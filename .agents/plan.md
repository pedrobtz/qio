# qio v0.1.0 implementation plan

Last updated: 2026-08-01

This plan turns the [`roadmap.md`](roadmap.md) priorities into an execution
order. The roadmap owns scope; [`TYPES.md`](TYPES.md) owns type behavior;
[`carquet.md`](carquet.md) and [`VENDORED.md`](VENDORED.md) own native
constraints. Change those sources before changing this plan's interpretation of
them.

## Release outcome

v0.1.0 is complete when:

- every required phase below has passed its exit gate;
- the deliberate exclusions in the roadmap remain excluded and fail clearly;
- supported files produce consistent results through `read_parquet()`,
  `collect()`, and `walk_batches()`;
- failed reads and writes leave no invalid handles or partial output;
- the source package builds and checks on supported platforms; and
- the README, reference site, NEWS, benchmarks, and vendored-code record match
  the shipped behavior.

## Working rules

- Complete phases in dependency order. Work inside a phase may use separate,
  focused pull requests.
- A checked implementation item is not complete until its tests,
  documentation, and exit gate pass.
- Add interoperability fixtures with provenance in
  `tests/testthat/parquet/SOURCE.md` as each format feature lands; do not defer
  them to release week.
- Add a `NEWS.md` entry for every user-visible change.
- Clean native objects before testing any vendored-header change.
- Measure before and after performance work on the same fixture, machine, and
  build configuration. Keep the benchmark reproducible.
- If work changes scope, update `roadmap.md` first. Do not pull nested values,
  predicates, raw-vector I/O, or other deferred features into v0.1.0.
- Every exit-gate line names its evidence: a test file, a workflow job, or a
  benchmark command. A gate that cannot be checked mechanically is not a gate.
- Keep the `Status:` line under each phase heading current.

## Dependency order

```text
P. Native glue preflight
          |
0. Scope and baseline
          |
1. Vendored foundation
          |
2. Read identity and planning
       /     |      \
3. Types  4. Reader  5. Writer
       \     |      /
  6. Inspection and writer controls
          |
7. Interoperability and documentation
          |
8. Release validation
```

Phase P precedes phase 0 so that baselines are recorded against corrected glue.
Phases 3 through 5 may proceed independently after phase 2. Phase 5 has its own
entry gate for writer configuration; that decision does not block phases 1
through 4. Phase 6 may begin earlier where it does not depend on unfinished
writer configuration, but it must pass together with phases 3 through 5 before
release work begins.

## Phase P: native glue preflight

Status: complete, except for one gate that no available tool covers; see the
exit gate.

Defects and dead code found by reviewing `src/qio.c` and `src/qio_file.c`
against the carquet headers and the R callers. None of this is new feature
work. Complete it before phase 0 so the recorded baselines and benchmarks
measure corrected code, and so later phases do not build on a known-wrong
mapping or an unprotected write loop.

Three items overlap later phases. Preflight fixes the defect; the later phase
still owns the full contract:

| Item | Preflight does | Owner of the rest |
|---|---|---|
| INT32 sentinel | Correct the mapping, add a fixture | Phase 3.1 warning aggregation |
| Writer unwind safety | Stop the leak and the truncated file | Phase 5 chunking and interrupts |
| Worker-pool submit | Remove the stall, fix the comment | Phase 4 measured optimization |

### Work

Correctness

- [x] Stop mapping a stored INT32 `-2147483648` to `NA`. `NA_INTEGER` is
  `INT_MIN`, so `src/qio_file.c:426` (dense `memcpy`) and `src/qio_file.c:341`
  (nullable copy) turn a legal Parquet value written by other tools into a
  missing value with no warning. Decide the mapping in `TYPES.md` first, then
  implement it and add a third-party fixture; qio's own writer cannot produce
  the value, so no existing test covers it.
