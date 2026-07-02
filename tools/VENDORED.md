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
  `carquet_neon_count_non_nulls`. See `analysis.md`. The dense cursor is reset
  on every fresh page load (in `carquet_column_ensure_page_loaded`) and advanced
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

- **carquet: zero decode over-read slack on the decompress buffer.**
  `src/carquet/reader/page_reader.c`. The reusable decompress buffer was
  `realloc`'d to exactly the page's uncompressed size; bit-unpacking / RLE
  decoders read a few words past the payload end to fill the final value group,
  landing on uninitialised heap. Benign where the OS returns zeroed pages
  (arm64 macOS), garbage on glibc (x86) — silently corrupting decoded values
  for any compressed column beyond ~a dozen rows. Fix: over-allocate
  `CARQUET_DECODE_SLACK` (64) bytes and zero that slack after each
  decompression (both V1 and V2 paths). Found with valgrind `--track-origins`
  on x86 (ASan is blind to it — the read is in-allocation-bounds once padded,
  and uninitialised, not out-of-bounds). Guarded by the partial-page test.

## Re-vendoring

To bump a version: re-run the copy steps above from a fresh checkout of the new
tag, update the table (version + commit + date), re-apply the local patches
above (or confirm they landed upstream), and re-run `R CMD INSTALL` to confirm it
still builds.
