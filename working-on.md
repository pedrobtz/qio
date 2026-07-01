# Working on qio

Last updated: 2026-07-01

This file is the source of truth for current qio development status and next
steps. Detailed type decisions and the full type roadmap live in
[`TYPES.md`](TYPES.md). The vendored carquet API is summarized in
[`inst/doc-extra/carquet.md`](inst/doc-extra/carquet.md).

## Current focus

Broader Parquet logical-type support is built on the shared read plan
(`read_plan()`), so eager reads, collected reads, and batch callbacks convert
identically. `DATE`, UTC-adjusted `TIMESTAMP`, and legacy `INT96` timestamps are
implemented. Candidate next steps are a non-UTC local `TIMESTAMP`
representation, exact `INT64`, or correct binary handling.

## Implemented

### Basic reading and writing

- `write_parquet()` writes flat data frames and equal-length lists.
- Supported R writer inputs are logical, integer, numeric, character, and
  factor.
- Compression options are Snappy, Zstandard, Gzip, LZ4, and uncompressed.
- `read_parquet()` is the eager convenience API and uses the same open,
  collect, and close path as lazy reads.
- Parquet null values map to the corresponding R `NA` values.
- `NA_real_` is written as null while `NaN` remains a floating-point value.

### Lazy file API

- `parquet_open()` creates a persistent `qio_parquet_file` backed by a carquet
  reader.
- `parquet_close()` is explicit and idempotent; garbage collection also closes
  abandoned handles.
- Closed, invalid, serialized, and foreign external pointers are rejected.
- Busy handles reject reentrant collection and close operations.
- `print()`, `dim()`, and `names()` are implemented as base S3 methods.
- `schema()` reports physical leaves, dotted paths, logical annotations,
  repetition, byte lengths, and definition/repetition levels.
- `row_groups()` reports row counts and compressed/uncompressed sizes.
- `metadata()` returns footer key/value pairs and preserves duplicate keys.

### Selective and batch reading

- `collect()` supports projected columns, selected row groups, and configurable
  decode batch sizes.
- Requested column order and physical row-group order are preserved.
- Duplicate, missing, and out-of-range selectors fail clearly.
- Final vectors are allocated once from the selected row count.
- Eager results larger than `.Machine$integer.max` are rejected.
- `walk_batches()` invokes `FUN(batch, index, ...)`, discards callback results,
  and returns the file handle invisibly.
- Batch callback errors and interrupts clean up native resources and restore the
  handle for reuse.

### Current physical type mappings

- Read: `BOOLEAN` to logical.
- Read: `INT32` to integer.
- Read: `INT64`, `FLOAT`, and `DOUBLE` to numeric.
- Read: `BYTE_ARRAY` to character, currently assuming UTF-8.
- Write: logical to `BOOLEAN`.
- Write: integer to `INT32`.
- Write: numeric to `DOUBLE`.
- Write: character and factor to `BYTE_ARRAY` with `STRING` annotation.
- `parquet_type_mapping()` exposes the current mapping table.

### Current logical type mappings

- Read: `INT32` annotated `DATE` to `Date`.
- Write: `Date` to `INT32` with a `DATE` annotation.
- Read: UTC-adjusted `INT64` `TIMESTAMP` to `POSIXct` in UTC. Millisecond,
  microsecond, and nanosecond units are rescaled to seconds. Non-UTC timestamps
  are left unapplied and read as their physical `INT64` double.
- Write: `POSIXct` to `INT64` microseconds with a UTC-adjusted `TIMESTAMP`
  annotation. Sub-microsecond fractions are rounded.
- Read: legacy `INT96` to `POSIXct` in UTC. The 12-byte value is decoded in C to
  seconds since the epoch (Julian day in word 2, nanoseconds-of-day in words
  0-1) and classed in R. `INT96` is read-only and treated as a UTC instant.
- `read_plan()` turns a `schema()` data frame into a per-column conversion plan.
  It is the shared driver applied by `collect()`, `read_parquet()`, and
  `walk_batches()` through `qio_apply_plan()`.
- Logical conversions are resolved in R from the plan. `qio_type_registry()`
  is the physical fallback and `qio_logical_registry()` holds static logical
  overrides (DATE); `qio_resolve_logical()` also handles parameterized
  annotations that depend on `logical_details`, such as timestamp units.
  `parquet_type_mapping()` derives from `qio_type_registry()`.

### Tests and fixtures

- Package round-trip tests cover supported R types, nulls, and compression.
- External fixtures cover interoperability and expected unsupported cases.
- A deterministic package-owned fixture has four row groups, supported
  physical types, nulls, and duplicate footer metadata.
- Lazy API tests cover metadata, projections, row groups, batch sizes, callback
  behavior, invalid inputs, closed handles, and reentrant operations.

### Packaging and portability

- Vendored carquet and compression-library copyright holders and licenses are
  recorded for CRAN.
- MinGW builds no longer assume SSE4.2 merely because the target is x86-64.
- Vendored ignored-result warnings are handled explicitly.
- The MinGW-incompatible `%zu` diagnostic was replaced with a portable format.
- Diagnostic-suppression pragmas were removed from the vendored Zstandard
  header.

## Decisions in force

- Physical storage and logical meaning are separate. New conversion dispatch
  must inspect both.
- Logical annotations take precedence over physical fallback mappings.
- Logical scalar conversion is applied in R via the read plan (`read_plan()` and
  `qio_apply_plan()`), shared by eager, collected, and batch reads. Physical
  decoding stays in C; only the logical reinterpretation lives in R.
- `INT64` remains numeric for now. All integers through `2^53` in magnitude are
  exactly representable; larger values may lose precision.
