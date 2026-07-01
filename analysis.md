# Why `qio::read_parquet` is slower than `nanoparquet` — profile analysis

**TL;DR** — The profiles show qio's decode and decompression are actually *faster*
than nanoparquet's. qio loses because it spends **~68% of its runtime re-counting
non-null values**, caused by a **quadratic (O(N²/batch)) prefix rescan** of
definition levels in the carquet page reader. Fixing that one loop should make qio
faster than nanoparquet, not just competitive.

---

## How the data was gathered

Both readers were sampled with macOS `sample` (1 ms interval) reading the *same*
file (`local-data/yellow_tripdata_2023-01.parquet`), 30 iterations each, via
`local-script/profile-all.sh`. Raw self-time tables:

- qio → [`local-script/qio.sample.summary.txt`](local-script/qio.sample.summary.txt)
- nanoparquet → [`local-script/nano.sample.summary.txt`](local-script/nano.sample.summary.txt)

"Self time" = the function that was actually executing when the sample was taken
(the *leaf* of the stack), so it points directly at where CPU cycles go.

---

## Where the time goes (self time, "Sort by top of stack")

### qio (~12,400 leaf samples counted)

| samples | % | function | category |
|--:|--:|---|---|
| **8399** | **~68%** | `carquet_neon_count_non_nulls` | **null counting** |
| 715 | 6% | `carquet_neon_checked_gather_i64` | value decode |
| 639 | 5% | `carquet_neon_build_null_bitmap` | null bitmap |
| 514 | 4% | `carquet_bitunpack8_32` | value decode |
| 369 | 3% | `carquet_rle_decoder_get_batch` | level/RLE decode |
| 302 | 2% | `qio_copy_batch` | R materialization |
| 264 | 2% | `read_projected_column` | dispatch |
| ~330 | ~3% | `libz` (`inflate`/gzip) | **decompression** |
| — | ~15% | everything else | mixed |

Grouped: **null counting ≈ 68%**, genuine value decode ≈ 15%, R materialization
≈ 4%, **decompression ≈ 3%**.

### nanoparquet (~12,200 leaf samples counted)

| samples | % | function | category |
|--:|--:|---|---|
| **6057** | **~50%** | `miniz::tinfl_decompress` | **decompression** |
| 1437 | 12% | `ParquetReader::read_data_page_rle` | level/RLE decode |
| 980 | 8% | `convert_column_to_r_dicts_na` | R materialization |
| 860 | 7% | `_platform_memmove` | buffer moves |
| 451 | 4% | `RunGenCollect` | R GC |
| 407 | 3% | `convert_column_to_r_int64_dict_miss` | R materialization |
| 368 | 3% | `SET_STRING_ELT` | R materialization |
| — | ~13% | everything else | mixed |

Grouped: **decompression ≈ 50%** (irreducible work — every reader must inflate the
pages), RLE decode ≈ 13%, R materialization ≈ 20%, buffer moves ≈ 9%.

### The key contrast

nanoparquet's profile is **healthy**: its single biggest cost is decompression,
which is unavoidable real work, and there is no pathological hotspot.

Two things jump out when comparing:

1. **qio has a pathological hotspot that nanoparquet lacks.** A *bookkeeping*
   routine (`count_non_nulls`) costs **11× more** than qio's actual value decode
   (8399 vs. 715). Counting nulls should be nearly free; here it dominates
   everything.

2. **qio's decompression is already far faster than nanoparquet's.** qio uses the
   system `libz` (~330 samples); nanoparquet bundles `miniz` (6057 samples) — ~18×
   more expensive on this file. qio's value decode (gather + bitunpack ≈ 1,300) is
   also lean. **qio's machinery is competitive or better everywhere except the
   null-count pass.**

So the slowness is not "qio is generally slow" — it is one specific, fixable bug.

---

## Root cause: a quadratic prefix rescan of definition levels

