# qio status and roadmap

Last reviewed: 2026-08-01

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
| `read_parquet()` | Open with mmap requested, collect, close |
| `parquet_open()` / `parquet_close()` | Persistent handle with mmap, checksum, and thread controls |
| `collect()` | Select flat columns and row groups into one data frame |
| `walk_batches()` | Invoke an R callback for each decoded batch |
| `schema()` | Report leaf paths, physical/logical types, repetition, and levels |
| `row_groups()` | Report row counts and compressed/uncompressed sizes |
| `metadata()` | Return footer metadata while preserving duplicate keys and order |
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
| `parquet_schema()` | Create reusable partial type overrides |
| `infer_parquet_schema()` | Show the inferred schema |

qio supports Snappy, Zstandard, Gzip, LZ4 Raw, and uncompressed output. Snappy
is the default. Dictionary encoding is not yet exposed.

Standard R CMD check runs on macOS, Windows, and Linux. Native workflows cover
sanitizers, Valgrind, LTO, gctorture, and rchk.

## v0.1.0 priorities

### 1. Trust and portability

- [x] Fix the defects found reviewing package-owned C glue before other v0.1.0
  work: the INT32 sentinel mapping below, an unprotected write loop that leaks
  and truncates on any longjmp, missing argument-type validation at native
  entry points, and dead state. Ordered in
  [`plan.md`](plan.md#phase-p-native-glue-preflight).
- [x] Track one authoritative `carquet-changes.patch`, exclude it from the
  source package, and add a CI reverse-apply drift check.
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
- [ ] Build an interoperability corpus across physical/logical types, page
  versions, encodings, and boundary values. Unsupported files must fail
  clearly.

### 3. Read performance and memory

- [x] Sub-batch strings so scratch space does not scale with the largest row
  group and `collect(batch_size =)` has real behavior.
- [x] Materialize dictionary text efficiently, with a safe fallback for mixed
  encoding.
- [x] Use statistics for a measured no-null fast path. **Measured and
  declined**; see [`plan.md`](plan.md#phase-4-bound-reader-memory-and-optimize-measured-hot-paths).
- [x] Decode suitable numeric columns into R memory and expand nullable values
  backward in place. **Measured and declined.**
- [x] Consider private readers for buffered parallelism only if persistent,
  non-mmap performance proves important. Implemented; worth about 2.6x.

### 4. Writer

- [x] Write bounded chunks, check interrupts, and abort partial files safely
  through `R_UnwindProtect`.
- [x] Surface richer carquet write errors when available.
- [ ] Add the reusable writer configuration described below. **Deferred to
  v0.2.0**, with the other open writer API decisions.
- [x] Establish reproducible write benchmarks before optimizing.

### 5. API and release

- [ ] Required for v0.1.0: expose column statistics, column-chunk metadata,
  explicit row-group boundaries, writer key/value metadata, and file
  validation.
- [ ] Deferrable within v0.1.0, in reverse cut order: page indexes, append
  mode, sorting declarations, bloom filters. These ship only if they land
  complete and tested before release documentation begins; otherwise they move
  to v0.2.0.
- [ ] Replace `url: ~` in `_pkgdown.yml`, validate the reference index, and
  publish pkgdown.
- [ ] Add an honest README feature matrix and reproducible benchmarks.
- [ ] Run final win-builder and R-hub checks, including a sanitizer platform,
  and document vendored-code licensing.

## Read options

[`TYPES.md`](TYPES.md#conversion-contracts) settles the modes themselves:
`int64 = c("double", "integer64")`, `time = c("numeric", "hms")`, and a
validated `tz`. The surface is now settled too:

- **Per-call arguments, not a handle setting and not an options object.**
  `read_parquet()`, `collect()`, `walk_batches()`, and `read_plan()` each take
  `int64`, `time`, and `tz` directly. Reads have three options where the writer
  has many, so a constructor would cost more than it saves, and binding them to
  `parquet_open()` would make one handle's plan depend on how it was opened.
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