- [x] Protect the write loop with `R_UnwindProtect`. Nothing between
  `carquet_writer_create` (`src/qio.c:183`) and `carquet_writer_close`
  (`src/qio.c:319`) survives a longjmp, and two are reachable inside it:
  `Rf_translateCharUTF8` (`src/qio.c:292`) on untranslatable strings, and the
  `nrow`-sized `R_alloc` calls (`src/qio.c:196` and each type branch) on
  allocation failure. Either leaks the writer and schema and leaves a truncated
  file. Cleanup must abort the writer and free the schema.
- [x] Fix the signed-overflow guard at `src/qio_file.c:859`. The product inside
  the cast is widened to `size_t`, but the `n_groups * ncol > 0` test is
  evaluated in `int`; on overflow it takes the one-element branch and the fill
  loop writes past the allocation. Compute the product once into an `int64_t`
  and branch on that.

Boundary validation

- [x] Add the missing `TYPEOF` guards in `qio_prepare_selection`:
  `STRING_ELT(columns, i)` (`src/qio_file.c:634`) and
  `INTEGER(row_groups)[i]` (`src/qio_file.c:689`) both assume a type the C
  layer never checks, while `path` and `callback` are checked at their entry
  points. R validates today; the asymmetry is what fails later.
- [x] Reject `batch_size < 1` in C. At `src/qio_file.c:992` a non-positive
  batch size never terminates, and `NA_INTEGER` grows `remaining` while
  allocating a batch per iteration.
- [x] Assert `k == nrow` in the writer's non-nullable branches. With
  `nullable[c] == 0` any `NA` is skipped while `n = nrow` is still passed to
  `carquet_writer_write_batch`, so the tail would be uninitialized. R blocks
  this today; the comment at `src/qio.c:102` already claims C re-validates
  before creating output, but it re-checks storage types only.

Performance and diagnostics

- [x] Stop the submit stall in parallel collect. `src/qio_file.c:897` submits
  every task before the main thread starts its string pass, but the pool queue
  holds 512 tasks and `carquet_worker_pool_submit` blocks when full despite its
  header comment. Past 512 (row group x numeric column) pairs the string decode
  starts late. Interleave submission with string work, and correct the overlap
  comment at `src/qio_file.c:911`.
- [x] Make a long parallel collect interruptible around
  `carquet_worker_pool_wait` (`src/qio_file.c:964`).
- [x] Replace `qio_leaf_node` (`src/qio_file.c:199`) with one pass that
  collects leaf nodes. It rescans every schema element per leaf, so `schema()`
  is quadratic in schema size.
- [x] Give the embedded-NUL failure a qio message naming the column path
  instead of `Rf_mkCharLenCE`'s generic error (`src/qio_file.c:366` and
  `src/qio_file.c:500`). Full UTF-8 validation stays in phase 3.2.

Cleanup

- [x] Remove write-only state: `handle->use_mmap` and
  `handle->verify_checksums` (`src/qio_file.c:1107`), which the mmap decision
  bypasses in favor of `carquet_reader_is_mmap`, and `context->walk`
  (`src/qio_file.c:54`).
- [x] Wire up or delete `QIO_CHUNK` (`src/qio.c:41`). It is unused, and its
  presence implies a chunked writer that does not exist.
- [x] Bind the callback arguments in an environment instead of splicing the
  batch data frame into the call as a literal (`src/qio_file.c:792`). Results
  are correct today, but an error inside a user callback deparses the whole
  batch into the traceback.
- [x] Remove the stale "not yet validated on Windows" note in
  `src/Makevars.win`; `R-CMD-check` has covered `windows-latest` for some time.
- [x] Record the Windows non-ASCII path limitation. Both `Rf_translateChar`
  call sites (`src/qio.c:72`, `src/qio_file.c:1089`) convert to the native
  encoding, which is the ANSI code page on Windows. The real fix needs
  wide-character support in carquet, so this is an upstream item plus a
  documented limitation, not a code change here.

