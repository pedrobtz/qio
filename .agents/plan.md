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

Status: complete.

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
- [x] Fix, rather than record, the Windows non-ASCII path limitation. The
  original reading was that this needed wide-character support upstream and so
  could only be documented. That was wrong: carquet already accepts a
  caller-owned `FILE*` for both reading and writing, so qio can open the file
  with `_wfopen()` and hand over the stream, and no vendored change is needed.
  Only mapping still takes a path, and a mapped read of an unrepresentable path
  falls back to buffered I/O. Implemented in `src/qio_path.{h,c}`, used by both
  `src/qio.c` and `src/qio_file.c`, including the per-lane readers. The
  buffered route is the default everywhere, so every platform's CI exercises
  it; what only Windows runs is the UTF-16 conversion.

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
- [x] Cleanup after a failure inside the write loop is covered. Closed by
  argument rather than by a fault-injection harness, because the gate as first
  written asked for something that cannot be built at proportionate cost and
  would add little. `R_alloc` failure raises R's error mechanism directly, and
  making it fail on demand needs a patched R; `carquet_set_allocator()` does
  not help, since it governs carquet's allocations rather than `R_alloc` and is
  documented as a process-wide setup call, not something to swap mid-session.
  What the gate is really about is that a longjmp out of the middle of a write
  leaves no writer, no schema, and no truncated file, and that path *is*
  exercised: the bytes-encoded-string test in `test-qio.R` raises from inside
  the same loop, through the same `R_UnwindProtect`, and asserts all three.
  An allocation failure would take exactly that route. What remains untested is
  only that one branch reaches it.
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
  `open_parquet()` default.
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

Status: complete. The two conditional optimizations were measured and closed
as not justified; see below.

### What the measurements show

- Buffered and memory-mapped reads are the same speed when serial (0.181 s vs
  0.179 s). The whole gap was the worker pool, and giving buffered handles
  private readers closed it: `collect-buffered` went to 0.063 s, level with the
  mapped parallel path.
- The first version of that change was wrong in a way worth remembering. It
  submitted the lanes to the pool *and* fell through to the inline loop, so
  every task ran twice, once on a worker and once on the main thread, against
  the same reader. The symptoms were short reads in about 1 of 10 collects and
  no speedup at all. Both were initially mis-read as a concurrency defect in
  carquet's buffered reader; the defect was in qio's dispatch. The lesson is
  that "no speedup" is diagnostic: parallel work that does not get faster is
  usually not running where it is thought to be.
- Chunked string scratch costs `read-string_low_cardinality` 6.6%, recorded as
  an accepted trade-off in `bench/README.md`. Materializing dictionary text
  from indexes targets that same workload and would recover it.

### Work

- [x] Read strings in sub-batches so scratch memory is bounded by
  `batch_size`, not the largest selected row group.
- [x] Give `collect(batch_size =)` observable, documented behavior. It bounds
  the reader's scratch, not the result; before this it had no effect at all.
- [x] Materialize dictionary text efficiently, falling back for plain or mixed
  encoding without changing the R result. Implemented without carquet's
  dictionary-preserving API, which is reachable only through the batch reader
  and has no public setter on a column reader: a dictionary page materializes
  every occurrence of a value as a pointer into one decoded entry, so caching
  CHARSXPs by that address gives the same saving with no coupling. Measured 200
  distinct addresses across 65536 rows on the reference column. The cache
  disables itself when it is not paying for itself, since a plain page gives
  every value a distinct address; without that it cost 9% on a high-cardinality
  column. `read-string_low_cardinality` 0.1130 s to 0.0615 s, -46%.
- [x] Add a statistics-driven no-null path only if benchmarks show a useful
  improvement. **Measured and declined.** Reading the same 2,000,000 doubles as
  REQUIRED (no definition levels at all) takes 0.0170 s against 0.0190 s as
  OPTIONAL with zero nulls, so eliminating definition-level work entirely is
  worth at most 10.5%, on a synthetic single-column file that maximizes the
  share. On the reference workloads it is smaller.