- Ordinary R numeric vectors continue to write as Parquet `DOUBLE`.
- Writing ambiguous physical types such as `FLOAT` or `INT64` will require an
  explicit writer schema or type declaration.
- Exact signed `INT64` support may later be offered through
  `bit64::integer64` or an equivalent bit-preserving class.
- Binary data must eventually become raw-vector list-columns; only text
  annotations should become R character vectors.
- Decimal support must preserve exact values. The proposed first
  representation is a character-backed decimal class carrying precision and
  scale.
- Nested lists, maps, and structs are a separate reconstruction project using
  definition and repetition levels.
- New `INT96` output will not be encouraged. Legacy `INT96` reading is supported
  (read-only, interpreted as a UTC instant).

## Next steps

### Immediate: unify scalar conversion

1. Introduce a native conversion-plan structure containing physical type,
   logical type and parameters, fixed byte length, definition/repetition
   levels, R target type, and conversion operations.
2. Use the plan for allocation and batch copying in both `collect()` and
   `walk_batches()`.
3. Normalize modern and legacy logical annotations before selecting a mapping.
4. Move `parquet_type_mapping()` onto the authoritative mapping registry.
5. Add fixtures and boundary tests before changing existing returned classes.

### Next: useful logical scalar types

1. Decide and implement a non-UTC local `TIMESTAMP` representation. It is a civil
   time, not an instant, so plain `POSIXct` is not semantically exact.
2. Test the numeric `INT64` boundary around `2^53`, including microsecond and
   nanosecond timestamps far from the epoch.
3. Design an explicit writer schema for `INT64`, `FLOAT`, timestamp units,
   fixed binary lengths, and decimal precision/scale. This would also let the
   writer emit millisecond or nanosecond timestamps instead of the fixed
   microsecond default.

### Then: binary and exact values

1. Distinguish annotated text from unannotated binary.
2. Add variable and fixed binary as raw-vector list-columns.
3. Add canonical UUID conversion and symmetric UUID writing.
4. Add exact decimal decoding for `INT32`, `INT64`, `BYTE_ARRAY`, and
   `FIXED_LEN_BYTE_ARRAY` storage.
5. Add decimal writing with explicit precision and scale.

### Later

1. Add integer logical widths, unsigned integer policies, time-of-day, enum,
   JSON, BSON, float16, and interval mappings.
2. Reconstruct lists, then nullable list elements, structs, nested lists, and
   maps.
3. Define parent-path projection for nested columns.
4. Preserve variant and geospatial payloads with their metadata.

## Open design questions

- What should the public writer schema syntax look like?
- Should exact signed `INT64` be selected globally, per read, or through a
  separate helper?
- What R representation should preserve non-UTC local timestamps without
  pretending they are instants?
- Should decimal values use a qio-owned class or integrate with an existing
  arbitrary-precision package?
- Should selecting a nested parent select all descendants, and should leaf
  selection return reconstructed parents or raw leaves?
- What should a struct column look like in a base R data frame?

## Known limitations

- Only flat, non-repeated columns can be collected.
- Logical time, decimal, UUID, and integer annotations do not yet change
  materialized R values. Non-UTC `TIMESTAMP` values are also left unapplied.
- Unannotated binary is currently treated as UTF-8 character data.
- `FIXED_LEN_BYTE_ARRAY` cannot be collected.
- `INT96` is read-only, always interpreted as a UTC instant, and shares the
  double-precision limit below.
- `INT64` may lose precision outside R's exact double-integer range, including
  microsecond and nanosecond timestamps far from the epoch.
- `POSIXct` is always written as microsecond `TIMESTAMP`; the unit is not yet
  configurable and sub-microsecond fractions are rounded.
- Other classed numeric vectors are still written from their underlying storage
  and lose their class (`Date` and `POSIXct` are preserved).
- Writer tuning is limited to compression.
- `pkgdown::check_pkgdown()` is blocked by the current `_pkgdown.yml` value
  `url: ~`; no speculative site URL has been added.

## Verification

### 2026-07-01 (legacy `INT96`)

- Added read-only legacy `INT96` timestamp decoding (Impala/Spark layout) to
  `POSIXct` in UTC. Decoded in C; classed in R via the `int96` converter.
- Promoted the external `alltypes_*` and `int96_from_spark` fixtures from
  rejected-with-error to positive reads.
- `devtools::test()`: 142 passed, 0 failed, 0 warnings, 0 skipped.
- `R CMD check` has not yet been re-run after the recent C changes; do so before
  the next release.

### 2026-07-01 (UTC `TIMESTAMP`)

- Added UTC-adjusted `TIMESTAMP` read (`POSIXct`, unit-aware) and `POSIXct`
  write as `INT64` microseconds. This adds the first `INT64` writer path.
- `devtools::test()`: 136 passed, 0 failed, 0 warnings, 0 skipped.
- `R CMD check` has not yet been re-run after the `DATE`/`TIMESTAMP` changes; do
  so before the next release.

### 2026-07-01 (read plan + `DATE`)

- Added `read_plan()`, the registry-backed conversion plan, and `DATE` read and
  write support.
- `devtools::test()`: 112 passed, 0 failed, 0 warnings, 0 skipped.
- `R CMD check` has not yet been re-run after the `DATE` changes; do so before
  the next release.

### 2026-07-01

- `devtools::test()`: 87 passed, 0 failed, 0 warnings, 0 skipped.
- Most recent `R CMD check --no-manual`: 0 errors, 0 warnings, 0 notes.
- `TYPES.md` and this tracking file are documentation-only changes after that
  package check.

## Maintenance notes

- Update this file whenever a type decision changes, a roadmap item is
  completed, or a new blocker is discovered.
- Move superseded decisions to an archive section instead of silently deleting
  their rationale.