### Exit gate

- [x] A third-party fixture containing INT32 `-2147483648` reads back per the
  mapping recorded in `TYPES.md`, and never as a silent `NA`.
- [x] A forced translation failure inside the write loop leaves no leaked writer
  or schema and no file at all. Covered by `test-qio.R`; before the fix the same
  input left an empty orphan file.
- [x] Every native entry point validates the type of every argument it
  dereferences, and the range of `threads` and `batch_size`.
- [x] Sanitizer, Valgrind, and gctorture workflows pass on the corrected glue.
  `native-checks` run 30700895527 on `2d6a50d`: sanitizers, Valgrind, LTO,
  gctorture, and rchk all green. rchk in particular covers the `PROTECT`
  balance in the new raw-vector and callback-environment code.
- [ ] Allocation failure inside the write loop is covered. Still open, and the
  sanitizer run does not close it: ASan and Valgrind do not make allocations
  fail, so nothing yet exercises the `R_alloc` failure path. Closing this needs
  a malloc-fault-injection harness. The translation-failure path through the
  same cleanup is covered by `test-qio.R`, so the cleanup itself is exercised;
  what is untested is that branch reaching it.
- [x] No write-only struct fields, unused constants, or stale build comments
  remain in package-owned C.

## Phase 0: lock scope and establish baselines

Status: complete

### Recorded baseline

Taken on the commit that completed phase P, from a clean tree on R 4.6.1,
`aarch64-apple-darwin23`, 8 cores.

| Baseline | Result |
|---|---|
| `devtools::test()` | 236 pass, 0 fail, 0 warn, 0 skip |
| `devtools::check()` | 0 errors, 0 warnings, 0 notes |
| `pkgdown::check_pkgdown()` | Fails: `url` missing in `_pkgdown.yml` |
| Benchmarks | [`bench/README.md`](../bench/README.md) |

The `R CMD check` note about `AGENTS.md` and `CLAUDE.md` at top level was fixed
here by adding both to `.Rbuildignore`. The pkgdown failure is left open: it
needs the published site URL and is already owned by phase 7.

Three baseline facts worth carrying forward rather than rediscovering:

- Run-to-run noise is bimodal. Serial cases repeat to within 3%, but the two
  worker-pool cases vary 11-12%, so the regression gate uses per-case
  tolerances rather than one number. Filtered runs are measurably faster than
  the same case inside a full run and must not be compared across the two.

- Buffered and mmap collects are the same speed when serial; the 2.7x gap is
  the worker pool, not the mapping. Phase 4's question about private-reader
  parallelism therefore starts from evidence that it is worth ~2.7x on the
  `parquet_open()` default.
- `walk_batches()` costs about 35% more than `collect()` for a full pass.

### Work

- [x] Confirm the v0.1.0 type boundary: complete shared planning, scalar,
  binary/text, decimal, temporal, and integer-width work. Nested and extension
  types remain deferred.
- [x] Record a clean baseline for the full test suite and R CMD check.
- [x] Establish reproducible read and write benchmark commands, fixtures,
  environment details, and reported metrics. Name the reference workloads that
  later phases must not regress, and set the regression threshold that fails a
  performance gate.
- [x] Choose the independent Parquet cross-check tool used by the phase 5, 6,
  and 7 gates. Record which tool and version, whether it runs in CI or only
  when fixtures are regenerated, and how its results become checked-in
  expectations. It must never become a test-time dependency of the package.
- [x] Turn any known baseline failure into an explicit roadmap item or fix it
  before feature work begins.

### Exit gate

- [x] `roadmap.md`, `TYPES.md`, and this plan agree on release scope.
- [x] Test, check, and benchmark baselines are reproducible from a clean tree,
  with named reference workloads and a numeric regression threshold.
- [x] The independent cross-check tool is chosen and its output location is
  recorded in `tests/testthat/parquet/SOURCE.md`.

