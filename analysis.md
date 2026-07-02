# qio read performance — analysis and optimization record

**Status: implemented.** Serial `qio::read_parquet` went from **4.54s to
~440ms (10×)** on the reference workload — parity with nanoparquet — while
allocating ~30% less memory (497 vs 711 MB). With memory-mapped input,
`collect()` additionally decodes numeric columns in parallel on carquet's
worker pool: **~220ms, ~3× faster than nanoparquet** (which is single-threaded
by design). This file records the diagnosis, the five changes, and the
remaining levers.

Reference workload: `local-data/yellow_tripdata_2023-01.parquet` (NYC yellow
taxi, 3.07M rows × 19 columns, gzip, dictionary-encoded, all columns OPTIONAL),
fully materialized to a base-R data.frame, single-threaded, Apple Silicon.

## How the problem was found

macOS `sample` profiles (see `local-script/profile-sample.sh` and
`profile-all.sh`) comparing qio against nanoparquet on the same file. The
original profile showed **~68% of qio's runtime inside
`carquet_neon_count_non_nulls`** — a null-*counting* bookkeeping routine costing
11× more than the actual value decode. nanoparquet's profile had no such
hotspot: its time went to decompression (miniz, ~50%) and genuine decode.

The guiding conclusion, confirmed at each step: **nanoparquet's speed is
architecture, not primitives** — it walks each column's definition levels once,
decodes values directly into the R vector, and does zero work for null-free
chunks. carquet has faster primitives (system zlib beats nano's miniz ~18×;
SIMD gather/bitunpack) but its layered general-purpose API re-derived the null
shape repeatedly. Every fix below removes redundant work; none makes a kernel
faster.

## The four changes

| # | change | where | median after |
|---|--------|-------|--------------|
| 0 | baseline | — | 4.54s |
| 1 | O(1) dense-value cursor (fixes O(N²) prefix rescan) | vendored carquet patch | 2.28s |
| 2 | direct column reads in `collect()` (skip batch reader's expand + null bitmap) | `src/qio_file.c` | 1.73s |
| 3 | count each page's nulls once, reuse across layers | vendored carquet patch | 519ms |
| 4 | type-specialized scatter (hoisted `REAL()`/`INTEGER()` accessors, `memcpy` fast paths) | `src/qio_file.c` | **438ms** |
| 5 | parallel numeric-column decode on carquet's worker pool (mmap only) | `src/qio_file.c` | **~220ms** (mmap + threads) |

### 1. Quadratic prefix rescan (carquet patch)

`carquet_read_next_page` recomputed `dense_start` — the non-null count before
the read cursor — by re-scanning the page's definition levels **from the start
on every partial read**: O(N²/batch) per page. Fixed by tracking
`page_dense_values_read` incrementally. Also made read time independent of
`batch_size`.

### 2. Direct column reads (qio)

`collect()` previously went through carquet's batch reader, whose contract is
row-aligned buffers + null bitmaps. Producing that format costs an in-place
dense→sparse expansion (memmove) plus a SIMD bitmap build — which qio then
immediately re-scattered into R vectors. `qio_collect_body` now iterates
(row group × column) via `carquet_reader_get_column` +
`carquet_column_read_batch`, which yield Parquet-native **dense values +
definition levels**, and `qio_scatter_dense_column` places them into the result
in a single pass. `build_null_bitmap` and the expand memmove disappeared from
the profile entirely. (`walk_batches()` still uses the batch reader.)

### 3. Count once per page (carquet patch)

The same definition levels were SIMD-counted **three times** per page — at
decode (to size the dense values), at read (to size the copy), and in the
column reader (to advance the dense output cursor). Now counted once at decode
(`page_non_null_count`) and reused (`last_dense_read`).
`carquet_neon_count_non_nulls` fell from 39% of runtime to ~1%.

### 4. Type-specialized scatter (qio)

The scatter loop called `REAL()`/`INTEGER()` — real function calls since
R 3.5 — **per value**, and re-ran a type `switch` per value. Rewritten
nanoparquet-style: one specialized loop per physical type, destination pointer
hoisted out of the loop, straight `memcpy` for REQUIRED DOUBLE/INT32 columns.

### 5. Parallel numeric-column decode (qio)

`collect()` builds one task per (row group × numeric column) and runs them on
carquet's own worker pool (`reader/worker_pool.h`, the pool the batch reader
uses). R's C API is main-thread-only, so the design is: the main thread
allocates all result vectors up front and hands workers **raw data pointers**;
workers decode into private malloc'd scratch and scatter through those
pointers with zero R API calls (`qio_scatter_numeric_raw`). BYTE_ARRAY columns
stay on the main thread (interning + write barrier), overlapping the workers.
Worker errors are recorded per task and raised on the main thread after
`carquet_worker_pool_wait`; on an R-side unwind, `qio_batch_cleanup` waits for
the pool before the longjmp continues so workers never write into released
vectors.

