# Vendored code

qio bundles C dependencies under `src/` and uses system zlib for Gzip. Do not
edit vendored files as ordinary package code: update from the pinned upstream
source, then reapply or upstream qio's patches.

| Library | Version | Commit | Retrieved | License |
|---|---|---|---|---|
| [carquet](https://github.com/Vitruves/carquet) | v0.6.0 | `06efab6dce5475a7faa86f0938d42e9078b6d440` | 2026-06-29 | MIT (`src/carquet/LICENSE`) |
| [zstd](https://github.com/facebook/zstd) | v1.5.7 | `f8745da6ff1ad1e7bab384bd1f9d742439278e99` | 2026-06-29 | BSD-3-Clause (`src/zstd/LICENSE`) |
| [lz4](https://github.com/lz4/lz4) | v1.10.0 | `ebb370ca83af193212df4dcbadcc5d87bc0de2f0` | 2026-06-29 | BSD-2-Clause (`src/lz4/LICENSE`) |

On Windows, Rtools supplies zlib.

## Included source

### carquet -> `src/carquet/`

Copy:

- `include/carquet/` to `src/carquet/carquet/`.
- `src/{compression,core,encoding,metadata,reader,simd,thrift,util,writer}/` to
  matching directories under `src/carquet/`.

Exclude CLI, tests, benchmarks, profiling, fuzzing, interop, examples, docs,
and build-system files.

### zstd -> `src/zstd/`

Copy from upstream `lib/`:

- `zstd.h`, `zstd_errors.h`, and `zdict.h`;
- `common/`, `compress/`, and `decompress/`.

Exclude `dictBuilder/`, `legacy/`, `deprecated/`, `dll/`, and build files.
`decompress/huf_decompress_amd64.S` is retained but not compiled.

`src/Makevars` defines:

- `XXH_NAMESPACE=ZSTD_` to avoid an xxHash symbol clash with carquet;
- `ZSTD_DISABLE_ASM=1`;
- `ZSTD_LEGACY_SUPPORT=0`.

zstd is single-threaded in qio.

### lz4 -> `src/lz4/`

Copy only `lz4.c` and `lz4.h`. Carquet uses the block API; frame, HC, file, and
separate xxHash sources are unnecessary.

## Local carquet patches

These changes are absent from the pinned upstream commit. Re-vendoring removes
them.

- **O(1) dense-value cursor** (`reader/page_reader.c`,
  `reader/reader_internal.h`). Maintain `page_dense_values_read` instead of
  rescanning prior definition levels. Reset it on page load and advance it on
  reads and partial-page skips. Covered by partial-page tests.
- **Count page nulls once** (`reader/page_reader.c`,
  `reader/column_reader.c`, `reader/reader_internal.h`). Cache
  `page_non_null_count` at decode and `last_dense_read` per read.
- **Fix scalar Snappy overlap** (`compression/snappy.c`). Use
  `big_pattern = 16`; a threshold of 8 sends 8..15-byte matches through unsafe
  16-byte copies and corrupts scalar x86 output. Covered by partial-page tests.
- **Zero decode slack** (`reader/page_reader.c`). Allocate and clear
  `CARQUET_DECODE_SLACK` after each payload so permitted group over-reads see
  defined bytes. This is defensive; the Snappy bug caused the reproduced
  corruption.
- **Propagate preload/index failures** (`reader/batch_reader.c`,
  `reader/column_reader.c`, `reader/page_filter.c`). Check column-read and
  offset-index statuses and release both indexes on page-filter failure. The
  preload path still returns a generic decode status.
- **Portable allocation format** (`reader/file_reader.c`). Use
  `PRIuMAX`/`uintmax_t`, not `%zu`, for MinGW's C runtime.
- **Correct SSE4.2 guard** (`simd/x86/sse_ops.c`). Outside MSVC, require
  `__SSE4_2__`; MinGW's `_M_X64` does not legalize SSE4.2 intrinsics without
  `-msse4.2`.

`reader_internal.h` defines structs shared by multiple translation units, while
R builds do not track header dependencies. After changing any vendored header,
clean before rebuilding:

```sh
find src -name '*.o' -delete
```

Failing to clean can mix old and new layouts and corrupt memory at runtime.

## Re-vendoring

1. Check out each new tag and record its exact commit.
2. Replace only the source subsets listed above.
3. Update the version table and license files.
4. Reapply every local patch, or confirm that upstream contains an equivalent
   fix and remove its ledger entry.
5. Clean all native objects because vendored headers may have changed.
6. Build, run the focused native/interoperability tests, then run the complete
   test suite and R CMD check.

When the planned `carquet-changes.patch` is added, it becomes the mechanical
patch record; this section remains the rationale and review checklist.
