# Read performance against nanoparquet

Owns the v0.2.0 read-performance work: the target, the measured evidence, the
root causes, and the ordered plan. Benchmark method, reference workloads, and
the regression threshold stay in [`../bench/README.md`](../bench/README.md);
this document says what to change and why.

## Target

**Match or beat nanoparquet on read, on the workloads where qio is behind.**

qio is already ahead on numerics and near parity on plain text. The whole gap
is dictionary-encoded text, and it widens with dictionary cardinality. Parity
there is the goal; the parallel decode qio already has is what should take it
past parity, since nanoparquet is single-threaded by design (confirmed: no
threading primitives anywhere in its sources).

## Where qio stands

1,000,000 rows, single column, snappy, four row groups, Apple silicon, 8 cores.
Median seconds to *materialized* data, so ALTREP deferral is charged fairly.

| workload | qio | nanoparquet | ratio |
|---|---:|---:|---:|
| doubles | 0.006 | 0.012 | **0.50x** |
| plain text, all distinct | 0.151 | 0.132 | 1.14x |
| dictionary text, 500 values | 0.028 | 0.015 | 1.87x |

The dictionary case degrades with cardinality, in steps that land exactly at
powers of two. This was predicted from carquet's kernel coverage before it was
measured, which is why it is trustworthy:

| distinct values | index bit width | qio | nanoparquet | ratio |
|---:|---:|---:|---:|---:|
| 200 | 8 | 0.0230 | 0.0150 | 1.53x |
| 256 | 8 | 0.0250 | 0.0150 | 1.67x |
| 257 | 9 | 0.0280 | 0.0160 | 1.75x |
| 65536 | 16 | 0.0710 | 0.0310 | 2.29x |
| 65537 | 17 | 0.0790 | 0.0300 | 2.63x |

The steps at 8 -> 9 and 16 -> 17 bits are ~12% each. They are real but
secondary: qio is already 1.53x behind at width 8, where carquet's fast kernel
*is* used. Most of the gap is constant across widths.

## Profile

`sample(1)` over a read loop, 1,000,000 rows, cardinality 200 (bit width 8, so
carquet's fast path). 3313 samples in `qio_parquet_collect`.

| component | share |
|---|---:|
| qio scatter loop -- `SET_STRING_ELT` | 20% |
| qio scatter loop -- address-cache hash and probe | 20% |
| carquet -- RLE index decode | 20% |
| GC triggered by result allocation | 11% |
| carquet -- dictionary gather into `carquet_byte_array_t` | 8% |
| carquet -- definition levels, page memmove | 6% |
| carquet -- snappy decompress | 0.3% |

Decompression is noise. The cost is index decoding and string materialization,
in roughly equal parts.

The 11% GC share is inflated by the measurement loop, which allocates a
1,000,000-element `STRSXP` repeatedly. Treat the other figures as slightly
understated rather than treating GC as a target.

The plain-text profile is different and should not be optimized with the same
changes: there `Rf_mkCharLenCE` is 38% and `qio_check_string_bytes` (UTF-8
validation) is 28%.

## Root causes

Three, each confirmed by reading both implementations rather than inferred from
timings alone.

### 1. Dictionary text is expanded, then re-deduplicated

carquet materializes every row into a 16-byte `carquet_byte_array_t`
(16 MB per million rows), and
[`qio_scatter_dense_column()`](../src/qio_file.c) then walks those structs
hashing each *pointer* to rediscover the 200 distinct values it already had.
qio pays to destroy the dictionary and pays again to rebuild it.

nanoparquet keeps the indices, builds one `STRSXP` of the dictionary, and
gathers (`RParquetReader.cpp`, `convert_column_to_r_ba_string`):

```cpp
SEXP tmp = PROTECT(Rf_allocVector(STRSXP, dict_len));
for (uint32_t i = 0; i < dict_len; i++) {         // one mkChar per distinct value
  SET_STRING_ELT(tmp, i, Rf_mkCharLenCE(...));
}
while (didx < end) {                               // direct index gather
  SET_STRING_ELT(x, from++, STRING_ELT(tmp, *didx++));
}
```

carquet already supports exactly this: `preserve_dictionaries` in the
batch-reader config ([`carquet.h`](../src/carquet/carquet/carquet.h) ~1707)
returns `uint32` indices plus the dictionary. **qio has never set it.**

Note that `roadmap.md` section 3 marks "materialize dictionary text
efficiently" as done. It refers to the address cache, which was a real
improvement over per-row `Rf_mkCharLenCE` (-46% at the time). The profile now
shows that cache is itself the 20%. The item should be reopened, not treated as
settled.

### 2. Bit-unpack kernels are narrow and sparse

| | carquet | nanoparquet |
|---|---|---|
| widths with a kernel | 1-8 and 16 | all of 1-32 |
| values per call | 8 | 32 |
| fallback for other widths | byte-at-a-time loop with `%` per byte | none needed |
| per-call overhead | `carquet_dispatch_get_bitunpack8_fn()` including `DISPATCH_ENSURE_INIT()` | none, unrolled |

nanoparquet vendors `fastpforlib` (Apache-2.0, ~2600 lines), which has 124
fully unrolled `__fastunpack1`..`__fastunpack32` routines.

The per-call dispatch lookup alone is 6% of carquet's RLE decode: it runs once
per 8 values and is pure overhead.

### 3. RLE literal runs are copied one value at a time

carquet unpacks into a small scratch buffer and then copies out with three loop
conditions per value ([`rle.c`](../src/carquet/encoding/rle.c) ~212):

```c
while (read < count && dec->bitpack_pos < dec->bitpack_count &&
       dec->run_remaining > 0) {
    output[read++] = dec->bitpack_buffer[dec->bitpack_pos++];
    dec->run_remaining--;
}
```

nanoparquet unpacks the whole literal run straight into the destination
(`RleBpDecoder.h`, `GetBatch`): `BitUnpack<T>(values + values_read,
literal_batch)`. No scratch, no per-value copy.

### Also: qio never writes dictionary-encoded text

Separate from reading, and it makes qio's own files the worst case. The same
500-value column: qio writes 283 KB, arrow writes 49 KB -- **5.7x**. Reading a
qio-written text column therefore lands on the plain path, where per-row
`mkCharLenCE` and UTF-8 validation dominate.

carquet's writer supports it (`column_writer.c` marks `BYTE_ARRAY` dictionary
eligible); qio calls `carquet_writer_options_init()` and never sets a per-column
encoding via `carquet_writer_set_column_encoding()`.

