# qio status and roadmap

Last reviewed: 2026-08-02

This file owns implemented R API, release scope, priorities, and open product
choices. Type behavior belongs in [`TYPES.md`](TYPES.md); carquet mechanics in
[`carquet.md`](carquet.md); dependency pins and patches in
[`VENDORED.md`](VENDORED.md). Ordered work and exit gates are in
[`plan.md`](plan.md). A carquet feature is not a qio commitment.

## Current API

qio has eager and persistent reads, selective and batched collection, metadata
inspection, explicit writer schemas, and threaded mmap reads. Reader cleanup is
unwind-safe, workers do not call the R API, and handle guards prevent re-entry.

### Reading

| API | Behavior |
|---|---|
| `read_parquet()` | Open with mmap requested, collect, close; selects columns and row groups |
| `open_parquet()` / `close_parquet()` | Persistent handle with mmap, checksum, and thread controls |
| `collect()` | Select flat columns and row groups into one data frame |
| `walk_batches()` | Invoke an R callback for each decoded batch |
| `schema()` | Report leaf paths, physical/logical types, repetition, and levels |
| `row_groups()` | Report row counts and compressed/uncompressed sizes |
| `metadata()` | Return footer metadata while preserving duplicate keys and order |
| `column_chunks()` | Report per-chunk type, codec, sizes, encodings, and optional structures |
| `column_statistics()` | Report per-chunk value/null counts and min/max bounds |
| `page_index()` | Report per-page bounds, null counts, offsets, and starting rows |
| `bloom_filter_may_contain()` | Test values against a chunk's bloom filter |
| `validate_parquet()` | Check structural validity and report what is wrong |
| `read_plan()` | Show each leaf's resolved R type and collectibility |
| `parquet_type_mapping()` | Report physical fallback mappings |

