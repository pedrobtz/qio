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

- [ ] Fix the defects found reviewing package-owned C glue before other v0.1.0
  work: the INT32 sentinel mapping below, an unprotected write loop that leaks
  and truncates on any longjmp, missing argument-type validation at native
  entry points, and dead state. Ordered in
  [`plan.md`](plan.md#phase-p-native-glue-preflight).
- [ ] Track one authoritative `carquet-changes.patch`, exclude it from the
  source package, and add a CI reverse-apply drift check.
- [ ] Add vendored-header prerequisites to `src/Makevars*` so header changes
  cannot leave ABI-incompatible objects.
- [ ] Upstream local carquet patches and re-vendor from a new pin. This is best
  effort: if upstream has not merged them before release validation, v0.1.0
  ships on the current pin with the patches documented and the re-vendor moves
  to v0.2.0.
- [ ] Exercise Windows mmap with at least two threads in CI.
- [ ] Make qualifying `walk_batches(threads = 1)` calls single-threaded; the
  vendored batch pipeline currently forces two workers.

### 2. Types and column identity

- [ ] Complete the v0.1.0 portion of the
  [`TYPES.md` implementation sequence](TYPES.md#implementation-sequence):
  shared planning through temporal and integer annotations. Nested and
  extension types remain deferred.
- [ ] Resolve projected columns by complete schema path, not leaf name.
- [ ] Build an interoperability corpus across physical/logical types, page
  versions, encodings, and boundary values. Unsupported files must fail
  clearly.

### 3. Read performance and memory

- [ ] Sub-batch strings so scratch space does not scale with the largest row
  group and `collect(batch_size =)` has real behavior.
- [ ] Materialize dictionary text efficiently, with a safe fallback for mixed
  encoding.
- [ ] Use statistics for a measured no-null fast path.
- [ ] Decode suitable numeric columns into R memory and expand nullable values
  backward in place.
- [ ] Consider private readers for buffered parallelism only if persistent,
  non-mmap performance proves important.

### 4. Writer

- [ ] Write bounded chunks, check interrupts, and abort partial files safely
  through `R_UnwindProtect`.
- [ ] Surface richer carquet write errors when available.
- [ ] Add the reusable writer configuration described below.
- [ ] Establish reproducible write benchmarks before optimizing.

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
validated `tz`. Their API surface is still open and must be decided once, before
the 64-bit and temporal work starts:

- which functions accept them (`read_parquet()`, `collect()`, `walk_batches()`,
  `parquet_open()`, or a single options object);
- how they reach the shared read plan and how `read_plan()` reports them; and
- where defaults are validated, which must be before any allocation.

Do not let the 64-bit and temporal phases each invent their own mechanism.

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
- whether row-group targets use rows, bytes, or both; and
- exact v0.1.0 fields, defaults, and global/per-column dictionary controls.

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
