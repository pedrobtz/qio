# Parquet-to-R type contracts

This file owns qio's current and target type behavior. Package scope belongs in
[`roadmap.md`](roadmap.md); physical decoding constraints belong in
[`carquet.md`](carquet.md).

Parquet physical types describe storage (`INT64`, `BYTE_ARRAY`); logical types
describe meaning (`TIMESTAMP`, `STRING`). Logical types therefore take
precedence over physical fallbacks.

## Rules

1. `read_parquet()`, `collect()`, and `walk_batches()` use the same read plan.
2. Physical decoding stays in C; logical conversion and R classes stay in the
   shared R plan unless fidelity requires a different C output mode.
3. Exact data is never silently converted to a lossy or textual form.
4. Returned R values own their memory; they never borrow a carquet batch.
5. Unsupported mappings fail with the column path and relevant type details.
6. Ordinary R types get unambiguous defaults. Ambiguous writes require
   `parquet_schema()`.
7. Read and write mappings are symmetric when one R type identifies one
   Parquet type.
8. `qio_type_registry()` is authoritative for physical fallbacks;
   `parquet_type_mapping()` must be generated from it.

The user-facing consolidation of everything below is `?qio-types`, generated
from `R/types.R`: one table of physical type, logical annotation, resulting R
type, precision notes, and write support. This file remains the owner of the
contracts and the reasoning; that topic is the reference a user reads. Change
this file first, then keep the table in step.

## Current behavior

