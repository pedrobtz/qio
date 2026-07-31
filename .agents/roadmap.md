# qio R API Status and Roadmap

Last reviewed: 2026-07-31

This is the source of truth for the implemented R API and remaining package
work. Historical performance analysis and the C-binding review were folded into
this file. Detailed carquet and dependency notes remain in
[`carquet.md`](carquet.md) and [`VENDORED.md`](VENDORED.md). Decisions that still
need an explicit choice are listed in [`design.md`](design.md).

## Current Status

The package has a working eager API, persistent reader handles, selective and
batched reads, schema inspection, explicit writer schemas, and threaded mmap
reads. The C-binding architecture has been reviewed: reader cleanup is
unwind-safe, worker threads do not call the R API, and handle lifecycle is
guarded against re-entrant access.

Current verification:

- `devtools::test()`: **209 passed, 0 failed, 0 warned, 0 skipped**.
- Standard R CMD check runs on macOS, Windows, and Linux.
- Native workflows are configured for sanitizers, Valgrind, LTO, gctorture,
  and rchk.
- The last recorded Apple Silicon reference benchmark was about 440 ms serial
  and 220 ms with mmap/threading for a 3.07-million-row taxi file. These are
  development measurements, not a release guarantee.

## Implemented R API

### Reading and inspection

| API | Implemented behavior |
|---|---|
| `read_parquet(file)` | Opens with mmap requested, collects supported flat columns, skips nested columns with one message, and closes the handle |
| `parquet_open()` / `parquet_close()` | Persistent file handle with mmap, checksum, and thread controls |
| `collect()` | Selects flat columns and row groups and returns one data frame |
| `walk_batches()` | Calls an R function for each decoded batch and honors `batch_size` |
| `schema()` | One row per leaf, including dotted path, physical/logical type, repetition, and levels |
| `row_groups()` | Row counts and compressed/uncompressed sizes |
| `metadata()` | Footer key/value metadata, preserving duplicate keys and order |
| `read_plan()` | Shows the resolved R type and whether each leaf is collectible |
| `parquet_type_mapping()` | Reports the physical Parquet-to-R fallback mappings |

`dim()`, `names()`, and `print()` methods are implemented for open handles.
`read_parquet()`, `collect()`, and `walk_batches()` share the same R-side read
plan, so supported logical types are converted consistently.

`collect()` uses carquet's low-level column API and type-specialized dense-value
scatter. Numeric row-group/column tasks run in parallel only when mmap is
active; strings remain on the R main thread. `walk_batches()` uses carquet's
batch reader.

### Current read mappings

| Parquet type | R result |
|---|---|
| `BOOLEAN` | logical |
| `INT32` | integer |
| `INT32 + DATE` | `Date` |
| `INT64` | double |
| UTC `INT64 + TIMESTAMP` | UTC `POSIXct`, unit-aware |
| `INT96` | UTC `POSIXct` |
| `FLOAT`, `DOUBLE` | double |
| `BYTE_ARRAY` | character, currently assumed UTF-8 |
| `FIXED_LEN_BYTE_ARRAY` | not collectible |

Only flat, non-repeated leaves are materialized. Selected nested leaves are
skipped with one operation-level message; nested reading is deferred to v0.2.0.
`INT64` and `INT96` results use R doubles and can lose integer precision beyond
2^53. Logical annotations not listed above currently retain their physical
fallback where possible.

### Writing

| API | Implemented behavior |
|---|---|
| `write_parquet()` | Writes data frames or equal-length atomic lists to a file |
| `parquet_schema()` | Creates reusable, partial writer overrides |
| `infer_parquet_schema()` | Shows the schema inferred from an R object |

Automatic mappings cover logical, integer, double, character, factor, `Date`,
and `POSIXct`. Explicit schemas support `BOOLEAN`, `INT32`, `INT64`, `FLOAT`,
`DOUBLE`, `STRING`, `DATE`, and UTC `TIMESTAMP` in millisecond, microsecond, or
nanosecond units. Supported compression choices are Snappy, Zstandard, Gzip,
LZ4 Raw, and uncompressed output.

qio defaults to Snappy. The underlying vendored carquet writer defaults to
uncompressed `PLAIN` encoding; dictionary encoding is available in carquet but
is not currently exposed by qio.

## Implemented Internal Work

- `collect()` bypasses carquet's row-aligned batch expansion and reads dense
  values plus definition levels directly.