The hot function `carquet_neon_count_non_nulls` is fine in isolation — it is being
*called on a quadratically growing amount of data*. The culprit is the caller in
[`src/carquet/reader/page_reader.c:2717`](src/carquet/reader/page_reader.c#L2717),
inside `carquet_read_next_page`:

```c
if (reader->decoded_def_levels && reader->max_def_level > 0) {
    int32_t dense_start = count_present_levels(
        reader->decoded_def_levels,      /* from the START of the page ... */
        reader->page_values_read,        /* ... up to the read cursor      */
        reader->max_def_level);
    values_to_copy = count_present_levels(
        reader->decoded_def_levels + reader->page_values_read,
        to_copy,
        reader->max_def_level);
    offset = (size_t)dense_start * value_size;
}
```

`dense_start` is the number of present (non-null) values *before the current read
cursor* — it maps the logical row offset to the dense (null-compacted) value
buffer. But it is recomputed **from the beginning of the page on every batch copy**
by re-scanning `[0, page_values_read)`.

For a page of `N` values consumed in batches of `B`, the successive calls scan
`0, B, 2B, 3B, … ` definition levels, for a total of

```
B · (0 + 1 + 2 + … + N/B) ≈ N² / (2B)
```

— **quadratic in the page's value count.** Parquet row-group pages here hold many
values, so this prefix rescan swamps the actual decode. That is exactly the 68%
attributed to `carquet_neon_count_non_nulls`.

(Note: the sibling call site in
[`src/carquet/reader/column_reader.c:139`](src/carquet/reader/column_reader.c#L139)
is *correct* — it counts only the current batch's `values_read`, so it is O(N)
overall. The bug is specific to `page_reader.c`.)

---

## Recommended fix

**Track the dense offset incrementally instead of recomputing it.** The reader
already keeps `page_values_read`; add a parallel running counter for the *dense*
position so `dense_start` never needs a rescan.

1. Add a field next to `page_values_read` in
   [`src/carquet/reader/reader_internal.h:171`](src/carquet/reader/reader_internal.h#L171):

   ```c
   int32_t page_values_read;        /* logical values read from current page */
   int32_t page_dense_values_read;  /* present (non-null) values read so far  */
   ```

2. Reset `page_dense_values_read = 0` wherever `page_values_read` is reset (on page
   load / page reset).

3. In `carquet_read_next_page`, drop the first `count_present_levels` call and use
   the running counter:

   ```c
   if (reader->decoded_def_levels && reader->max_def_level > 0) {
       int32_t dense_start = reader->page_dense_values_read;      /* O(1) */
       values_to_copy = count_present_levels(                     /* O(B) */
           reader->decoded_def_levels + reader->page_values_read,
           to_copy, reader->max_def_level);
       offset = (size_t)dense_start * value_size;
       reader->page_dense_values_read += values_to_copy;          /* advance */
   }
   ```

This converts the whole page walk from **O(N²/B) → O(N)** and touches each
definition level exactly once. It should collapse the ~8,400-sample hotspot toward
the ~700 samples of the genuine per-value work — i.e. remove the majority of qio's
runtime.

### Cheap secondary win

Add a per-page "all present" fast path: when a data page has no nulls (its
definition-level RLE is a single run at `max_def_level`, or a `has_nulls` flag is
false), skip `count_present_levels` entirely — `dense_start == page_values_read`
and `values_to_copy == to_copy`. Many NYC-taxi columns are non-nullable or
null-free, so this removes the scan for them outright.

### Expected outcome

Given qio's decompression (~3%) and decode (~15%) are already leaner than
nanoparquet's, eliminating the ~68% null-count tax should make qio **faster than
nanoparquet** on this workload, not merely close the gap.

---

## Important constraint

`src/carquet/` is **vendored** (see `CLAUDE.md` and `tools/VENDORED.md`) and must
not be edited in place. This fix belongs **upstream in carquet**, then re-vendored
following `tools/VENDORED.md`. The change is small, self-contained, and does not
alter the public API, so it should re-vendor cleanly.