`dim()`, `names()`, and `print()` methods exist for open handles. All
materializing reads share one R conversion plan. Current type support is in
[`TYPES.md`](TYPES.md#current-behavior); reader mechanics are in
[`carquet.md`](carquet.md#qio-reader-paths).

### Writing

| API | Behavior |
|---|---|
| `write_parquet()` | Write data frames or equal-length atomic lists |
| `write_parquet(row_group_size =)` | Split output into row groups by row count |
| `write_parquet(metadata =)` | Record footer key/value metadata |
| `write_parquet(sorted_by =)` | Declare a sort order without sorting or verifying |
| `write_parquet(append =)` | Add row groups to an existing file, after a full schema check |
| `parquet_schema()` | Create reusable partial type overrides |
| `infer_parquet_schema()` | Show the inferred schema |

qio supports Snappy, Zstandard, Gzip, LZ4 Raw, and uncompressed output. Snappy
is the default. `BYTE_ARRAY` columns are dictionary-encoded, which carquet
abandons for PLAIN by itself once a chunk's dictionary outgrows its page limit;
there is no user-facing control over encoding, and the numeric types are left
PLAIN. Choosing encodings per column belongs with the writer configuration
deferred to v0.2.0.

Standard R CMD check runs on macOS, Windows, and Linux. Native workflows cover
sanitizers, Valgrind, LTO, gctorture, and rchk.

### Known API asymmetries

Reviewed 2026-08-03 across `read_parquet()`, `write_parquet()`, and
`open_parquet()`. Five inconsistencies were found and fixed: the noun-first
verb names, `file` naming both a path and an open handle, `read_parquet()`
having no way to read part of a file, `threads = 0` as a magic value, and the
lazy-reading functions having no cross-references at all. What remains is
deliberate, and is recorded here so it is not rediscovered as a defect:

- **`write_parquet(metadata =)` shares a name with the `metadata()` generic.**
  Both refer to the same footer key/value pairs, so the collision is
  descriptive rather than confusing, and renaming either would be worse.
- **`...` means opposite things in the same position.** `collect(x, ...)`
  rejects non-empty dots; `walk_batches(x, FUN, ...)` forwards them to `FUN`.
  Both are documented. The alternative is a separate argument for callback
  arguments, which no comparable R API uses.
- **`mmap` defaults `FALSE` on a handle but `TRUE` inside `read_parquet()`.**
  An eager read releases the mapping immediately; a persistent handle would
  hold it, including a Windows delete-lock, for as long as the handle lives.
  The defaults differ because the lifetimes do.
- **`bloom_filter_may_contain()` is the only export without examples**, because
  qio's writer cannot emit a bloom filter and there is no `inst/extdata`. Fix
  it by shipping a small fixture, not by writing an example that cannot run.

## v0.1.0 priorities

### 1. Trust and portability

- [x] Fix the defects found reviewing package-owned C glue before other v0.1.0
  work: the INT32 sentinel mapping below, an unprotected write loop that leaks
  and truncates on any longjmp, missing argument-type validation at native
  entry points, and dead state. Ordered in
  [`plan.md`](plan.md#phase-p-native-glue-preflight).
- [x] Track every local carquet change as a commit on the `qio` branch of the
  carquet fork, and add a CI drift check that pins both the fork and upstream.
- [x] Add vendored-header prerequisites to `src/Makevars*` so header changes
  cannot leave ABI-incompatible objects.
- [ ] Upstream local carquet patches and re-vendor from a new pin. This is best
  effort: if upstream has not merged them before release validation, v0.1.0
  ships on the current pin with the patches documented and the re-vendor moves
  to v0.2.0.
- [x] Exercise Windows mmap with at least two threads in CI.
- [x] Make qualifying `walk_batches(threads = 1)` calls single-threaded; the
  vendored batch pipeline currently forces two workers.

### 2. Types and column identity

- [x] Complete the v0.1.0 portion of the
  [`TYPES.md` implementation sequence](TYPES.md#implementation-sequence):
  shared planning through temporal and integer annotations, less the
  `INTERVAL` class carved out below. Nested and extension types remain
  deferred.
- [x] Resolve projected columns by complete schema path, not leaf name.
- [x] Build an interoperability corpus across physical/logical types, page
  versions, encodings, and boundary values. Unsupported files must fail
  clearly. Audited in phase 7; the audit found an unreadable encoding as well
  as gaps. `ENUM` remains uncovered because no available writer emits it.

### 3. Read performance and memory

- [x] Sub-batch strings so scratch space does not scale with the largest row
  group and `collect(batch_size =)` has real behavior.
- [x] Materialize dictionary text efficiently, with a safe fallback for mixed
  encoding. First shipped as an address-keyed CHARSXP cache, then reopened when
  profiling showed that cache was itself 20% of a dictionary-text read, and
  finally replaced in v0.1.0 by reading carquet's dictionary indices directly.
  A chunk that falls back from dictionary to PLAIN mid-way is re-read on a
  fresh column reader. See [`read-performance.md`](read-performance.md).
- [x] Reach parity with nanoparquet on dictionary-encoded text. Done in
  v0.1.0 across six ordered steps, one of which was measured and declined.
  Dictionary text moved from 1.4x-2.55x to 0.90x-1.10x, and the ratio is now
  flat across index bit widths rather than stepping at each kernel boundary.
- [x] Remove per-value work from the read plan's converters. Found by pointing
  the reader at a real public dataset rather than generated fixtures, which
  exposed a 426x slowdown and a silent correctness bug in the same code. Four
  converters were affected: local `TIMESTAMP`, `UUID`, `FLOAT16` and binary
  `DECIMAL`. See
  [`read-performance.md`](read-performance.md#what-the-generated-benchmarks-could-not-see).
- [ ] **v0.2.0.** Switch encoding at the page boundary instead of re-reading a
  chunk that falls back from dictionary to PLAIN. Worth ~10% on files Apache
  Arrow writes, which emit a dictionary page even for all-distinct columns.
  Needs carquet to report the boundary rather than failing the read.
- [ ] **v0.2.0.** Benchmark the writer against arrow and nanoparquet. Every
  comparison so far has been reads; the writer has never been measured against
  another implementation at all.
- [x] Use statistics for a measured no-null fast path. **Measured and
  declined**; see [`plan.md`](plan.md#phase-4-bound-reader-memory-and-optimize-measured-hot-paths).
- [x] Decode suitable numeric columns into R memory and expand nullable values
  backward in place. **Measured and declined.**
- [x] Consider private readers for buffered parallelism only if persistent,
  non-mmap performance proves important. Implemented; worth about 2.6x.
- [x] Verify the comparison itself before trusting any ratio derived from it.
  The benchmark's forcing function used `sum()`, which arrow answers from its
  ALTREP methods without allocating, so every arrow ratio measured before
  2026-08-03 was inflated. Corrected to `sum(unclass(column) + 0)`. This is
  what closes read performance for v0.1.0: on three public files qio is 0.81x,
  1.11x and 1.00x against the best alternative, and on generated shapes it is
  1.00x to 1.12x with one workload at 0.62x.
- [ ] **v0.2.0.** Split a row group across threads. qio schedules one task per
  *(row group x column)*, so a file with one row group and four columns gets
  four tasks whatever the core count: 1.91x from eight cores, plateauing at
  four. Ranked as headroom rather than a deficit -- the file that exposed it is
  1.11x against arrow, not the 1.78x first recorded from the flawed benchmark.
  See [`read-performance.md`](read-performance.md).

**Read performance is closed for v0.1.0.** The remaining entries above are
v0.2.0 and none of them is a parity gap. Do not reopen this section on
generated numbers alone; every defect that mattered was found by pointing
`bench/real-file.R` at a file this repository did not choose.

### 4. Writer

- [x] Write bounded chunks, check interrupts, and abort partial files safely
  through `R_UnwindProtect`.
- [x] Surface richer carquet write errors when available.
- [ ] Add the reusable writer configuration described below. **Deferred to
  v0.2.0**, with the other open writer API decisions.
- [x] Establish reproducible write benchmarks before optimizing.

### 5. API and release

- [x] Required for v0.1.0: expose column statistics, column-chunk metadata,
  explicit row-group boundaries, writer key/value metadata, and file
  validation.
- [x] Deferrable within v0.1.0: page indexes, sorting declarations, bloom
  filters, append mode. All four shipped, so nothing was cut. Append carries
  the qio-side schema check that makes it safe; carquet's own check is not
  sufficient, and the evidence is recorded in
  [`plan.md`](plan.md#phase-6-expose-the-remaining-inspection-and-writer-controls).
- [x] Publish pkgdown. The URL is set to `https://pedrobtz.github.io/qio/`,
  `check_pkgdown()` reports no problems, and the site builds without warnings.
  Published and serving; the `pkgdown.yaml` workflow deploys it to `gh-pages`.
  The site gained a `Getting started` article in 2026-08-12's release polish,
  so the reference index is no longer its only content. It is an article and
  not a vignette on purpose: it lives in `vignettes/articles/`, which
  `.Rbuildignore` excludes, so it is built for the website and never shipped
  in the tarball. `knitr` and `rmarkdown` moved out of `Suggests` into
  `Config/Needs/website` to match, and `VignetteBuilder` is gone -- the
  installed package has no vignettes to build. The cost is that `R CMD check`
  no longer runs the article's code; the `pkgdown.yaml` workflow does, on
  every pull request, which is what keeps it honest.
- [x] Add an honest README feature matrix and reproducible benchmarks.
- [x] Document vendored-code licensing. `inst/COPYRIGHTS` is authoritative --
  every holder, the files each covers, the license, and the modifications qio
  makes -- and `DESCRIPTION` points at it with `Copyright: file
  inst/COPYRIGHTS`. `Authors@R` keeps only qio's author and carquet's, since
  listing four more `cph` entries there duplicated the file without adding
  anything a reader could act on. Licenses ship at `src/*/LICENSE`; pins and
  local patches are in [`VENDORED.md`](VENDORED.md), which does not ship.
- [x] ~~Run final win-builder and R-hub checks.~~ **Not required for v0.1.0**:
  both are CRAN-submission tooling and qio is not being submitted. Their one
  unique contribution here, Windows R-devel, is now a row in the
  `R-CMD-check` matrix; the sanitizer platform duplicates `native-checks`.
  See [`plan.md`](plan.md#phase-8-release-validation).

## Read options

[`TYPES.md`](TYPES.md#conversion-contracts) settles the modes themselves:
`int64 = c("double", "integer64")`, `time = c("numeric", "hms")`, and a
validated `tz`. The surface is now settled too:

- **Per-call arguments, not a handle setting and not an options object.**
  `read_parquet()`, `collect()`, `walk_batches()`, and `read_plan()` each take
  `int64`, `time`, and `tz` directly. Reads have three options where the writer
  has many, so a constructor would cost more than it saves, and binding them to
  `open_parquet()` would make one handle's plan depend on how it was opened.
- **`read_plan()` takes the same arguments** so a plan can be inspected for
  exactly the read that will follow. This is what keeps `read_plan()` the
  authoritative description rather than a separate opinion.
- **One internal constructor validates them.** Every entry point calls
  `qio_read_options()` first, before any allocation or native call, and threads
  the result into `qio_build_plan()`. The three materializing reads cannot
  diverge because they share that one path.
- Defaults reproduce today's behavior exactly, so adding the arguments changes
  no existing result.

The arguments appear as each mode is implemented: `int64` with the 64-bit work,
`time` and `tz` with the temporal work. The mechanism is fixed now so those two
phases do not invent different ones.

## Writer configuration

The direction is settled:

- `write_parquet()` will accept one reusable configuration object rather than
  accumulating tuning arguments.
- The schema owns types; the configuration owns compression, levels, row-group
  and page sizing, statistics, checksums, and encoding.
- Validate the complete, self-contained object before creating or truncating a
  file. Do not use global R options or mutable process state.
- Per-column settings use complete schema paths.
- Defaults preserve ordinary `write_parquet()` behavior without requiring an
  explicit object.

Still open:

- constructor and argument names;
- whether row-group targets use rows, bytes, or both. Carquet offers only a
  byte target plus an explicit `carquet_writer_new_row_group()` boundary, so a
  row-count target has to be implemented in qio by counting rows and calling
  that boundary; and
- exact v0.1.0 fields, defaults, and global/per-column dictionary controls.

qio currently sets no row-group target at all, so every file it writes under
128MB is a single row group. Phase 6's explicit row-group boundaries are what
make multi-row-group output possible from qio.

The dictionary design must use carquet's effective per-column encoding API,
not its inert global option; see [`carquet.md`](carquet.md#writer-boundary).

## Deliberate exclusions

For v0.1.0:

- Parquet I/O is path-based. Any future raw-vector API must keep input bytes
  alive for the reader, return R-owned output, and document that it buffers a
  whole file rather than streaming.
- **Reading a URL downloads the whole file first, and that is not a placeholder
  for range requests.** Reads accept `http`, `https`, `ftp`, `ftps` and `file`
  URLs by fetching to the session temp directory, so the input stays a local
  path and the exclusion above holds. Selecting columns or row groups therefore
  saves decoding but not transfer.

  The downloaded copy is owned by whoever resolved the URL and is removed
  only after every connection and handle on it has been closed. That ordering
  is not cosmetic: Windows refuses to delete an open file, while Unix deletes
  it happily, so a removal registered too early leaks a temp file on Windows
  alone and passes everywhere else. `on.exit()` runs its expressions in the
  order they were added, so a function that opens the file after registering
  the removal must do that work in a separate frame -- which is why
  `validate_parquet()` is a wrapper around `qio_validate_file()`. All removals
  go through `qio_remove_temp()`, which carries the rule.

  Partial reads over HTTP are blocked in carquet, not in qio.
  `carquet_reader_open`, `carquet_reader_open_file` and
  `carquet_reader_open_buffer` are the only three entry points, and
  `carquet_reader_options_t` carries `use_mmap`, `verify_checksums`,
  `buffer_size` and `num_threads` -- no IO hook. There is nowhere to supply
  read and seek callbacks, so range requests cannot reach the reader. Two
  routes were considered and rejected: an R connection is not a `FILE*`, has no
  public conversion to one, is not seekable for `url()`, and is main-thread
  only, which would forfeit the private-reader parallelism; and synthesizing a
  `FILE*` with `fopencookie`/`funopen` has no Windows equivalent.

  So v0.2.0's version of this is a custom IO interface added to carquet on the
  fork and offered upstream, not an R-side change. Do not re-derive this.
- There is no predicate language, exact filtering, or predicate pushdown.
  Explicit column and row-group selection remains supported. A future design
  must define construction, nulls, unsupported operations, and fallback when
  pruning metadata is absent.
- Reads and writes are flat-only as specified in
  [`TYPES.md`](TYPES.md#nested-release-boundary); nested reading targets v0.2.0.

- The reusable writer configuration object is v0.2.0. `write_parquet()` keeps
  `compression`, and `parquet_schema()` keeps types; nothing else in v0.1.0
  needs tuning. Deferring leaves its open questions -- constructor and argument
  names, row-group targets in rows or bytes, fields, defaults, and dictionary
  controls -- unanswered rather than guessed.
- Writes of types with no unambiguous R representation are v0.2.0: binary,
  fixed binary, `UUID`, `FLOAT16`, `ENUM`, `BSON`, and decimal. Reads carry the
  interop value, because a user must read whatever another tool wrote but
  rarely must write these types; `write_parquet()` already rejects them with a
  clear error. Deferring also leaves open, rather than guessing, how a raw
  list-column infers binary, where a fixed width comes from, how `FLOAT16`
  rounds, whether `ENUM` comes from a factor, and what `parquet_schema()` calls
  these types.
- Exact fixed-point decimal is v0.2.0. In v0.1.0 a `DECIMAL` column reads as
  `double` with its scale applied, so a price stored as unscaled `1230` with
  scale 2 reads as `12.30`, and one message per read says the values may be
  inexact. Returning the unscaled integer or the raw bytes, as v0.0.x did, is
  worse than an approximate number: it is silently the wrong quantity.
- Writing a non-UTC `TIMESTAMP` is v0.2.0, along with the operation-level
  message that a zone is being discarded. `POSIXct` writes as a UTC-adjusted
  `TIMESTAMP`, which is the correct default and loses nothing; choosing a wall
  clock on write is the same class of decision as the other deferred writes.
- `INTERVAL` ships as exact bytes, not as a class. It is a fixed 12-byte
  binary leaf, so the v0.1.0 binary mapping already returns it losslessly. A
  dedicated interval class needs print, format, subset, comparison, and `NA`
  semantics with no runtime dependency; that design is v0.2.0.
- Extension types are v0.2.0. `GEOMETRY` and `GEOGRAPHY` are single
  `BYTE_ARRAY` leaves, so their WKB bytes already fall out of the v0.1.0 binary
  mapping; `VARIANT` is a group and is skipped with the other nested columns.
  v0.1.0 adds no extension-specific code and surfaces no extension metadata API
  beyond what `schema()` already reports.

Also deferred: ALTREP/zero-copy R views, custom codecs, shared process-wide
reader pools, and structured variant/geospatial interpretation. Revisit these
only with a concrete use case and explicit ownership or fallback semantics.

## Package constraint

Zero required runtime R dependencies remains the default. Any exception needs
an explicit design decision; optional modes may use suggested packages.

## Maintenance

Update this file when API status, release scope, priority, or an open product
choice changes. Track execution and exit gates in [`plan.md`](plan.md). Do not
duplicate type contracts, integration mechanics, or patch history here.