Nulls become the corresponding R `NA`. Materializing reads accept `int64`,
`time`, and `tz`; see [64-bit integers](#64-bit-integers) and
[Timestamps and time of day](#timestamps-and-time-of-day). Unsigned columns are
never returned as negative values, at any width.

### Reads

| Parquet storage | Current R result | Limitation |
|---|---|---|
| `BOOLEAN` | logical | — |
| `INT32` | integer or `Date` | Only `DATE` is interpreted; stored `-2147483648` becomes `NA` with a warning (see [INT32 sentinel values](#int32-sentinel-values)) |
| `INT64` | numeric, `bit64::integer64`, or `POSIXct` | Selected by `int64`; unrepresentable values become `NA` with one warning per affected column |
| `INT96` | UTC `POSIXct` | Read-only legacy timestamp |
| `FLOAT`, `DOUBLE` | numeric | `FLOAT` is widened to double |
| `BYTE_ARRAY` | character or list of raw | Character only with a `STRING`, `ENUM`, or `JSON` annotation; validated as UTF-8 |
| `FIXED_LEN_BYTE_ARRAY` | list of raw, character, or numeric | Raw by default; `UUID` becomes canonical text and `FLOAT16` widens to double |

Only flat, non-repeated leaves are materialized. Selected nested leaves are
omitted with one operation-level message. If all selected leaves are nested,
the result has zero columns and preserves its row count.

`DATE` and UTC-adjusted `TIMESTAMP` conversions are applied by the shared R read
plan. Other logical annotations are visible through `schema()` but currently
use their physical fallback when one exists.

Bytes are only text when the file says so. An unannotated `BYTE_ARRAY` is
arbitrary bytes and reads as a list of raw vectors, where a null value is a
`NULL` element. Text columns are validated as UTF-8 and fail with the column
path and row when they are not.

### Writes

| R input | Inferred Parquet output | Notes |
|---|---|---|
| logical | `BOOLEAN` | Optional when any value is `NA` |
| integer | `INT32` | Optional when any value is `NA` |
| numeric | `DOUBLE` | `NA` is null; `NaN` is a value |
| character, factor | `BYTE_ARRAY` + `STRING` | Factors lose their levels |
| `Date` | `INT32` + `DATE` | Days since 1970-01-01 |
| `POSIXct` | `INT64` + UTC `TIMESTAMP` | Microseconds by default |

`parquet_schema()` supplies reusable partial overrides. Explicit schemas
currently support `BOOLEAN`, `INT32`, `INT64`, `FLOAT`, `DOUBLE`, `STRING`,
`DATE`, and UTC `TIMESTAMP` in millisecond, microsecond, or nanosecond units.
Explicit `INT64` input must be finite, whole, and within `[-2^53, 2^53]`.

Double-backed 64-bit integer objects currently infer `DOUBLE`.

## Target mappings

### Numeric and temporal

| Parquet type | R result | Contract |
|---|---|---|
| `BOOLEAN` | logical | Existing mapping |
| signed `INTEGER(8/16/32)` | integer | Validate annotation against storage |
| signed `INTEGER(64)` or bare `INT64` | numeric or `bit64::integer64` | Selected by `int64`; see below |
| unsigned `INTEGER(8/16)` | integer | Exact |
| unsigned `INTEGER(32)` | numeric | Exact |
| unsigned `INTEGER(64)` | numeric or `bit64::integer64` | Selected by `int64`; see below |
| `FLOAT`, `DOUBLE`, `FLOAT16` | numeric | Widen smaller IEEE formats to double |
| `NULL` | all-`NA` logical | Preserve row count |
| `DATE` | `Date` | Days since Unix epoch |
| UTC `TIMESTAMP` | `POSIXct` | Instant displayed in `tz` |
| non-UTC `TIMESTAMP` | `POSIXct` | Wall clock interpreted in `tz` |
| `TIME` | numeric or `hms` | Seconds since midnight, selected by `time` |
| `INTERVAL` | list-column of 12-byte raw vectors | Exact bytes in v0.1.0; a dedicated class is v0.2.0 |

Ordinary numeric input continues to infer `DOUBLE`. `FLOAT`, `FLOAT16`, and
`INT64` writes require an explicit schema.

R's `integer` reserves `INT_MIN` as `NA_INTEGER`, so no R integer vector can
carry a stored INT32 `-2147483648`. See
[INT32 sentinel values](#int32-sentinel-values) for the contract.

`POSIXct` is double seconds. Microsecond and nanosecond values may lose
subsecond precision far from the epoch; conversions must check overflow and
define rounding. New `INT96` output will not be added.

### Text, binary, and exact values

| Parquet type | R result |
|---|---|
| `STRING`, `ENUM`, `JSON` | character |
| unannotated `BYTE_ARRAY`, `BSON` | list-column of raw vectors |
| `FIXED_LEN_BYTE_ARRAY` | list-column of fixed-length raw vectors |
| `UUID` | canonical character UUID |
| `DECIMAL` | `double` in v0.1.0; exact fixed-point character in v0.2.0 |

Ordinary character input continues to infer `STRING`. Writes of binary, fixed
binary, `UUID`, `FLOAT16`, `ENUM`, `BSON`, and decimal are deferred to v0.2.0;
`write_parquet()` rejects those R inputs with a clear error today. When they
land they will require explicit schemas, since none of these is identified
unambiguously by an ordinary R type.

Extension types are deferred to v0.2.0, and v0.1.0 adds no code for them. What
falls out of the rules above is the whole of their v0.1.0 behavior:

- `GEOMETRY` and `GEOGRAPHY` are single `BYTE_ARRAY` leaves, so their WKB bytes
  read as raw list-columns. `schema()` continues to report `crs` and the edge
  algorithm; no other metadata is attached to the column.
- `VARIANT` is a group, so it is skipped with the other nested columns.
- `INTERVAL` is a fixed 12-byte leaf, so it reads as a fixed-length raw vector.

Richer interpretation belongs in v0.2.0 or in downstream packages. Reading
these as exact bytes now means a later structured mapping changes a column's
class, which [Compatibility](#compatibility) governs.

### Nested values

| Parquet structure | Target R result |
|---|---|
| `LIST` | list-column of vectors or nested objects |
| `MAP` | list-column of key/value data frames |
| group/struct | nested data-frame or named-list column |

Maps are not named lists: keys need not be strings or unique. Nested
reconstruction must distinguish null and empty lists, null elements, and
missing structs; coordinate all leaves; preserve logical rows across batches;
and define parent-path projection.

See [`carquet.md`](carquet.md#nested-streams) for the underlying leaf model and
`research_arrow_nested/` for non-normative background.

## Conversion contracts

These decisions are settled even where implementation remains open.

### INT32 sentinel values

R's `integer` reserves `INT_MIN` (`-2147483648`) as `NA_INTEGER`, so a stored
INT32 of that value cannot be represented. qio keeps the `integer` mapping and
reports the substitution rather than changing the column's type.

- A stored `-2147483648` becomes `NA_integer_`.
- Emit at most one warning per affected column, not per value, row group, or
  batch, and none at all for a column that lost nothing:
  `Some INT32 values in column '<name>' were coerced to NA because R's integer
  type reserves -2147483648 as its missing value.`
  The flag is per column and is set rather than counted, so a column that
  coerces a million values across twenty batches still warns once. Naming the
  column is the point: on a wide file an unattributed warning says data was
  lost without saying where.
- The rule applies wherever an INT32 leaf reaches R as `integer`, including
  through the `DATE` converter, and to any future signed `INTEGER(8/16/32)`
  annotation that resolves to R `integer`.

Promoting the column to `double` was rejected. `read_plan()` is a pure function
of the schema, so a data-dependent type would break the guarantee that all
three materializing reads agree, and would let `walk_batches()` yield different
types for different batches of one column.

qio's writer cannot produce a bare INT32 sentinel from an R `integer` vector,
but it can through an explicit `DATE` column, whose validated range includes
`INT_MIN`. That round trip is the reproducible in-package case; third-party
fixtures still cover bare INT32.

### 64-bit integers

Materializing reads will accept `int64 = c("double", "integer64")`; the default
is `"double"`.

| Input | `double` mode | `integer64` mode |
|---|---|---|
| signed `INT64` | Exact in `[-2^53, 2^53]`; otherwise `NA_real_` | Preserve bits as `bit64::integer64`; `-2^63` becomes its reserved `NA` sentinel |
| unsigned `INTEGER(64)` | Exact in `[0, 2^53]`; otherwise `NA_real_` | Exact through `2^63 - 1`; larger values become `NA_integer64_` |

Requirements:

- Detect limits from the original 64-bit payload, before conversion.
- Never expose the upper unsigned half as negative signed values.
- `"integer64"` requires `bit64`; fail clearly if it is unavailable.
- Track replacements per column, signed and unsigned alike. Emit at most one
  relevant warning per affected column, not per value, row group, or batch.
- In double mode, warn:
  `Some INT64 or UINT64 values in column '<name>' were coerced to NA because
  they cannot be represented exactly as R doubles; use int64 = "integer64" to
  preserve the supported 64-bit range.`
- In integer64 mode, warn:
  `Some INT64 or UINT64 values in column '<name>' were coerced to NA because
  they cannot be represented by bit64::integer64.`
- `read_plan()` records the mode, and every materializing read applies it. The
  argument surface is settled in
  [`roadmap.md`](roadmap.md#read-options): per-call arguments on
  `read_parquet()`, `collect()`, `walk_batches()`, and `read_plan()`, validated
  by one shared constructor before any allocation.

### Timestamps and time of day

Reads and writes will accept `tz = "UTC"`; validate it before allocating output
or creating a file.

- A UTC-adjusted `TIMESTAMP` is an instant. `tz` changes its display, not its
  value.
- A non-UTC `TIMESTAMP` is a wall clock. Read it in `tz`; write it by rendering
  the input in `tz`, then discard the zone. Never use the machine's local zone
  implicitly.
- A civil time that is **ambiguous** at a DST boundary -- one that occurs twice
  -- resolves to whichever instant the platform's `mktime` chooses.
- A civil time that is **nonexistent** -- inside a spring-forward gap -- has no
  instant in `tz`, and **what it becomes is platform-dependent**: BSD and macOS
  return -1 from `mktime`, which surfaces as `NA`, while glibc normalizes it to
  a valid instant. qio does not currently impose a single answer, so the same
  file can read differently on Linux and macOS. Making this deterministic is
  open; see [`read-performance.md`](read-performance.md).
- What *is* guaranteed on every platform is that such a value **affects only
  itself**. An earlier implementation re-anchored through formatted text, where
  one of them made `as.POSIXct.character` fall back to a date-only format and
  silently dropped the time of day from every value in the column.
- A non-UTC write with `tz != "UTC"` emits one operation-level message:
  `Converting POSIXct values to local time in "<tz>" before writing a non-UTC
  Parquet TIMESTAMP; the timezone is not stored in the file.`
- Do not emit that message for UTC-adjusted timestamps or `tz = "UTC"`.
- Plans and schemas report the unit, timezone, and UTC-adjusted flag.

Materializing reads will accept `time = c("numeric", "hms")`; the default is
`"numeric"`.

- Both modes contain double seconds since midnight; neither returns `POSIXct`.
- `"hms"` requires the suggested `hms` package and fails clearly when absent.
- Rescale milliseconds, microseconds, or nanoseconds to seconds while retaining
  the original unit and UTC-adjusted annotation in the plan or metadata.
- Reject non-null values outside the valid time-of-day range.

### Text and binary

- Only text annotations become character. Arbitrary bytes become raw vectors.
- Text remains character across dictionary, `PLAIN`, and mixed encoding.
  Dictionary order and row-group differences never affect the result.
- qio may use dictionary indexes internally, but it must copy strings into
  R-owned memory before the carquet reader advances.
- `FIXED_LEN_BYTE_ARRAY` validates every value against `type_length`.
- UUID input and output use canonical text and exactly 16 physical bytes.

### Decimal

v0.1.0 reads decimals as `double`; exact fixed-point character is v0.2.0.

- Read every physical representation (`INT32`, `INT64`, `BYTE_ARRAY`,
  `FIXED_LEN_BYTE_ARRAY`) and apply the declared scale, so unscaled `1230` with
  scale 2 reads as `12.30`. Byte-array storage is a big-endian two's-complement
  integer.
- Emit one message per read naming how many decimal columns were read as
  `double` and that the values may be inexact. A `double` holds a decimal
  exactly only when the unscaled integer is within `[-2^53, 2^53]`; larger
  precisions lose low-order digits.
- Keep precision, scale, and storage visible in `schema()` and `read_plan()`.
- Returning the unscaled integer, or the raw bytes, is not an option: both are
  silently the wrong quantity rather than an approximation of the right one.

For v0.2.0:

- Return exact fixed-point character, preserving declared trailing zeroes, and
  never route the unscaled integer through `double`.
- Decimal writes take character input plus explicit precision and scale. Parse
  exactly and reject malformed, inexact, or out-of-range values before creating
  the output file.

### Nested release boundary

v0.1.0 reads and writes flat schemas only.

- Reads omit selected nested physical leaves and emit one operation-level
  message: `Skipping <n> nested Parquet column(s); nested reading is deferred
  to qio 0.2.0.` The count is physical leaves; use grammatical singular/plural.
- If all selected leaves are nested, preserve rows in zero-column results and
  batches.
- `read_plan()` marks these leaves `nested = TRUE`, `collectible = FALSE`, with
  the v0.2.0 reason.
- Reject nested input and nested writer schemas before creating or truncating
  output.
- A list-column containing one raw scalar per row may still represent flat
  `BYTE_ARRAY`; it is not a Parquet nested type.

After v0.1.0, define complete-path projection and R null semantics before
exposing canonical list, map, and struct reconstruction. Reject unsupported
legacy or recursive shapes instead of flattening their meaning.

## Implementation sequence

1. **Shared planning:** keep allocation, null handling, copying, and logical
   conversion behind one schema-driven plan; generate mapping documentation
   from the registry.
2. **Core scalars:** `DATE`, UTC `TIMESTAMP`, explicit `INT64`/`FLOAT` writes,
   and read-only `INT96` are done. Add 64-bit read modes and boundary fixtures.
3. **Binary and text:** separate bytes from text; add fixed binary, UUID, JSON,
   BSON, enum, and float16.
4. **Exact decimal:** support every physical storage form and explicit writes.
5. **Remaining temporal/integer types:** finish timezone, `TIME`, and
   integer-width annotations. `INTERVAL` needs no work here: step 3 already
   returns its 12 bytes exactly.
6. **Nested values:** lists first, then null variants, structs, maps,
   parent-path projection, and finally writes.
7. **Extensions:** structured variant and geospatial interpretation, and a
   dedicated interval class.

The roadmap tracks scheduling; this order records type dependencies. Steps 1
through 5 are v0.1.0; steps 6 and 7 are v0.2.0.

## Compatibility

New logical interpretation can change the class of a file qio already decodes
physically. Record such changes in `NEWS.md`, cover them with cross-writer
fixtures, and release them deliberately. When a better mapping would be lossy
or ambiguous, keep an exact fallback or reject it explicitly.