- Type-specialized scatter avoids per-value R accessor calls and uses bulk
  copies for suitable required columns.
- Mmap reads can decode numeric columns on carquet's worker pool while keeping
  all R API use on the main thread.
- Local carquet patches fix scalar Snappy corruption, page-state performance,
  swallowed errors, decode-buffer safety, and portability. Their rationale is
  recorded in [`VENDORED.md`](VENDORED.md).
- Dead eager-reader C code was removed, and the public documentation now states
  that `collect(batch_size =)` is currently unused.

The reviewed integration strategy remains in force: physical decode belongs in
C, logical reinterpretation belongs in the shared R read plan, and
`collect()` should continue using low-level column streams rather than undoing
the batch reader's row-aligned representation.

## Open Work

### 1. Trust and portability

- [ ] Generate and track an authoritative `carquet-changes.patch`, exclude it
  from the source package, and add a CI reverse-apply drift check.
- [ ] Add vendored-header prerequisites to `src/Makevars` and
  `src/Makevars.win` so header changes cannot leave ABI-incompatible objects.
- [ ] Upstream the local carquet correctness, performance, and portability
  patches, then re-vendor from a new pin.
- [ ] Ensure Windows CI explicitly exercises mmap with at least two threads;
  the current equivalence test uses automatic thread selection.
- [ ] Fix or upstream carquet's batch-pipeline behavior where
  `num_threads = 1` can still create two workers. This affects qualifying
  `walk_batches()` calls, while qio's direct `collect()` path respects one.

### 2. R API correctness and type coverage

- [ ] Implement the resolved signed `INT64` and unsigned `INTEGER(64)` modes
  across `read_plan()`, `read_parquet()`, `collect()`, and `walk_batches()`,
  including operation-level warnings and bit-preserving
  `bit64::integer64` output where representable.
- [ ] Resolve selected flat columns by their complete schema path. The current
  C selection still uses carquet's leaf-name-only lookup, which can collide
  when a skipped nested leaf has the same name as a top-level flat column.
- [ ] Add read output modes so unannotated binary and BSON become raw-vector
  list-columns and `FIXED_LEN_BYTE_ARRAY` can be materialized.
- [ ] Implement exact UUID and decimal materialization.
- [ ] Implement the resolved `tz = "UTC"` timestamp contract for reads and
  writes, including non-UTC wall-clock interpretation and the single
  timezone-loss message on applicable writes.
- [ ] Implement remaining integer-width annotations, `TIME`, `ENUM`, `JSON`,
  `BSON`, and `FLOAT16` according to decisions in
  [`design.md`](design.md).
- [ ] Build an interoperability corpus covering physical types, logical types,
  page versions, and encodings. Unsupported files must fail clearly.
- [ ] Add read-side overflow fixtures for extreme microsecond and nanosecond
  timestamps.

### 3. Read performance and memory

- [ ] Sub-batch string reads. The current scratch allocation scales with the
  largest selected row group; this would bound scratch and give
  `collect(batch_size =)` real behavior.
- [ ] Use dictionary values and indexes internally to materialize character
  vectors efficiently, with a safe materialized fallback for mixed encodings.
- [ ] Use statistics for a no-null fast path where the benefit is measurable.
- [ ] Decode suitable numeric columns directly into R vector memory and expand
  nullable values backward in place.
- [ ] Consider private readers per worker for buffered parallel reads only if
  long-lived non-mmap handles prove to be a real use case.

### 4. Writer API

- [ ] Write in bounded chunks, check user interrupts, and abort partial files
  safely through `R_UnwindProtect`.
- [ ] Surface richer carquet write errors when its API can return contextual
  error information.
- [ ] Add the resolved reusable writer-configuration object and expose tuning
  through it: row-group/page sizing, compression levels, statistics,
  dictionary/per-column encoding, and later page indexes and bloom filters.
- [ ] Add writer mappings for binary, UUID, and decimal after their read
  representations are settled.
- [ ] Establish and track write-performance benchmarks before optimizing the
  writer.

### 5. Additional carquet capabilities

- [ ] Column statistics, chunk metadata, page indexes, and bloom-filter
  inspection.
- [ ] Append mode, explicit row-group boundaries, and a streaming writer API.
- [ ] Writer key/value metadata and sorting declarations.
- [ ] File validation helpers and optional prebuffer control for non-mmap
  storage.