Parallelism is gated on `mmap = TRUE`: the fread path shares FILE-handle and
prebuffer state across column readers and is not thread-safe. `threads = 0`
(the default) uses the machine's core count; `threads = 1` forces serial.

```r
pf <- parquet_open(path, mmap = TRUE)   # threads = 0 -> auto
x  <- collect(pf)                        # ~220ms vs nano's ~650ms
```

## Isolation experiments worth remembering

- **Null-path tax**: identical qio-written files differing only in
  REQUIRED vs OPTIONAL (one NA per column): 0.80s vs 1.46s before change 3 —
  the OPTIONAL machinery alone nearly doubled read time even with ~zero actual
  nulls. Real-world writers (pyarrow, Spark) mark nearly everything OPTIONAL.
- **arrow comparisons need care**: `arrow::read_parquet` defaults to ALTREP
  (lazy; `mem_alloc` ≈ 0). With `options(arrow.use_altrep = FALSE)` it still
  reads in ~150ms — but ~2.6× of its lead is multithreading (361ms
  single-threaded on 8-core). qio and nanoparquet are single-threaded.
- **carquet's "70× faster than Arrow" claim** is the mmap zero-copy path
  (uncompressed + PLAIN + REQUIRED + fixed-width): it returns pointers into the
  file, no decode. Unreachable from R without ALTREP, and real-world files
  (gzip + dictionary + OPTIONAL + int64) satisfy none of its conditions.

## Constraints

The carquet patches (changes 1 and 3) touch vendored code under
`src/carquet/` — against repo convention. They are documented in
`tools/VENDORED.md` § "Local patches" and must be upstreamed to
https://github.com/Vitruves/carquet or re-applied on re-vendor.

**Build gotcha**: `reader_internal.h` defines the column-reader struct used by
every reader `.c` file, and R's build does not track header dependencies.
After editing it, clean-build (`find src -name '*.o' -delete`) or stale objects
keep the old struct layout and corrupt memory at runtime (silent SIGABRT).

## Remaining levers (not implemented)

0. ~~`read_parquet()` does not thread by default~~ — **resolved**:
   `read_parquet()` now opens with `mmap = TRUE` (carquet falls back to
   buffered reads automatically if mapping fails), so the eager API threads by
   default: ~200ms vs nanoparquet's ~650ms. The mapping lives only for the
   read (the handle closes on exit), keeping the Windows delete-lock and
   truncation-SIGBUS exposure to a ~0.2s window. `parquet_open()` keeps
   `mmap = FALSE` because its handles are long-lived.
1. **No-null fast path**: `carquet_reader_column_statistics()` exposes
   `null_count`; when 0, skip definition-level handling entirely and take the
   REQUIRED path (bulk copy). Most real-world OPTIONAL columns are null-free.
2. **Decode into R memory** for DOUBLE/INT32: pass `REAL(x)`/`INTEGER(x)` as
   `carquet_column_read_batch`'s output buffer; nullable columns then use
   nanoparquet's in-place back-to-front NA expand. Removes the scratch buffer
   copy. (carquet still stages pages internally — a 1-copy floor vs
   nanoparquet's 0; that residual needs an upstream carquet redesign.)
3. **carquet bitunpack dispatch hoist**: `carquet_bitunpack8_32` re-fetches its
   SIMD function pointer (with an atomic init check) every few values; hoist to
   once per page. Small vendored patch.
4. **Threading the fread path** would need per-column-reader file descriptors
   (pread) upstream in carquet, or one private carquet reader per worker task
   in qio.

## Verification (2026-07-02)

- `bench::mark`, 10 iterations, warm cache, GC included:
  qio threaded (mmap) **223ms**, qio serial 676ms, qio fread 676ms,
  nanoparquet 654ms — all qio variants at 497MB vs nano's 711MB.
- Full test suite: 190 pass, 0 fail (includes the partial-page null-offset
  regression test and a threaded-vs-serial mmap equivalence test).
- Threaded, serial-mmap, and fread reads are `identical()`; data validated
  against `arrow::read_parquet` column-by-column: identical values and NA
  counts (358,715), modulo qio's documented representation of non-UTC
  timestamps as raw numeric.
- Caution when benchmarking: `devtools::load_all()` compiles a **debug build**
  (`-O0`, ~3× slower) and leaves `-O0` objects in `src/` that a later
  `R CMD INSTALL` silently reuses; benchmark only the installed package in a
  fresh session (see the header of `local-script/benchmark.R`).
