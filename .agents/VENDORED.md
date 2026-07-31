# Vendored source code

This package bundles ("vendors") the C source of its dependencies so it builds
without external libraries (except system zlib). The bundled sources live under
`src/`. Do not edit vendored files in place — re-vendor from upstream at the
pinned version instead.

| Library | Version | Commit | Source | Retrieved | License |
|---------|---------|--------|--------|-----------|---------|
| carquet | v0.6.0  | `06efab6dce5475a7faa86f0938d42e9078b6d440` | https://github.com/Vitruves/carquet | 2026-06-29 | MIT (`src/carquet/LICENSE`) |
| zstd    | v1.5.7  | `f8745da6ff1ad1e7bab384bd1f9d742439278e99` | https://github.com/facebook/zstd | 2026-06-29 | BSD-3-Clause (`src/zstd/LICENSE`) |
| lz4     | v1.10.0 | `ebb370ca83af193212df4dcbadcc5d87bc0de2f0` | https://github.com/lz4/lz4 | 2026-06-29 | BSD-2-Clause (`src/lz4/LICENSE`) |

System `zlib` is used for the gzip codec and is not vendored (it is universally
available; on Windows it is supplied by Rtools).

## carquet → `src/carquet/`

The library sources only. Copied from the upstream tree:

- `include/carquet/` → `src/carquet/carquet/` (public headers)
- `src/{compression,core,encoding,metadata,reader,simd,thrift,util,writer}/`
  → `src/carquet/<same>/`

Excluded: `src/cli/`, `tests/`, `benchmark/`, `profiling/`, `fuzz/`, `interop/`,
`examples/`, `docs/`, and all build-system files.

## zstd → `src/zstd/`

Copied from upstream `lib/`:

- root headers `zstd.h`, `zstd_errors.h`, `zdict.h`
- `common/`, `compress/`, `decompress/`

Excluded: `dictBuilder/`, `legacy/`, `deprecated/`, `dll/`, and build files.
The x86-64 assembly `decompress/huf_decompress_amd64.S` is kept for fidelity but
**not compiled** — the build defines `ZSTD_DISABLE_ASM=1` and globs only `*.c`,
so the portable C decode path is used everywhere.