### 6. Release readiness

- [ ] Replace `url: ~` in `_pkgdown.yml`, check the reference index, and publish
  a pkgdown site.
- [ ] Add an honest README feature matrix and reproducible read/write benchmark
  documentation.
- [ ] Run final CRAN checks through win-builder and R-hub, including a sanitizer
  platform, and document the vendored-code licensing arrangement.

## Later or Deliberately Deferred

- Predicate/filter syntax, exact row filtering, and row-group/page predicate
  pushdown are deferred until after v0.1.0. The first release focuses on the
  core read and write APIs.
- In-memory raw-vector input and output are deferred until after v0.1.0. The
  first release reads and writes file paths; future buffer APIs must define
  ownership and whole-file memory limits.
- Nested LIST/MAP/struct reconstruction and parent-path projection are deferred
  to v0.2.0. In v0.1.0, selected nested physical leaves are omitted with one
  message per materializing read operation.
- Nested writing is deferred until after v0.1.0 and until the corresponding
  read representations and null semantics are stable. The first writer emits
  flat Parquet schemas only.
- ALTREP and exposure of carquet's zero-copy views are deferred because they
  change file-lifetime and materialization semantics.
- Variant and geospatial payload materialization are outside the current parity
  target.
- Custom codecs and shared process-wide reader pools are low priority.

## Decisions in Force

- Physical decoding stays in C; logical conversion and class assignment stay
  in the shared R read plan. A C output mode may be selected when the physical
  representation must change before R can use it faithfully.
- Logical annotations take precedence over physical fallback mappings.
- Ordinary R numeric vectors write as Parquet `DOUBLE`; ambiguous physical
  targets require `parquet_schema()`.
- Signed `INT64` will support `int64 = c("double", "integer64")`. Double is the
  default; values outside the inclusive range from `-2^53` through `2^53`
  become `NA` with one warning per read operation. The exact mode requires the
  suggested `bit64` package. See [`design.md`](design.md) for the `-2^63`
  sentinel constraint.
- Unsigned `INTEGER(64)` uses the same option. Double mode returns values
  through `2^53` and replaces larger values with `NA`; integer64 mode returns
  values through `2^63 - 1` and replaces the upper unsigned half with `NA`.
  Each mode emits at most one relevant warning per read operation.
- Timestamp reads and writes will accept `tz = "UTC"`. UTC-adjusted timestamps
  preserve their instant; non-UTC timestamps use `tz` to interpret or render
  wall-clock fields. Writing non-UTC timestamps with a non-UTC `tz` emits one
  message because the timezone is not stored in Parquet.
- Parquet `TIME` reads will support `time = c("numeric", "hms")`. Numeric
  seconds since midnight are the default; the optional class mode requires the
  suggested `hms` package.
- Dictionary, plain, and mixed-encoded text always materialize as character.
  Dictionary preservation may be an internal optimization but will not change
  the public R type or expose factors.
- v0.1.0 will not expose a predicate/filter API or predicate pushdown; those
  require a separate post-release design.
- v0.1.0 uses path-based Parquet I/O only; raw-vector buffer I/O is deferred
  until a concrete post-release use case justifies its API and memory cost.
- v0.1.0 writes flat Parquet schemas only. Nested LIST, MAP, struct/group, and
  repeated-field output is deferred until after the read representation is
  stable.
- v0.1.0 reads flat, non-repeated leaves only. Selected nested leaves are
  skipped with one message per operation; nested reconstruction and parent-path
  projection are deferred to v0.2.0.
- Writer operational settings belong in a reusable configuration object;
  `parquet_schema()` remains responsible for physical and logical column types.
- Binary data should become raw-vector list-columns; only text annotations
  should become character.
- Decimal reads will return exact fixed-point character values. Decimal writes
  require explicit precision and scale and parse character input without
  converting through double; ordinary character columns remain Parquet STRING.
- New `INT96` output will not be added; legacy `INT96` remains read-only.
- New writer mappings belong in `parquet_schema()`, not one-off arguments.
- Zero runtime R dependencies remains a package goal unless a design decision
  explicitly justifies otherwise.

## Maintenance

Update this file when an API is implemented, an open item changes status, or a
new limitation is discovered. Record unresolved product choices in
[`design.md`](design.md), and keep patch-level details in
[`VENDORED.md`](VENDORED.md) rather than duplicating them here.