## Plan

Ordered by measured value per unit of risk. Each step states its own exit
gate. **No step lands without before/after medians on an idle machine**, per
the working rules in `../bench/README.md`.

### Step 0 -- extend the comparison harness (prerequisite)

`bench/compare-readers.R` uses one text cardinality, which hides the cliff that
turned out to be a real effect. Add a cardinality sweep (200, 257, 65536,
65537) and record ratios, not just seconds.

Exit: the table above is reproducible from a committed script.

### Step 1 -- materialize dictionary text from indexes

The largest single win and the one that reaches the target.

Read via carquet's `preserve_dictionaries` path, build the dictionary `STRSXP`
once per column chunk, gather by index. Removes the dictionary gather (8%) and
the entire address cache (20%).

Constraints that make this harder than it looks, and which the design must
address before any code is written:

- **A column chunk can mix encodings.** Arrow writes a dictionary page and then
  falls back to PLAIN for later pages in the same chunk; carquet errors out in
  preserve mode when that happens (`page_reader.c` ~967, ~1103). A fallback to
  the current path is mandatory, per page, not per column.
- **`qio_apply_plan()` must keep `read_parquet()`, `collect()`, and
  `walk_batches()` consistent** (see `../CLAUDE.md`). A faster path used by only
  one of the three is a defect, not an optimization.
- **UTF-8 validation moves but must not be skipped.** Validate the dictionary
  once per chunk instead of once per row. That is a speedup *and* a
  correctness-preserving change; dropping validation is not on the table.
- The address cache stays for the plain path, where it already pays for itself
  and switches itself off when it does not.

