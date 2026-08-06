# Repository guidance

`qio` reads and writes Apache Parquet files from R through the vendored C
library `carquet`. The default API has no required runtime R dependencies;
optional result modes may use suggested packages such as `bit64` and `hms`.

Before changing behavior, read the document that owns it:

- [`.agents/TYPES.md`](.agents/TYPES.md) for Parquet-to-R mappings.
- [`.agents/roadmap.md`](.agents/roadmap.md) for release scope and priorities.
- [`.agents/plan.md`](.agents/plan.md) for ordered v0.1.0 work and exit gates.
- [`.agents/VENDORED.md`](.agents/VENDORED.md) before touching vendored code.

## Architecture

The layers are R API -> package-owned C glue -> vendored C libraries.

- `R/parquet.R`: eager I/O and user-facing helpers.
- `R/parquet-file.R`: open handles, inspection, selection, and collection.
- `R/parquet-plan.R`: shared read mapping and logical conversion.
- `R/parquet-schema.R`: writer schema inference and overrides.
- `src/qio.c`: writer bridge and native registration.
- `src/qio_file.c`: handles, metadata, collection, and batches.
- `src/{carquet,zstd,lz4}/`: vendored libraries.

Keep physical decoding in C and logical reinterpretation in the shared R read
plan. `qio_type_registry()` owns physical fallbacks; `qio_apply_plan()` must
keep `read_parquet()`, `collect()`, and `walk_batches()` consistent.

`read_parquet()` is `open_parquet()` plus `collect()`. Open files are external
pointers with finalizers. Native entry points must validate the pointer and
respect the open/busy guards; close must remain idempotent. Eager reads request
mmap and may decode numeric columns in parallel. Persistent handles default to
buffered I/O.

## Editing rules

- Use two-space indentation in R and four spaces in package-owned C.
- Prefer base R pipes (`|>`), `lower_snake_case`, and `qio_` for internal
  helpers.
- Preserve the goal of zero required runtime R dependencies unless a recorded
  design decision says otherwise.
- Export and document public functions. Do not create roxygen topics for
  internal helpers.
- Regenerate `man/` and `NAMESPACE`; never edit generated `.Rd` files.
- Wrap roxygen text at 80 characters and run `air format .` for R sources.
- **Renaming anything public means a sweep of the whole repository, not of
  `R/` and `tests/`.** `bench/`, `tools/`, `README.md`, `AGENTS.md`, `.agents/`
  and C comments all name public functions and result columns, and none of them
  is compiled or tested, so a stale reference there survives a green suite and
  a clean `R CMD check`. `tools/check-inspection-against-arrow.R` is the one
  that fails loudly; run it after any rename.
- **Do not add `NEWS.md` entries until 0.1.0 is released.** Its section is one
  line, `* Initial release.`, and stays that way: nothing before 0.1.0 was ever
  published, so there is no installed version for a change to be described
  against. Record the reasoning in `.agents/` and the behavior in the reference
  documentation instead. **After 0.1.0 ships**, add a short `NEWS.md` item for
  every user-visible change.

**Never edit `src/carquet` in place.** qio vendors it from the `qio` branch of
[the carquet fork](https://github.com/pedrobtz/carquet), where every local
change is its own commit on top of a pinned upstream commit. Make the change
there, push it, re-copy, and update the fork pin in
[`.agents/VENDORED.md`](.agents/VENDORED.md), which also documents re-vendoring
and how a patch becomes an upstream pull request. `tools/check-vendor-drift.sh`
fails CI on a vendored file edited in place, and on a ledger that disagrees with
the series. The same rule applies to `src/zstd` and `src/lz4`: re-vendor rather
than patch.

`src/Makevars*` declares vendored headers as prerequisites, so a header change
rebuilds every object on its own; `tools/check-header-deps.sh` proves it. A
manual clean is a valid reset but is no longer required.

Two things about `load_all()` worth knowing before trusting a build:

- **It compiles at `-O0`.** Never time anything built with it. Pass
  `debug = FALSE` for `-O2`, or install. See `bench/README.md`.
- **It decides whether to compile from `qio.so`, not from the object files.**
  Deleting `src/*.o` alone leaves the library in place, so `load_all()` skips
  compiling and silently keeps whatever flags built it. Use
  `pkgbuild::clean_dll()` for a real reset.

Treat native changes as platform-sensitive. ARM64 uses NEON; typical x86 builds
use scalar fallbacks. The workflows under `.github/workflows/` cover Linux,
Windows, sanitizers, Valgrind, LTO, rchk, and gctorture. `gctorture` is its own
workflow and runs only when `src/**` changes, because it costs about nine times
the other native jobs combined; dispatch it by hand for a release or for a
change that alters how C is called without changing C.

## Build and test

Run commands from the repository root:

```sh
Rscript -e 'devtools::load_all()'                  # compile and load (-O0)
Rscript -e 'devtools::load_all(debug = FALSE)'     # same, but -O2
Rscript -e 'devtools::test(filter = "parquet-plan")' # focused tests
Rscript -e 'devtools::test()'                      # full test suite
Rscript -e 'devtools::document()'                  # regenerate docs
Rscript -e 'devtools::check()'                     # R CMD check
Rscript -e 'pkgdown::check_pkgdown()'              # reference index
air format .                                       # format R sources
```

Building requires GNU make and system zlib; zstd and LZ4 are bundled.

Tests use testthat edition 3. Mirror `R/foo.R` with
`tests/testthat/test-foo.R`, add focused coverage for every behavior change,
and run the full suite before handoff. Use `withr` for temporary resources and
snapshots for user-facing messages. Keep interoperability fixtures under
`tests/testthat/parquet/`, with provenance in the adjacent `SOURCE.md`.

## Commits and pull requests

Use short, imperative commits, optionally scoped, and keep each commit focused.
Pull requests should explain behavior and rationale, link relevant issues, list
checks run, and flag platform-sensitive or vendored changes. Include evidence
for performance claims.