## Phase 1: make the vendored foundation reproducible

Status: complete except for the best-effort upstream submission, which does not
block the release.

### What the work turned up

- The header-dependency rule was necessary and its absence is silent.
  `R CMD INSTALL` rebuilt **0 of 79** objects after a shared header changed
  without the rule, and all 79 with it. `devtools::load_all()` precleans, so it
  rebuilds everything either way and can never reveal this.
- Adding any rule to `Makevars` makes it make's default goal, because Makevars
  is read before R's own makefiles. Without a leading `all: $(SHLIB)` the build
  stops after one object and links nothing.
- The batch pipeline is far narrower than "compressed and mapped": every
  projected column must also be non-nullable. Arrow writes nullable columns by
  default, so most third-party files never reach the worker pool at all.

### Work

- [x] Generate one authoritative `.agents/carquet-changes.patch` against the
  pinned upstream commit. It applies to pristine upstream to reproduce
  `src/carquet` exactly, and reverses to recover pristine upstream.
- [x] Add a CI check that reverse-applies the patch to the vendored tree and
  fails on drift. Verify that `.Rbuildignore` still excludes `.agents/` from the
  R source package. `tools/check-vendor-drift.sh`, run by the `vendor`
  workflow; verified to fail on injected drift.
- [x] Add vendored-header dependencies to `src/Makevars` and
  `src/Makevars.win`; prove that touching a shared header rebuilds all affected
  objects. `tools/check-header-deps.sh`, verified to fail with the rule removed.
- [x] Add a Windows CI case that forces mmap with at least two threads and
  compares its result with the serial path. Covered by tests in
  `test-parquet-file.R`, which `R-CMD-check` already runs on `windows-latest`.
- [x] Make `walk_batches(threads = 1)` start no second worker, patching the
  vendored batch pipeline locally if upstream has not fixed it.
- [ ] Best effort: submit or update upstream changes for every local carquet
  patch. If the required fixes are merged before release validation begins,
  re-vendor from the new pin and update `VENDORED.md` and the patch record. If
  they are not, ship on the current pin with the patches documented and open a
  v0.2.0 re-vendor item in `roadmap.md`. Upstream cadence must not block the
  release.

### Exit gate

- [x] The patch drift check passes from a clean checkout.
  `tools/check-vendor-drift.sh` exits 0 clean and 1 on drift.
- [x] A vendored-header change cannot reuse ABI-incompatible objects.
  `tools/check-header-deps.sh`, with the negative control above.
- [x] A focused test in `test-parquet-file.R` shows that
  `walk_batches(threads = 1)` creates no second worker. It counts process
  threads, with `threads = 2` as a control so a broken probe cannot pass, and
  skips where no thread-count probe exists (Windows).
- [x] Serial and threaded mmap reads agree on Windows, Linux, and macOS.
  `R-CMD-check` run 30699868106 on `2d6a50d`: all five jobs green, including
  `windows-latest` and three `ubuntu-latest` R versions.
- [x] Native sanitizer, Valgrind, LTO, gctorture, and rchk workflows pass.
  `native-checks` run 30700895527 on `2d6a50d`, all five jobs green.
- [x] The `vendor` workflow passes on the branch. Run 30699868156 on
  `2d6a50d`: the patch-drift and header-dependency checks both pass from a
  clean CI checkout, not only on a developer machine.

## Phase 2: finish column identity and shared planning

Status: complete

### What the work turned up

Selecting by leaf name was not merely ambiguous, it was wrong on a file any
mainstream writer can produce. In `name_collision.parquet` a struct field `s.b`
and a flat column `b` share the leaf name `b`;
`carquet_schema_find_column("b")` returns the nested leaf, so asking for the
flat column failed with *"nested parquet column 'b' is not supported"*. Where
both candidates are flat, the same lookup would have returned the wrong column
silently. Selections now resolve to leaf indexes in R before any native call.

### Work

