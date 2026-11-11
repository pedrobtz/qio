# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## Shared conventions

The portfolio’s shared rules are synced into `.claude/shared/` from
`pedrobtz/packages:claude/shared/`. Never edit them here. Where this
file and a shared file disagree, this file wins for this package.

@.claude/shared/workflow.md @.claude/shared/r-package.md
@.claude/shared/ci.md @.claude/shared/native-code.md
@.claude/shared/correctness.md @.claude/shared/assurance.md

## What this is

`qio` reads and writes Apache Parquet files from R through the vendored
C library `carquet`. Whole files are read with one call; larger ones can
be opened to inspect their schema and read selected columns, row groups
or batches. The default API has no required runtime R dependencies (only
`utils`); optional result modes may use suggested packages such as
`bit64` and `hms`. Building needs GNU make and system zlib; zstd and LZ4
are bundled, and Rtools supplies zlib on Windows.

Before changing behaviour, read the document that owns it. They outrank
this file:

- [`.agents/TYPES.md`](https://pedrobtz.github.io/qio/.agents/TYPES.md)
  for Parquet-to-R mappings and conversion contracts.
- [`.agents/roadmap.md`](https://pedrobtz.github.io/qio/.agents/roadmap.md)
  for the current API, release scope and priorities.
- [`.agents/plan.md`](https://pedrobtz.github.io/qio/.agents/plan.md)
  for the ordered v0.1.0 work and exit gates.
- [`.agents/VENDORED.md`](https://pedrobtz.github.io/qio/.agents/VENDORED.md)
  before touching vendored code.
- [`.agents/carquet.md`](https://pedrobtz.github.io/qio/.agents/carquet.md)
  for the integration with the vendored carquet snapshot, and
  [`.agents/read-performance.md`](https://pedrobtz.github.io/qio/.agents/read-performance.md)
  for read performance against nanoparquet.
- [`bench/README.md`](https://pedrobtz.github.io/qio/bench/README.md)
  for the benchmark method, workloads, regression threshold and recorded
  baseline.

`.agents/research_arrow_nested/` is background research; where it
conflicts with `TYPES.md` or `roadmap.md`, those win. `AGENTS.md`
carries the older, self-contained version of these rules for other
agents; this file supersedes it for Claude Code.

## Current state

Version 0.1.1 is on CRAN (published 2026-09-29); the default branch is
`0.1.1.9000`, verified 2026-11-11. Since 0.1.1,
[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
writes binary, `GEOMETRY` and `GEOGRAPHY` columns with geospatial
statistics, and
[`geospatial_statistics()`](https://pedrobtz.github.io/qio/reference/geospatial_statistics.md)
reports them; see `NEWS.md`.

## Versions and dependents

The current version’s parent issue is \#18 (`v0.1.2`). Sibling packages
that depend on this one before CRAN does: zugeo
(`Suggests: qio (>= 0.1.1.9000)`, with `Remotes: pedrobtz/qio`).

## Commands

Beyond the shared commands:

``` sh
Rscript -e 'devtools::load_all(debug = FALSE)'       # compile at -O2
Rscript -e 'devtools::test(filter = "parquet-plan")' # focused tests
Rscript -e 'pkgdown::check_pkgdown()'                # reference index
Rscript -e 'pkgbuild::clean_dll()'                   # real build reset
Rscript tools/check-inspection-against-arrow.R       # after any rename
tools/check-vendor-drift.sh                          # vendored tree vs pins
tools/check-header-deps.sh                           # header rebuilds
```

Two things about `load_all()` worth knowing before trusting a build:

- **It compiles at `-O0`.** Never time anything built with it. Pass
  `debug = FALSE` for `-O2`, or install. See `bench/README.md`.
- **It decides whether to compile from `qio.so`, not from the object
  files.** Deleting `src/*.o` alone leaves the library in place, so
  `load_all()` skips compiling and silently keeps whatever flags built
  it. Use
  [`pkgbuild::clean_dll()`](https://pkgbuild.r-lib.org/reference/clean_dll.html)
  for a real reset.

`src/Makevars*` declares vendored headers as prerequisites, so a header
change rebuilds every object on its own; `tools/check-header-deps.sh`
proves it. A manual clean is a valid reset but no longer required.

Gate a performance change on `bench/benchmark.R --compare` on a quiet
machine, not on CI numbers.

## Architecture

The layers are R API -\> package-owned C glue -\> vendored C libraries.

- `R/parquet.R`: eager I/O and user-facing helpers.
- `R/parquet-file.R`: open handles, inspection, selection and
  collection.
- `R/parquet-plan.R`: shared read mapping and logical conversion.
- `R/parquet-schema.R`: writer schema inference and overrides.
- `src/qio.c`: writer bridge and native registration.
- `src/qio_file.c`: handles, metadata, collection and batches.
- `src/qio_path.c`: path handling.
- `src/{carquet,zstd,lz4}/`: vendored libraries.

[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md)
is
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
plus [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md).
Open files are external pointers with finalizers. Eager reads request
mmap and may decode numeric columns in parallel. Persistent handles
default to buffered I/O.

## Invariants that are easy to break

- **Physical decoding in C, logical reinterpretation in the shared R
  read plan.** `qio_type_registry()` owns physical fallbacks;
  `qio_apply_plan()` must keep
  [`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md) and
  [`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
  consistent.
- **Handles.** Native entry points must validate the external pointer
  and respect the open/busy guards; close must stay idempotent.
- **Renaming anything public means a sweep of the whole repository, not
  of `R/` and `tests/`.** `bench/`, `tools/`, `README.md`, `AGENTS.md`,
  `CLAUDE.md`, `.agents/` and C comments all name public functions and
  result columns, and none of them is compiled or tested, so a stale
  reference there survives a green suite and a clean `R CMD check`.
  `tools/check-inspection-against-arrow.R` is the one that fails loudly;
  run it after any rename.
- **Native changes are platform-sensitive.** ARM64 uses NEON; typical
  x86 builds use scalar fallbacks. Windows has its own code paths:
  code-page path handling with its mmap fallback, and the per-thread
  zstd context that only ever broke there.
- **`NEWS.md`.** Every user-visible change gets a short `NEWS.md` item
  now that 0.1.0 has shipped. (Before 0.1.0 the rule was the opposite:
  the section stayed `* Initial release.`.)
- **Style deviation:** package-owned C uses four-space indentation; R
  uses two. Internal R helpers are prefixed `qio_`, and R uses base
  pipes (`|>`).

## Testing

- Mirror `R/foo.R` with `tests/testthat/test-foo.R`.
- Interoperability fixtures live under `tests/testthat/parquet/`, with
  provenance in the adjacent `SOURCE.md`. The `tools/generate-*` scripts
  build them.
- `helper-warnings.R`: `collect_warnings()` captures every warning an
  expression raises, with its value, because `expect_warning()` consumes
  only one and the per-column coercion warnings need counting.
- `helper-wkb.R`: little-endian ISO WKB builders for test geometries.
- `tools/check-writer-against-arrow.R` and
  `tools/check-inspection-against-arrow.R` cross-check against arrow.
- `.covrignore` leaves `src/carquet`, `src/zstd` and `src/lz4` out of
  coverage, because they outnumber the package’s own C fifty to one.
  Package-owned `src/qio*.c` is deliberately counted.

## Continuous integration

- `R-CMD-check.yaml`: **deviation**, still a hand-rolled `r-lib/actions`
  matrix rather than a call to r-actions’ `r-cmd-check.yml`, so it does
  not yet count as the pre-submission check; \#16 tracks the adoption.
  It runs Windows R-devel on every commit because of the Windows-only
  paths above.
- `native-checks.yml`: r-actions’ sanitizers, Valgrind, LTO and rchk.
  Pull requests run a quick profile: UBSan without the ASan containers
  or Valgrind.
- `gctorture.yml`: its own workflow, run only when `src/**` changes
  (vendored trees included), because it costs about nine times the other
  native jobs combined. Pull requests run gctorture at step 500 instead
  of 20. Dispatch it by hand for a release or for a change that alters
  how C is called without changing C.
- **Deviation from `ci.md`:** label a pull request `full-ci` to run the
  full set before merging, and pushes to `main` always run the full
  profile, not the quick one.
- `vendor.yml`: `src/carquet` must be exactly the pinned commit of the
  fork’s `qio` branch, that branch the upstream pin plus one commit per
  ledger entry, and a shared vendored header change must rebuild every
  object.
- `benchmark.yml`: publishes `benchmark` and `compare-readers` tables
  and CSVs on every run. It does not gate on performance; it fails only
  on `--max-seconds`.
- `coverage.yaml`: r-actions’ coverage. `pkgdown.yaml`: the site.
- \#24 tracks gating jobs on documentation-only pull requests.

## Vendored native code

Pins, licences, the patch ledger and the re-vendoring procedure are in
[`.agents/VENDORED.md`](https://pedrobtz.github.io/qio/.agents/VENDORED.md):
carquet v0.6.0 (MIT) via the `pedrobtz/carquet` fork’s `qio` branch,
zstd v1.5.7 (BSD-3-Clause), lz4 v1.10.0 (BSD-2-Clause).

**Never edit `src/carquet` in place.** qio vendors it from the `qio`
branch of [the carquet fork](https://github.com/pedrobtz/carquet), where
every local change is its own commit on top of a pinned upstream commit.
Make the change there, push it, re-copy, and update the fork pin in
`.agents/VENDORED.md`, which also documents how a patch becomes an
upstream pull request. `tools/check-vendor-drift.sh` fails CI on a
vendored file edited in place, and on a ledger that disagrees with the
series. The same rule applies to `src/zstd` and `src/lz4`: re-vendor
rather than patch.

**Deviation from `native-code.md`:** the fork’s commit series, not
`tools/patches/` and `src/vendor/PROVENANCE`, is the patch record, and
the vendored trees sit directly under `src/`.

Open vendoring work:

- \#4 re-vendor carquet to v0.7.x;
- \#5 fail when the fork’s CI is red at the pin;
- \#6 guard `carquet_column_set_preserve_dictionary()`;
- \#7 upstream the remaining patches;
- \#8 re-benchmark the performance patches against v0.7.0;
- \#17 take zstd and lz4 from zukomp.
