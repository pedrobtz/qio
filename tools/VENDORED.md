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

## Re-vendoring

To bump a version: re-run the copy steps above from a fresh checkout of the new
tag, update the table (version + commit + date), and re-run `R CMD INSTALL` to
confirm it still builds.
