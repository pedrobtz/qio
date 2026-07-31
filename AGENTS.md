# Repository Guidelines

## Overview

`qio` reads and writes Apache Parquet files from R through the vendored C
library `carquet`. The default API has no required runtime R dependencies;
optional result modes use the suggested `bit64` and `hms` packages. Read
`.agents/roadmap.md` and `.agents/design.md` before changing type behavior or
release scope.

## Project Structure & Module Organization

- `R/` contains user-facing functions, S3 methods, validation, and logical type
  conversion. `parquet.R` provides eager I/O, `parquet-file.R` manages open
  files and selective reads, `parquet-plan.R` owns read mappings, and
  `parquet-schema.R` owns writer schema resolution.
- `src/qio.c` implements the write bridge and `.Call` registration;
  `src/qio_file.c` implements open handles, metadata, collection, and batches.
- `src/carquet/`, `src/zstd/`, and `src/lz4/` are vendored native libraries.
- `tests/testthat/` contains tests and `tests/testthat/parquet/` contains
  interoperability fixtures. Record fixture provenance in `SOURCE.md`.
- `man/` and `NAMESPACE` are generated from roxygen comments. `.agents/`
  contains design, type, roadmap, and vendoring documentation.

## Architecture Rules

The main layers are R API → package-owned C glue → vendored C libraries.
`read_parquet()` is `parquet_open()` plus `collect()`. Open files are external
pointers with finalizers; native entry points must validate the pointer and
respect the busy/open guards that prevent re-entrant use and make close
idempotent.

Keep physical decoding in C and logical reinterpretation in the shared R read
plan. `qio_type_registry()` is the source of truth for physical fallbacks, and
`qio_apply_plan()` must keep `read_parquet()`, `collect()`, and
`walk_batches()` consistent. Eager reads request mmap and may decode numeric
columns in parallel; long-lived `parquet_open()` handles default to buffered
I/O.

## Build, Test, and Development Commands

Run commands from the repository root:

```sh
Rscript -e 'devtools::load_all()'   # compile and load for interactive work
Rscript -e 'devtools::install()'    # install a local compiled build
Rscript -e 'devtools::test()'       # run the complete testthat suite
Rscript -e 'devtools::test(filter = "parquet-plan")' # focused tests
Rscript -e 'devtools::document()'   # regenerate man/ and NAMESPACE
Rscript -e 'devtools::check()'      # build and run R CMD check
Rscript -e 'pkgdown::check_pkgdown()' # validate the reference index
air format .                        # format R sources
```

Building requires GNU make and zlib; zstd and LZ4 compile from bundled sources.

## Coding Style & Naming Conventions

Use two-space indentation in R and four spaces in package-owned C. Prefer base
R pipes (`|>`) and `lower_snake_case`; internal helpers use the `qio_` prefix.
Keep physical decoding in C and logical type conversion in the shared R read
plan. Wrap roxygen comments at 80 characters and regenerate documentation
instead of editing `.Rd` files directly. Preserve the package goal of zero
required runtime R dependencies unless a design decision says otherwise.

Export and document user-facing functions; do not add roxygen topics to purely
internal helpers. Add a concise `NEWS.md` bullet for user-visible changes.

## Vendored Code & Native Safety

Do not modify vendored trees as ordinary package code. Follow
`.agents/VENDORED.md` for re-vendoring and for local patches that must be
reapplied or upstreamed. If a vendored header changes, remove stale objects
with `find src -name '*.o' -delete` before rebuilding; mismatched layouts can
corrupt memory without a linker failure.

SIMD paths differ by architecture: arm64 enables NEON, while x86 commonly uses
scalar fallbacks. Treat native changes as platform-sensitive and rely on the
Linux/Windows R CMD checks plus sanitizer, Valgrind, gctorture, and rchk
workflows under `.github/workflows/`.

## Testing Guidelines

Tests use testthat edition 3. Mirror `R/foo.R` with
`tests/testthat/test-foo.R`, and add focused coverage for every behavior change.
Use `withr` for temporary files and cleanup. Prefer snapshots for user-facing
messages, warnings, and errors. Keep interoperability fixtures in
`tests/testthat/parquet/`. Include round-trip, null, projected-column, and
row-group cases where relevant. Every behavior change needs focused coverage;
run the full suite before handoff.

## Commit & Pull Request Guidelines

Follow the existing short, imperative commit style, optionally scoped:
`fix x86 DOUBLE corruption`, `perf: reduce buffer clearing`, or
`writer: validate schema`. Keep commits focused. Pull requests should explain
the behavior and rationale, link relevant issues, list tests and checks run,
and call out platform-sensitive C, SIMD, or vendored-code changes. Include
benchmarks for performance claims and update `NEWS.md` for user-facing changes.