- [x] Decode suitable numeric columns into R-owned memory and expand nullable
  values backward in place. **Measured and declined.** Numeric columns already
  decode into R-owned memory; what expansion would remove is one copy from the
  worker's scratch into the R vector. A `memcpy` of that column is 0.0006 s
  against a 0.0190 s read, so the ceiling is 3.2%, and it applies only where
  the physical and R widths match exactly: `INT32` to integer and `DOUBLE` to
  double, not `INT64`, `FLOAT`, `INT96`, or `BOOLEAN`.

  Both were declined on the same reasoning: single-digit ceilings, narrow
  applicability, and each one adds a special-case decode path. This phase spent
  most of its debugging on exactly that kind of path -- a fast path that ran
  every task twice, and a cache that regressed the case it did not fit. The
  gains already banked are 77%, 46%, and 35%; these two are not worth the new
  surface. Revisit if a profile ever shows definition-level decoding dominating
  a real workload.
- [x] Benchmark buffered persistent reads, and implement private-reader
  parallelism with correct ownership. Each worker gets its own
  `carquet_reader_t`, opened on the same path with the same options, because
  the buffered path shares `FILE*` and prebuffer state. Tasks are grouped into
  lanes so one reader is only ever used by one lane, and a lane runs its tasks
  in sequence on a single worker. Measured 0.181 s to 0.063 s on
  `collect-buffered`, a 65% reduction, bringing the buffered default level with
  the mapped parallel path. Only taken above 50,000 selected rows, since each
  private reader re-parses the footer.

### Exit gate

- [x] Peak string scratch scales with `batch_size`, not with the largest
  selected row group. Bound: `min(batch_size, rows in the row group)` times the
  value width, 16 bytes for a byte-array descriptor plus 2 for a definition
  level. Instrument: `gc()`'s "max used" Vcells, since `R_alloc` draws from R's
  vector heap. Measured on a 2-million-row file: a flat ~81 MB at every
  `batch_size` before, 67 MB at 16k rows after. Asserted in
  `test-parquet-file.R`.
- [x] Dictionary, plain, and mixed pages return identical character results.
  Fixture `string_encodings.parquet` holds one of each, including a column that
  switches encoding partway; results are checked against Apache Arrow's own
  read and across batch sizes, since a batch boundary resets the cache.
- [ ] Performance changes include reproducible evidence from the reference
  workloads and stay within each case's tolerance
  (`Rscript bench/benchmark.R --compare <tag>` exits non-zero otherwise).
  Changes to the parallel path also report `collect-mmap-serial` and
  `collect-buffered`, whose tolerances are tight enough to be meaningful.
- [x] Valgrind, sanitizers, and gctorture pass the new allocation paths.
  `native-checks` run 30703576368 on `785cb99`, all five jobs green, covering
  the private-reader threading and the chunked scratch.

  What that does and does not establish: ASan, UBSan, and Valgrind memcheck
  find memory errors, not data races -- race detection is thread sanitizer or
  Helgrind, neither of which is in the matrix. Race freedom rests instead on
  the value-comparison tests across thread counts, which is what caught the
  double-execution bug. A thread-sanitizer job would be worth adding before
  more threading work.

## Phase 5: harden and configure the writer

Status: complete for v0.1.0. The reusable configuration object is deferred to
v0.2.0; everything else in the phase is done.

### What the work turned up

Attempting to write columns in chunks exposed that carquet's writer corrupts
data when a column is written in more than one batch: `BOOLEAN` bit packing does
not resume across calls, and BYTE_STREAM_SPLIT transposes each call's subrange
separately.

Chasing that led to a worse bug already present on the branch. carquet selects
BYTE_STREAM_SPLIT for `FLOAT` and `DOUBLE` whenever a codec is set, which is
qio's default, and its encoder is wrong for any page assembled from more than
one call. A nullable double column past roughly a megabyte of present values
was written with **every non-null value wrong** -- 171,428 of 200,000 -- and
Apache Arrow read the same wrong values back, so the file itself was corrupt.
`uncompressed` was unaffected, which is what identified the encoding.