- [x] Resolve user selections to leaf indexes by complete schema path before
  entering carquet. Cover duplicate leaf names and collisions between flat and
  skipped nested leaves.
- [x] Settle the materializing-read option surface once, before phases 3.1 and
  3.4 invent separate mechanisms: where `int64`, `time`, and `tz` are accepted,
  how they reach the shared plan, how `read_plan()` reports them, and how
  defaults are validated before any allocation. Settled in
  [`roadmap.md`](roadmap.md#read-options): per-call arguments on the three
  materializing reads plus `read_plan()`, validated by one shared
  `qio_read_options()` constructor. The arguments themselves ship with the
  modes that need them, in 3.1 and 3.4; no argument is added here that would
  accept a value qio cannot yet honor.
- [x] Audit the schema-driven read plan so allocation, null handling, physical
  fallback, logical conversion, and class assignment are selected once.
- [x] Keep `qio_type_registry()` authoritative and generate
  `parquet_type_mapping()` from it.
- [x] Make unsupported-type diagnostics include the complete column path,
  physical type, logical type, and relevant parameters.
- [x] Verify that eager reads, persistent collection, and batch walking apply
  identical plans for projection, row-group selection, nulls, and zero-column
  results.

### Exit gate

- [x] Complete-path selection is unambiguous across every read API.
- [x] A test regenerates `parquet_type_mapping()` from `qio_type_registry()` and
  fails on any difference, so documented mappings cannot drift from native
  behavior.
- [x] The read-option surface is fixed and documented in `roadmap.md`.
  `read_plan()` reporting each selected mode is verified in 3.1, with the first
  argument that has a mode to report.
- [x] Focused plan, projection, row-group, nested-skip, and batch tests pass in
  `test-parquet-plan.R` and `test-parquet-file.R`.

## Phase 3: complete v0.1.0 type coverage

Status: complete for reads. Writes of types with no unambiguous R
representation, and exact fixed-point decimal, are deferred to v0.2.0 by a
recorded scope decision in `roadmap.md`.

### What 3.1 turned up

Reading 64-bit integers was wrong in three distinct ways, not just imprecise.
A stored `18446744073709551615` came back as `-1`, because an unsigned column
was widened as if signed; values between `2^53` and `2^63 - 1` rounded
silently; and `INT64_MAX` rounded *past* itself to `9223372036854775808`.

The range check also has to be told which columns it applies to. A `TIMESTAMP`
is physically INT64, and range-checking a nanosecond timestamp against `2^53`
turns every instant after 1970-04-15 into `NA`. The read plan already knows
which INT64 leaves are plain integers, so it passes a per-column flag rather
than letting C infer it from the schema a second time.

Implement the contracts in [`TYPES.md`](TYPES.md#conversion-contracts) in this
order. All four groups depend on the phase 2 read-option surface.

- [x] Materialize the Parquet `NULL` logical type as all-`NA` logical while
  preserving row count.

### 3.1 64-bit integers

- [x] Add signed and unsigned `double` and optional `bit64::integer64` modes.
- [x] Preserve original bits until range checks are complete and aggregate
  warnings once per operation.
- [x] Test `2^53`, signed `-2^63`, unsigned `2^63 - 1`, nulls, projection, row
  groups, and batches. Fixture `int64_boundaries.parquet`, written by Arrow
  because qio has no unsigned 64-bit writer.

### 3.2 Text, binary, and exact identifiers

- [x] Restrict character conversion to text annotations. Only `STRING`,
  `ENUM`, and `JSON` become character; this changes existing behavior, and the
  Apache reference `alltypes_*` fixtures are affected. Recorded in `NEWS.md`.
- [x] Materialize variable and fixed binary as raw-vector list-columns, with
  `NULL` for null values. `FIXED_LEN_BYTE_ARRAY` is now readable.
- [x] Add JSON, BSON, ENUM, UUID, and FLOAT16 read mappings.
- [x] Symmetric writes: deferred to v0.2.0 with the other exotic writes; see
  `roadmap.md`. `write_parquet()` already rejects these R inputs clearly.
- [x] Validate UTF-8 and fixed widths, and reject malformed UUID and FLOAT16
  widths.
- [x] Add fixtures for a `UUID` column and for a text column holding invalid
  UTF-8, via `tools/generate-type-fixtures.c` built on carquet's writer.
  Neither Arrow nor qio's writer can produce them.

### 3.3 Decimal

- [x] Decode `INT32`, `INT64`, `BYTE_ARRAY`, and `FIXED_LEN_BYTE_ARRAY`
  decimals, applying the declared scale. Byte-array storage is big-endian
  two's complement.
- [x] Emit one message per read that decimal columns were read as `double` and
  may be inexact, and expose precision, scale, and storage through `schema()`
  and `read_plan()`.
- [x] Deferred to v0.2.0: exact fixed-point character, and explicit decimal
  writes with exact parsing and pre-write validation. Reading as `double`
  replaces returning the unscaled integer or the raw bytes, both of which were
  silently the wrong quantity.

### 3.4 Temporal and annotated integers

- [x] Finish UTC and non-UTC timestamp reads with validated `tz` and documented
  DST behavior. A UTC-adjusted column is an instant that `tz` only displays; a
  non-UTC column is a wall clock re-anchored in `tz`, with base R deciding
  ambiguous and nonexistent civil times. `tz` is validated before any
  allocation, and the machine's local zone is never used implicitly.
- [x] Add numeric and optional `hms` time-of-day modes.
- [x] Add remaining signed/unsigned integer-width annotations. Unsigned 32-bit
  reads as `double`, since a stored `4294967295` read as `-1` before.
  `INTERVAL` needs no work here; 3.2 already returns its 12 bytes exactly.
- [x] Add boundary fixtures for every timestamp unit and integer width:
  `temporal_types.parquet`, written by Arrow because qio's writer has no
  unsigned, narrow-integer, `TIME`, or non-UTC timestamp support.
- [ ] Deferred to v0.2.0: writing a non-UTC `TIMESTAMP`, with the
  operation-level message specified in `TYPES.md`. `POSIXct` still writes as a
  UTC-adjusted `TIMESTAMP`, which is the correct default; choosing a zone on
  write belongs with the other deferred write decisions.

### Exit gate

- [x] Every supported mapping has null, projected-column, row-group, batch,
  boundary, and malformed-input coverage. Round-trip coverage applies only to
  types qio can write; the rest are verified against third-party fixtures,
  since writes are deferred to v0.2.0.
- [x] All three materializing read APIs return the same type and values.
  Asserted per type group in `test-external.R`, including under projection,
  row-group selection, and batching.
- [x] Optional modes fail clearly when their suggested package is unavailable.
  `test-parquet-plan.R` mocks the namespace lookup, since `bit64` and `hms`
  are installed in development and the branch would otherwise never run.
- [x] Nested values, extension types, and a dedicated interval class remain
  outside v0.1.0. `GEOMETRY`, `GEOGRAPHY`, and `INTERVAL` read as exact bytes
  through the binary mapping; `VARIANT` is skipped as nested.

## Phase 4: bound reader memory and optimize measured hot paths

Status: memory items complete. The buffered-parallelism decision is measured
but not implemented; the remaining optimizations are unstarted.

### What the measurements show

- Buffered and memory-mapped reads are the same speed when serial (0.180 s vs
  0.177 s, 1.02x). The 2.64x gap is entirely the worker pool. Private-reader
  parallelism for buffered handles is therefore worth about 2.6x on the
  `parquet_open()` default, which means the plan's "or record why it is not
  justified" branch is not available on the evidence.
- Chunked string scratch costs `read-string_low_cardinality` 6.6%, recorded as
  an accepted trade-off in `bench/README.md`. Materializing dictionary text
  from indexes targets that same workload and would recover it.

### Work

- [x] Read strings in sub-batches so scratch memory is bounded by
  `batch_size`, not the largest selected row group.
- [x] Give `collect(batch_size =)` observable, documented behavior. It bounds
  the reader's scratch, not the result; before this it had no effect at all.
- [ ] Materialize dictionary text from indexes when safe and fall back for
  plain or mixed encoding without changing the R result.
- [ ] Add a statistics-driven no-null path only if benchmarks show a useful
  improvement.
- [ ] Decode suitable numeric columns into R-owned memory and expand nullable
  values backward in place.
- [ ] Benchmark buffered persistent reads. Either implement private-reader
  parallelism with correct ownership or record why it is not justified for
  v0.1.0. **Benchmarked: it is justified** (2.64x on the default handle), so
  the recording branch is closed and the implementation is outstanding. It
  needs one independent `carquet_reader_t` per worker, since the buffered path
  shares `FILE*` and prebuffer state; each private reader re-parses the footer,
  so the gain has to be amortized against that for small reads.

### Exit gate

- [x] Peak string scratch scales with `batch_size`, not with the largest
  selected row group. Bound: `min(batch_size, rows in the row group)` times the
  value width, 16 bytes for a byte-array descriptor plus 2 for a definition
  level. Instrument: `gc()`'s "max used" Vcells, since `R_alloc` draws from R's
  vector heap. Measured on a 2-million-row file: a flat ~81 MB at every
  `batch_size` before, 67 MB at 16k rows after. Asserted in
  `test-parquet-file.R`.
- [ ] Dictionary, plain, and mixed pages return identical character results.
- [ ] Performance changes include reproducible evidence from the reference
  workloads and stay within each case's tolerance
  (`Rscript bench/benchmark.R --compare <tag>` exits non-zero otherwise).
  Changes to the parallel path also report `collect-mmap-serial` and
  `collect-buffered`, whose tolerances are tight enough to be meaningful.
- [ ] Valgrind, sanitizers, and gctorture pass the new allocation paths.

## Phase 5: harden and configure the writer

Status: not started

### Entry gate

- [ ] The remaining writer-configuration choices in `roadmap.md` are resolved:
  constructor and argument names, row-group sizing units, v0.1.0 fields,
  defaults, and global and per-column dictionary controls. Configuration work
  in this phase does not start until they are.

### Work

- [ ] Write bounded chunks, check user interrupts between chunks, and protect
  cleanup with `R_UnwindProtect`.
- [ ] Abort after write failures but never after `carquet_writer_close()` has
  consumed the handle. Test interruption and every failure stage.
- [ ] Validate schema and configuration before creating or truncating output.
- [ ] Preserve contextual carquet write errors through the C and R boundaries.
- [ ] Implement the resolved reusable configuration object with global and
  complete-path per-column settings.
- [ ] Keep `parquet_schema()` responsible for types and verify that the default
  configuration preserves current `write_parquet()` output choices.
- [ ] Add reproducible write benchmarks before attempting optimizations.

### Exit gate

- [ ] Interrupted and failed writes release native resources and do not leave a
  file that appears successfully complete.
- [ ] All configuration is validated before output mutation and is reusable
  across writes.
- [ ] Codec, null, row-group, page, and per-column configuration tests pass.
- [ ] Writer round trips pass against qio and independent Parquet readers.

## Phase 6: expose the remaining inspection and writer controls

Status: not started

This phase carries the most optional scope in the release. Each item is labelled
Required or Deferrable; deferrable items ship only if they land complete and
tested before phase 7 begins.

### Work

- [ ] Required: add column statistics and column-chunk metadata inspection.
- [ ] Required: add file validation helpers with useful error context.
- [ ] Required: add explicit row-group boundaries.
- [ ] Required: add writer key/value metadata.
- [ ] Required: document unsupported carquet capabilities instead of exposing
  incomplete wrappers.
- [ ] Deferrable: add column-index and offset-index inspection with explicit
  ownership cleanup. Do not add predicate evaluation or pushdown.
- [ ] Deferrable: add append mode with qio-side complete schema compatibility
  checks.
- [ ] Deferrable: add sorting declarations, documenting that they do not sort or
  verify input.
- [ ] Deferrable: add bloom-filter inspection with explicit ownership cleanup.

### Descope order

Under schedule pressure, cut deferrable items in this order and record each cut
in `roadmap.md` before removing it here: bloom-filter inspection, sorting
declarations, append mode, page indexes. The required items stay in v0.1.0.

### Exit gate

- [ ] Every shipped object has documented ownership, stable print behavior, and
  malformed-file tests.
- [ ] Any cut item is recorded as deferred in `roadmap.md` and absent from the
  README feature matrix and reference index.
- [ ] If append mode ships, it rejects incompatible logical parameters and
  parent paths before writing.
- [ ] Inspection results agree with the independent Parquet tool chosen in
  phase 0.

## Phase 7: complete interoperability and release documentation

Status: not started

### Work

- [ ] Audit the fixture corpus across physical types, logical annotations,
  encodings, data-page versions, null patterns, and row-group layouts.
- [ ] Record generator, version, command, license, and expected behavior for
  every fixture in `SOURCE.md`.
- [ ] Add a README feature matrix that separates read, write, inspect, and
  deferred support.
- [ ] Publish reproducible read/write benchmark instructions and results without
  presenting development measurements as guarantees.
- [ ] Replace `url: ~` in `_pkgdown.yml`, validate the reference index, and
  build the site without warnings.
- [ ] Document every bundled license, copyright holder, pin, and local patch.
- [ ] Regenerate roxygen output and complete the v0.1.0 `NEWS.md` section.

### Exit gate

- [ ] Documentation describes actual behavior, defaults, limitations, and
  deliberate exclusions.
- [ ] The built source package contains required licenses and excludes internal
  plans, patch records, build products, fixtures not intended for distribution,
  and local data.
- [ ] `pkgdown::check_pkgdown()` passes.

## Phase 8: release validation

Status: not started

### Work

- [ ] Clean all native objects and build from a fresh checkout.
- [ ] Run `devtools::document()`, the complete test suite, `devtools::check()`,
  and `pkgdown::check_pkgdown()`.
- [ ] Require green macOS, Windows, and Linux `R-CMD-check` runs. Dispatch
  `native-checks` against the release commit itself and require green
  sanitizer, Valgrind, LTO, gctorture, and rchk jobs; it does not run on every
  commit.
- [ ] Run win-builder and R-hub, including a sanitizer platform; resolve every
  actionable ERROR, WARNING, and NOTE.
- [ ] Inspect the source tarball for object files, build products, patch
  records, and local artifacts; confirm that required vendored sources,
  licenses, generated documentation, and tests are present.
- [ ] Install and test from that source tarball, not only from the working tree.
- [ ] Set `Version: 0.1.0`, finalize NEWS and release metadata, then rerun the
  complete release matrix.
- [ ] Tag and publish v0.1.0 only from the verified release commit.

### Exit gate

- [ ] Every earlier exit gate remains green on the release commit.
- [ ] `Imports` remains empty; `bit64` and `hms` stay in `Suggests`, are reached
  only through opt-in modes, and their tests skip cleanly when absent.
- [ ] A clean user library can install qio from the source tarball and run the
  documented smoke examples without undeclared dependencies.
- [ ] The tag, source archive, documentation site, and package metadata identify
  the same version and commit.

## Maintenance

Update checkboxes as work merges. If an item is removed, deferred, or added,
record the scope change in `roadmap.md` and then update this plan. Keep detailed
type contracts and vendored patch rationale in their owning documents rather
than duplicating them here.
