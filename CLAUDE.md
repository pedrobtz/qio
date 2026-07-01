# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`qio` is an R package for reading and writing Apache Parquet files. It wraps the C-based `carquet` library (vendored at `src/carquet/`) with an R interface. The package has no runtime R dependencies — only `testthat` and `withr` as test suggests.

## Development Commands

```r
# Install the package (compiles C code)
devtools::install()

# Run all tests
devtools::test()

# Run a single test file
devtools::test(filter = "qio")   # matches by test label substring

# Regenerate documentation and NAMESPACE from roxygen2 comments
devtools::document()

# Full R CMD check
devtools::check()

# Or from the shell:
R CMD check --no-manual .
```

## Architecture

### Layers

1. **R API** (`R/`): user-facing S3 functions that validate inputs and call `.Call()`.
2. **C glue** (`src/qio.c`, `src/qio_file.c`): thin R ↔ C bridges. `qio.c` handles eager read/write; `qio_file.c` manages the persistent `qio_parquet_file` handle (lazy reader).
3. **carquet** (`src/carquet/`): vendored C Parquet implementation — do not edit in place.
4. **Compression** (`src/zstd/`, `src/lz4/`): also vendored — do not edit in place.

### Key files

| File | Role |
|---|---|
| `R/parquet.R` | All public R functions: `read_parquet`, `write_parquet`, `parquet_open/close`, `schema`, `row_groups`, `metadata`, `collect`, `walk_batches`, S3 methods for `qio_parquet_file` |
| `R/parquet-file.R` | Input validators (`qio_file_path`, `qio_flag`, `qio_whole_number`, `qio_columns`, `qio_row_groups`, `qio_empty_dots`) |
| `R/parquet-type-mapping.R` | `parquet_type_mapping()` — static table of physical Parquet ↔ R type mappings |
| `src/qio.c` | `qio_read_parquet` / `qio_write_parquet` C entry points and the `qio_scatter` scatter helper |
| `src/qio_file.c` | Persistent handle: open, close, dim, names, schema, row_groups, metadata, collect, walk |
| `src/qio_file.h` | Declarations for all `qio_file.c` entry points |
| `src/Makevars` | Build: globs vendor sources, sets include paths, SIMD flags, and link flags |
| `tools/VENDORED.md` | Vendored library versions and re-vendoring instructions |
| `working-on.md` | Living development log: implemented features, decisions in force, next steps, and known limitations — **read before adding new type support** |
| `TYPES.md` | Detailed type decision record and full type roadmap |

### `qio_parquet_file` handle lifecycle

`parquet_open()` allocates a C reader wrapped in an R external pointer (`EXTPTRSXP`) with a finalizer. The handle carries a "busy" flag to reject re-entrant operations and an "open" flag so `parquet_close()` is idempotent. All `.Call()` entry points in `qio_file.c` validate the pointer before use.

### Type mapping

Physical Parquet types map to R types without consulting logical annotations today. The logical annotation layer (dates, timestamps, decimals, UUIDs) is the primary active development area. See `working-on.md` §"Decisions in force" before changing conversion behavior.

## Vendored code

Never edit files under `src/carquet/`, `src/zstd/`, or `src/lz4/` directly. To update a vendored library, follow the re-vendoring steps in `tools/VENDORED.md`.

## Tests

Tests live in `tests/testthat/test-qio.R`. The test suite uses `withr::local_tempfile()` for isolation. External fixtures (interoperability tests) and the package-owned fixture (four row groups, all supported types, duplicate footer keys) are used alongside round-trip tests.

Current baseline: 87 tests, 0 failures, 0 warnings (as of 2026-07-01).