Both are recorded in
[`VENDORED.md`](VENDORED.md#known-upstream-defects-worked-around-in-qio).

### Entry gate

- [x] The remaining writer-configuration choices are resolved by deferral: the
  configuration object moves to v0.2.0, so none of the naming, sizing, or
  dictionary questions block v0.1.0. Recorded in `roadmap.md`.

### Work

- [x] Write bounded chunks and check user interrupts between chunks. Unblocked
  by fixing both encodings that could not resume across batches. Columns are
  written 65536 rows at a time, with an interrupt check between chunks. Peak
  heap for a 4-million-row string column fell from 101MB to 40MB; measure this
  on a single wide column, because a mixed frame's own memory hides the
  scratch. Cleanup was already protected with `R_UnwindProtect` from phase P.
- [x] Stop writing corrupt `FLOAT` and `DOUBLE` columns. First worked around by
  forcing `PLAIN`, which cost 50% write time and 38% file size; then fixed
  properly by patching carquet to transpose each page once at finalize, which
  recovers the size entirely and is 17% faster than the workaround.
- [x] Abort after write failures but never after `carquet_writer_close()` has
  consumed the handle, and test every failure stage. Covered in `test-qio.R`:
  a validation failure leaves an existing file byte-identical, a failure during
  encoding leaves no file at all and frees the path, and the close path clears
  the handle before calling close so cleanup can never abort a consumed writer.
  Interruption is not directly tested: with writes unchunked there is no
  interrupt check to reach, and adding one is blocked upstream.
- [x] Validate schema and configuration before creating or truncating output.
  Asserted rather than assumed: six rejected writes are attempted over an
  existing file and its size and contents are compared afterwards.
- [x] Preserve contextual carquet write errors through the C and R boundaries,
  as far as carquet exposes them: `carquet_writer_write_batch()` and
  `carquet_writer_close()` return only a status, with no `carquet_error_t`, so
  messages now carry `carquet_status_string()` and the failing row.
- [ ] Implement the resolved reusable configuration object with global and
  complete-path per-column settings. **Deferred to v0.2.0** with the other
  writer API decisions; the release needs none of it, and deferring leaves the
  open naming and sizing questions unanswered rather than guessed.
- [x] Keep `parquet_schema()` responsible for types. With the configuration
  object deferred there is no second source of truth to reconcile; the only
  output choice qio now overrides is `PLAIN` encoding for `FLOAT`/`DOUBLE`, to
  avoid the corrupting encoder.
- [x] Add reproducible write benchmarks before attempting optimizations.
  `bench/` has carried `write-numeric`, `write-string_low_cardinality`, and
  `write-mixed` since phase 0.

### Exit gate

- [x] Interrupted and failed writes release native resources and do not leave a
  file that appears successfully complete. Interrupts are now checked between
  chunks; the unwind path is the same one the failure tests exercise.
- [x] All configuration is validated before output mutation. Reuse across
  writes moves with the configuration object to v0.2.0.
- [x] Codec, null, and page-boundary tests pass: every writable type across
  five codecs, with and without nulls, at sizes on both sides of a data page,
  plus degenerate frames. Row-group and per-column configuration tests move
  with the deferred configuration object.
- [x] Writer round trips pass against qio and an independent Parquet reader.
  The suite round-trips against the input, which is what detects a corrupt
  write; `tools/check-writer-against-arrow.R` reads the same files with Apache
  Arrow and compares *that* against the input, which is what attributes the
  fault to the writer rather than the reader. Comparing the two readers to each
  other would prove nothing: a badly written file decodes to the same wrong
  values in both, and verifying this on a build with the corruption restored is
  how that was established.

## Phase 6: expose the remaining inspection and writer controls

Status: complete. All five required items and all four deferrable ones
shipped, so nothing was cut and the descope order below was never exercised.

Append shipped against the earlier recommendation to defer it, on an explicit
call. The reasoning for that recommendation was not wrong, and the evidence
for it is now recorded in the gate: bypassing qio's own compatibility check
lets carquet corrupt a file that was correct. What changed is that the check
exists and is tested, not that the hazard went away.

This phase carries the most optional scope in the release. Each item is labelled
Required or Deferrable; deferrable items ship only if they land complete and
tested before phase 7 begins.

### Work

- [x] Required: add column statistics and column-chunk metadata inspection.
  `column_statistics()` and `column_chunks()`, one row per column per row
  group. Bounds are list columns decoded at the physical level only, because
  a bound is a sort key rather than a value to compute with; text is the
  exception. Documented as writer claims that qio does not verify and does
  not act on.
- [x] Required: add file validation helpers with useful error context.
  `validate_parquet()` reports the file's problem rather than the parser's:
  too small, wrong or missing magic, truncated, encrypted footer, footer
  that does not parse, or row groups that do not sum to the declared rows.
  Deliberately does not read data pages, and says so.
- [x] Required: add explicit row-group boundaries.
  `write_parquet(row_group_size =)` counts rows. Required restructuring the
  write loop to be row-group-major: carquet closes a group only when every
  column has reached the same logical row, which column-at-a-time writing
  never satisfied before the last column.
- [x] Required: add writer key/value metadata.
  `write_parquet(metadata =)` takes a named character vector; duplicate keys
  keep their order and `NA` round-trips as a key with no value.
- [x] Required: document unsupported carquet capabilities instead of exposing
  incomplete wrappers. `?qio-limitations` lists each one with the reason, so an
  absent function reads as a decision.
- [x] Deferrable: add column-index and offset-index inspection with explicit
  ownership cleanup. Do not add predicate evaluation or pushdown. `page_index()`
  reports both sides as one frame, one row per page. Neither handle is held
  across an R allocation other than a single `R_alloc`, and bounds are copied
  out before the handles are freed. No pushdown was added.
- [x] Deferrable: add append mode with qio-side complete schema compatibility
  checks. `write_parquet(append = TRUE)`. The qio-side check is the point: with
  it bypassed, carquet accepts a MICROS-for-MILLIS timestamp append, rewrites
  the footer, and three rows that read as 2020 before the append read as 1970
  after it. qio compares the complete declaration, including logical
  parameters and schema paths, and adopts the file's nullability so a
  null-free batch can still be appended to a nullable column.
- [x] Deferrable: add sorting declarations, documenting that they do not sort or
  verify input. `write_parquet(sorted_by =)`. Write-only: carquet records the
  declaration but exposes no way to read it back, so agreement is checked
  against pyarrow rather than by round trip.
- [x] Deferrable: add bloom-filter inspection with explicit ownership cleanup.
  `bloom_filter_may_contain()`, named for the only thing a bloom filter can
  promise. Values are reduced to the column's physical type, and a value that
  cannot be is an error rather than a `FALSE` that would read as
  "definitely absent".

### Descope order

Kept for the record; nothing was cut. Had schedule pressure forced it, the
order would have been **append mode, bloom-filter inspection, sorting
declarations, page indexes**, with each cut recorded in `roadmap.md` first.

Append moved from third cut to first. It is the only item in the release that
can damage data the user already has. carquet's append compares leaf count,
order, names, physical types, repetition, fixed widths, and logical type IDs,
but not parent paths and not logical *parameters*: decimal scale, timestamp
unit, integer signedness, CRS. Appending a MICROS timestamp column to a MILLIS
file therefore passes its check and writes wrong values into a file that was
correct before. qio would have to implement all of that validation itself.

Every defect found so far in this project affected only newly written or newly
read data; this would be the first to corrupt what was already on disk. That is
the wrong risk for a first release, so append waits for v0.2.0 and the schema
compatibility work it needs.

### Exit gate

- [x] Every shipped object has documented ownership, stable print behavior, and
  malformed-file tests. All four new results are plain data frames, so ownership
  and printing are R's. `test-inspect.R` covers a file that is too small, not
  Parquet, truncated, encrypted, and structurally inconsistent.
- [x] Any cut item is recorded as deferred in `roadmap.md` and absent from the
  README feature matrix and reference index. Nothing was cut: all four
  deferrable items shipped. The README matrix is phase 7's.
- [x] If append mode ships, it rejects incompatible logical parameters and
  parent paths before writing. It does not ship; see Descope order.
- [x] Inspection results agree with the independent Parquet tool chosen in
  phase 0. `tools/check-inspection-against-arrow.R`: row-group count and sizes,
  statistics bounds, null counts, and footer metadata all match Arrow's reading
  of the same file, and Arrow reads back the values the writer was given, which
  is what proves the row-group-major restructure did not corrupt anything.

## Phase 7: complete interoperability and release documentation

Status: complete. The fixture audit was the substance of it: comparing the
corpus against what qio claims to support turned up a reader defect that no
existing test could have found, which is the argument for doing this before
release validation rather than treating it as documentation.

### Work

- [x] Audit the fixture corpus across physical types, logical annotations,
  encodings, data-page versions, null patterns, and row-group layouts. The
  audit found four gaps and one bug: `INT64` `DELTA_BINARY_PACKED` did not read
  at all, because Arrow writes a larger block size for 64-bit columns and the
  decoder validated every header against the 32-bit shape. The single delta
  column in the Apache corpus is `INT32`, which is why nothing caught it. Gaps
  filled by `tools/generate-coverage-fixtures.py`; results and the one
  remaining gap (`ENUM`, which no available writer emits) in
  `parquet/SOURCE.md`.
- [x] Record generator, version, command, license, and expected behavior for
  every fixture in `SOURCE.md`.
- [x] Add a README feature matrix that separates read, write, inspect, and
  deferred support. Also corrected the install instructions, which told readers
  to `install.packages("qio")` from CRAN, where qio is not published.
- [x] Publish reproducible read/write benchmark instructions and results without
  presenting development measurements as guarantees. Commands and the caveat in
  the README; method, workloads, measured tolerances, and recorded figures in
  `bench/README.md`, which states that numbers from different machines are not
  comparable and that a baseline goes stale.
- [x] Document every bundled license, copyright holder, pin, and local patch.
  Holders are in `DESCRIPTION`'s `Authors@R` with the license each covers;
  licenses ship at `src/*/LICENSE`; pins and patches are in `VENDORED.md`, with
  a README pointer noting it is not shipped.
- [x] Regenerate roxygen output and complete the v0.1.0 `NEWS.md` section. The
  heading is still `0.0.0.9000`; renaming it belongs with the version bump in
  phase 8.

### Exit gate

- [x] Documentation describes actual behavior, defaults, limitations, and
  deliberate exclusions. `?qio-limitations` owns the exclusions, the README
  carries the matrix, and two stale claims were corrected: CRAN installation,
  and `open_parquet()`'s note that buffered reads stay single-threaded.
- [x] The built source package contains required licenses and excludes internal
  plans, patch records, build products, fixtures not intended for distribution,
  and local data. Verified by inspecting `R CMD build` output: `.agents/`,
  `bench/`, the patch record, the agent instructions, local data, and all build
  products are absent; all four license files are present.
- [x] The reference index lists every exported topic, checked without needing
  the site URL. `tools/check-reference-index.R`: all 19 exported topics.

Publishing moved to phase 8: `pkgdown::check_pkgdown()` fails until
`_pkgdown.yml` has a `url`, and that value is the maintainer's to choose. It is
a release-time setting, not documentation work, and blocking this phase on it
would have held up everything else here.

## Phase 8: release validation

Status: local gates green; external submissions and the tag outstanding. Re-run
once after the read-performance work landed, and **not yet re-run after the
converter fixes that followed it**.

### Work

- [x] Replace `url: ~` in `_pkgdown.yml`, validate the reference index, build
  the site without warnings, and confirm `pkgdown::check_pkgdown()` passes.
  Moved here from phase 7: the URL is the maintainer's choice and is a release
  setting rather than documentation. Set to the conventional GitHub Pages
  address for the repository, `https://pedrobtz.github.io/qio/`, with matching
  `URL` and `BugReports` in `DESCRIPTION`, which pkgdown expects and which had
  been missing. `check_pkgdown()` reports no problems and `build_site()`
  completes with no warnings across 34 reference pages. Publishing the built
  site is still outstanding.
- [x] Clean all native objects and build from a fresh checkout.
- [x] Run `devtools::document()`, the complete test suite, `devtools::check()`,
  and `pkgdown::check_pkgdown()`. `--as-cran` reports two NOTEs, both benign:
  a new submission whose pkgdown URL is not published yet, and a local HTML
  Tidy too old to validate the manual. Running `document()` from clean also
  caught the `URL` and `BugReports` added to `DESCRIPTION` in phase 7 never
  reaching `man/qio-package.Rd`.
- [x] Require green macOS, Windows, and Linux `R-CMD-check` runs. Dispatch
  `native-checks` against the release commit itself and require green
  sanitizer, Valgrind, LTO, gctorture, and rchk jobs; it does not run on every
  commit. All five green. The `vendor` workflow failed first and was right to:
  four carquet patches had been made without regenerating the patch record.
- [ ] Run win-builder and R-hub, including a sanitizer platform; resolve every
  actionable ERROR, WARNING, and NOTE.
- [x] Inspect the source tarball for object files, build products, patch
  records, and local artifacts; confirm that required vendored sources,
  licenses, generated documentation, and tests are present. `bench/`,
  `.agents/` and `.github/` are absent; `tools/` ships by design.
- [x] Install and test from that source tarball, not only from the working
  tree. Run it with `NOT_CRAN=true`, or the thirteen `skip_on_cran()` tests
  stay skipped and the run proves less than it appears to.
- [ ] Set `Version: 0.1.0`, finalize NEWS and release metadata, then rerun the
  complete release matrix. **NEWS still describes none of the read-performance
  work, and now has a user-facing correctness fix to describe as well**: a
  local `TIMESTAMP` column read with a DST-observing `tz` could silently lose
  the time of day from every value.
- [ ] Tag and publish v0.1.0 only from the verified release commit.

**Phase 8 has found a real omission on each of its two runs so far** -- the
missing documentation URLs, then the undocumented vendored patches. Treat a
clean run as the exception rather than the expectation, and re-run it in full
after the last code change rather than assuming an earlier pass still holds.

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