Build defines (see `src/Makevars`): `XXH_NAMESPACE=ZSTD_` (keeps zstd's bundled
xxHash from clashing with carquet's `carquet_xxhash64`), `ZSTD_DISABLE_ASM=1`,
`ZSTD_LEGACY_SUPPORT=0`. zstd multithreading is left off (single-threaded).

## lz4 → `src/lz4/`

carquet only uses the LZ4 block API (`LZ4_compress_default`,
`LZ4_decompress_safe`, `LZ4_compressBound`), so only `lz4.c` and `lz4.h` are
vendored. The frame/HC/file APIs and lz4's own `xxhash.c` are not needed.

## Local patches

These changes were applied on top of the vendored sources and are **not** in
upstream at the pinned commit. Re-vendoring will drop them — re-apply, or (better)
upstream them and bump the pin.

- **carquet: O(1) dense-value cursor in the page reader.**
  `src/carquet/reader/page_reader.c` + `reader_internal.h`. Adds
  `page_dense_values_read` to the column reader and maintains it incrementally,
  replacing an O(N) rescan of `[0, page_values_read)` in
  `carquet_read_next_page` that ran on every partial read — making one page
  O(N²/batch) in its value count. Consuming a large page in small batches
  (qio's default `batch_size`) spent the majority of read time in
  `carquet_neon_count_non_nulls`. The dense cursor is reset on every fresh page
  load (in `carquet_column_ensure_page_loaded`) and advanced
  in both `carquet_read_next_page` and the `carquet_column_skip` partial-page
  drop, so null offsets stay correct. Guarded by the partial-page-read test in
  `tests/testthat/test-parquet-file.R`.

- **carquet: count a page's nulls once, not per read.**
  `src/carquet/reader/page_reader.c`, `column_reader.c` + `reader_internal.h`.
  Adds `page_non_null_count` (present values in the current page, counted once at
  decode) and `last_dense_read` (present values from the last read) to the column
  reader. `carquet_read_next_page` reuses the page total for whole-page reads
  instead of re-scanning the definition levels, and the column reader reuses the
  per-read count instead of re-scanning again. Previously the same definition
  levels were SIMD-counted three times (decode + read + column layers), making
  `carquet_neon_count_non_nulls` ~39% of a nullable read; after this it is ~1%,
  dropping the NYC taxi read from ~1.7s to ~0.5s (near nanoparquet).

  NOTE: `reader_internal.h` defines the column-reader struct used across every
  reader `.c` file, but R's build does not track header dependencies — after
  editing it you MUST clean-build (`find src -name '*.o' -delete` before
  `R CMD INSTALL`), or stale objects keep the old struct layout and corrupt
  memory at runtime.

- **carquet: fix snappy scalar `incremental_copy` for 8..15-byte matches.**
  `src/carquet/compression/snappy.c`. Snappy's overlapping match copy has three
  builds: a NEON reshuffle (`__ARM_NEON`, baseline arm64), an SSSE3 reshuffle
  (`__SSSE3__`, needs `-mssse3`), and a pure-scalar fallback. The scalar path set
  its short-pattern threshold `big_pattern = 8`, so a match distance in `[8, 16)`
  skipped the 8-byte `copy64` fill and fell into the "simple block copies" tail,
  which uses 16-byte `copy128`s. With `src = op - pattern_size`, a 16-byte read
  from `src` spans `[op-pattern_size, op+ (16-pattern_size))` — its second half is
  the not-yet-written destination, so it copies garbage (the uninitialised
  decompress buffer). Result: any snappy stream containing an 8..15-byte match —
  e.g. the default codec on repetitive/zero-heavy columns like plain doubles —
  decoded to garbage past the first such match. Benign on builds with NEON/SSSE3
  (arm64, or x86 with `-mssse3`); garbage on the scalar fallback, which is what a
  default-flags x86-64 build (this package) uses. Fix: `big_pattern = 16` for the
  scalar path too, so `[8, 16)` matches use the correct 8-byte overlapping fill.
  This was the true source of the "uninitialised value" valgrind flagged against
  the decompress buffer below. Reproduce on arm64 by compiling snappy without
  `__ARM_NEON`. Guarded by the partial-page test in
  `tests/testthat/test-parquet-file.R`.

- **carquet: zero the decode over-read slack on the decompress buffer (defensive).**
  `src/carquet/reader/page_reader.c`. The reusable decompress buffer is
  `realloc`'d (not zeroed); `ensure_decompress_capacity` over-allocates
  `CARQUET_DECODE_SLACK` (64) bytes past the payload and `memset`s just that
  `[needed, needed+slack)` slack before each decompress, so a decoder's group
  over-read past the produced bytes reads defined zeros rather than uninitialised
  heap (benign on arm64 macOS where pages come zeroed, undefined on glibc x86).
  Only the slack is zeroed, not the whole buffer — the decompress that follows
  writes the full `[0, needed)` payload, so a per-page whole-buffer `memset` on
  the read hot path is unnecessary. NOTE: the concrete corruption originally
  chased here turned out to be the snappy scalar bug above, not a bit-unpack/RLE
  over-read; with that fixed this slack is defensive belt-and-suspenders. Found
  with valgrind `--track-origins` on x86 (ASan is blind to it — the read is
  in-allocation-bounds once padded, and uninitialised, not out-of-bounds).

- **carquet: propagate page preload and offset-index failures.**
  `src/carquet/reader/batch_reader.c`, `column_reader.c`, and `page_filter.c`.
  Replaces ignored column-read and offset-index statuses with checked failures;
  page-filter cleanup releases both indexes before returning. The batch preload
  path still returns a bare `CARQUET_ERROR_DECODE`, so richer column context
  remains an upstream improvement.

- **carquet: use a portable format for prebuffer allocation errors.**
  `src/carquet/reader/file_reader.c`. Formats allocation sizes through
  `PRIuMAX` and `uintmax_t`, avoiding `%zu` incompatibility with the Microsoft C
  runtime used by MinGW/Rtools.

- **carquet: require an actual SSE4.2 feature signal outside MSVC.**
  `src/carquet/simd/x86/sse_ops.c`. MinGW defines `_M_X64` for compatibility but
  still needs `-msse4.2` before SSE4.2 intrinsics are legal. The guard now accepts
  the architecture macros implicitly only under MSVC and otherwise requires
  `__SSE4_2__`.

## Re-vendoring

To bump a version: re-run the copy steps above from a fresh checkout of the new
tag, update the table (version + commit + date), re-apply the local patches
above (or confirm they landed upstream), and re-run `R CMD INSTALL` to confirm it
still builds.