Expected: -28% on the dictionary workloads, which is roughly parity
(0.023 -> ~0.017 against nanoparquet's 0.015).

Exit: dictionary workloads at ratio <= 1.1x; the full interoperability corpus
unchanged; a fixture with mid-chunk encoding fallback in
`tests/testthat/parquet/`.

### Step 2 -- fix the RLE literal-run copy

Unpack literal runs directly into the destination and delete the per-value copy
loop. Hoist the dispatch lookup out of the per-8-values path.

Smallest change here, and it helps every RLE consumer -- dictionary indices,
definition levels, booleans -- not only text.

Expected: the dispatch hoist alone is ~6% of the RLE decode (~1% overall); the
direct-unpack is worth more but is not separately measured yet. Measure both
independently; do not land them as one commit.

Exit: measured gain on `read-string_low_cardinality` and no regression on
`read-numeric_nulls`, which exercises the same decoder for definition levels.

### Step 3 -- widen bit-unpack kernel coverage

Add unrolled kernels for widths 9-15 and 17-32, and unpack 32 values per call
rather than 8.

Two ways to get there, and the choice needs deciding before work starts:

| option | pros | cons |
|---|---|---|
| Extend carquet's own kernels | fits `VENDORED.md` patch discipline, upstreamable, no new license | ~24 kernels to write and test |
| Vendor `fastpforlib` | proven, complete, already used by nanoparquet | new Apache-2.0 dependency in an MIT package, third bundled license, CRAN `LICENSE`/NOTICE work, and it is C++ in a C codebase |

**Recommendation: extend carquet.** The C++/licensing/CRAN cost of a third
bundled library outweighs 24 mechanical kernels, and a carquet patch is
upstreamable where a vendored library is not. Revisit only if the kernels prove
harder than expected.

Expected: ~12% on widths outside 1-8 and 16, which is where high-cardinality
dictionaries live. Nothing on width <= 8.

Exit: `test_bitunpack_wide`-style verification of every new kernel against the
scalar unpacker, plus the cardinality sweep from step 0 showing the cliff gone.

### Step 4 -- parallelize text columns

`qio_file.c` keeps all `BYTE_ARRAY` work on the main thread because interning
and the write barrier are R API. But only `SET_STRING_ELT` (20%) truly needs
the main thread. After step 1, the index decode is worker-safe: workers produce
`uint32` indices into private scratch, the main thread gathers.

This is the step that goes *past* nanoparquet rather than matching it.

Expected: up to the ~50% of a text read that is not R API, bounded by
Amdahl and by the existing 50,000-row threshold for private readers.

Exit: a measured gain at 8 threads with no change at `threads = 1`; clean under
the sanitizer and helgrind workflows.

### Step 5 -- write dictionary-encoded text

Set `CARQUET_ENCODING_RLE_DICTIONARY` for `BYTE_ARRAY` columns. Roughly ten
lines. 5.7x smaller files on low-cardinality text, and it puts qio-written files
on the fast read path.

**This one is gated on verification, not on measurement.** qio has never
exercised carquet's dictionary encoder, and this project has already found a
carquet encoder that silently corrupted output (BYTE_STREAM_SPLIT, recorded in
`../bench/README.md`). Round-trip the full type matrix and verify with arrow and
pyarrow as independent oracles before trusting it.

Exit: independent-oracle verification across the type matrix; a size and time
figure for each reference workload; a `NEWS.md` entry, since it changes default
output.

## Sequencing

Steps 1-5 are v0.2.0 and **should not start before v0.1.0 is tagged.** Step 1
restructures how text is materialized, which invalidates phase 8's release
validation.

Step 5 is the exception worth considering for v0.1.0: it changes a shipped
default, and defaults are the expensive thing to revisit after release --
not for compatibility, since old files stay readable, but because users' stored
files and their own measurements anchor on whatever 0.1.0 wrote. It is cheap to
verify, so the decision should follow the verification result rather than
precede it.

Within v0.2.0, do step 0 first, then 1, then 2, then 3. Step 4 comes last: it
is the only one whose payoff depends on another step landing first.

## Out of scope

Recorded so they are not re-proposed without new evidence.

- **Statistics-driven no-null path** and **backward in-place expansion.** Both
  measured and declined in phase 4, ceilings of 10.5% and 3.2%. nanoparquet
  does implement the second one (`convert_column_to_r_ba_string_miss`), which
  is worth knowing but does not change the measured ceiling on qio's side.
- **Dropping UTF-8 validation.** It is 28% of the plain-text read, and it is
  why qio rejects invalid UTF-8 and embedded nuls with the column and row.
  Moving it (step 1) is in scope; removing it is not. If the plain path becomes
  the priority, SIMD-accelerate `qio_utf8_invalid_at()` instead.
- **Compression codecs.** Snappy decompression is 0.3% of a dictionary read.
  There is nothing here.
