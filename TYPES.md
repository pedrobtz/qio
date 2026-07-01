# Parquet Type Support

This document describes how `qio` currently maps Parquet values to R, the
limitations of those mappings, and the intended path toward broader type
support.

Parquet has two related type systems:

- A **physical type** describes the bytes stored in a column, such as `INT64`
  or `BYTE_ARRAY`.
- A **logical type** gives those bytes meaning, such as `TIMESTAMP`, `STRING`,
  `DECIMAL`, or `UUID`.

Supporting a physical type is therefore not sufficient by itself. For example,
an `INT64` column may be an integer, a timestamp, a time of day, or the backing
storage for a decimal value. `qio` currently handles a useful subset of the
physical types but does not yet interpret most logical annotations.

## Current behavior

`read_parquet()`, `collect()`, and `walk_batches()` use the following read
mappings. Null values become the corresponding R `NA` value.

| Parquet physical type | Current R type | Status and limitations |
|---|---|---|
| `BOOLEAN` | logical | Supported |
| `INT32` | integer or `Date` | `DATE` is interpreted; other annotations use the physical fallback |
| `INT64` | numeric | Supported; precision is not guaranteed beyond `2^53` |
| `INT96` | `POSIXct` | Read-only legacy timestamp, decoded to a UTC instant |
| `FLOAT` | numeric | Supported; widened from 32-bit to R's 64-bit double |
| `DOUBLE` | numeric | Supported |
| `BYTE_ARRAY` | character | Supported but currently assumed to contain UTF-8 text |
| `FIXED_LEN_BYTE_ARRAY` | — | Unsupported |

The current writer infers a Parquet type from each R column:

| R input | Parquet output | Notes |
|---|---|---|
| logical | `BOOLEAN` | Required unless the column contains `NA` |
| integer | `INT32` | Required unless the column contains `NA` |
| numeric | `DOUBLE` | `NA` is null; `NaN` remains a value |
| character | `BYTE_ARRAY` + `STRING` | Encoded as UTF-8 |
| factor | `BYTE_ARRAY` + `STRING` | Converted to character; levels are not preserved |

`infer_parquet_schema()` displays these choices before writing.
`parquet_schema()` creates a reusable partial schema, and
`write_parquet(schema =)` applies it while leaving unspecified columns on the
automatic mapping. Explicit schemas currently support `BOOLEAN`, `INT32`,
`INT64`, `FLOAT`, `DOUBLE`, `STRING`, `DATE`, and UTC-adjusted `TIMESTAMP` with
millisecond, microsecond, or nanosecond units. `INT64` inputs must be finite
whole numbers within R's exact double-integer range (`-2^53` through `2^53`).

Only flat, non-repeated columns can currently be materialized. The schema can
be inspected for nested files, but attempting to collect nested leaves produces
an error.

### Logical annotations

`DATE` and UTC-adjusted `TIMESTAMP` are interpreted. An `INT32` column annotated
`DATE` is read as `Date` and an R `Date` is written as `INT32` + `DATE`. A
UTC-adjusted `INT64` `TIMESTAMP` is read as `POSIXct` in UTC (millisecond,
microsecond, and nanosecond units are rescaled to seconds), and an R `POSIXct`
is written as `INT64` microseconds + a UTC-adjusted `TIMESTAMP`. These
conversions are resolved in R from the read plan (see [`read_plan()`] and
`qio_apply_plan()`), so eager reads, `collect()`, and `walk_batches()` all apply
them. The remaining annotations are reported through `schema()` but not yet
applied; their value conversion is still selected from the physical type.
Consequently:

- non-UTC `TIMESTAMP` values (local civil times) are not applied;
- `DECIMAL` scale and precision are not applied;
- `UUID` and other binary annotations are not interpreted; and
- unannotated binary data is incorrectly treated as UTF-8 text rather than raw
  bytes.

Objects using a double-backed 64-bit integer representation are written as
`DOUBLE`.

### The current `INT64` decision

For now, `qio` reads physical `INT64` values as ordinary R numeric vectors.
This keeps the package dependency-free and is convenient for the common case.
Every integer from `-2^53` through `2^53` can be represented exactly by an R
double. Outside that range, conversion may round distinct integers to the same
R value.

The initial policy is:

- continue returning numeric vectors for unannotated signed `INT64` columns;
- document the precision boundary rather than warning for every such column;
- continue writing ordinary numeric vectors as `DOUBLE`; and
- use `parquet_schema(column = "INT64")` to explicitly write a numeric vector
  as `INT64`.

An exact opt-in representation based on `bit64::integer64`, or an equivalent
bit-preserving class, can be added later. Exact support must copy the underlying
64 bits rather than convert through a C `double`.

## Design principles for new mappings

New type support should follow these rules:

1. Logical annotations take precedence over physical fallback mappings.
2. Eager reads, lazy collection, and batch walking use the same conversion
   implementation.
3. Exact types such as decimal and binary are not silently converted to a
   lossy or textual representation.
4. Ordinary R types keep unsurprising defaults. Ambiguous writer choices, such
   as `FLOAT` versus `DOUBLE`, require an explicit schema or type declaration.
5. Unsupported combinations fail with the column path, physical type, logical
   type, and relevant parameters in the error.
6. Values returned to R own their memory and never retain pointers into a
   carquet batch.
7. Read and write mappings should be symmetric whenever the R representation
   identifies a unique Parquet type.

Internally, qio should build one conversion plan for each selected leaf. A plan
would contain the physical type, logical annotation and parameters, fixed byte
length, maximum definition and repetition levels, target R representation, and
conversion functions. This would replace the duplicated physical-type switches
in the current eager writer and lazy reader.

`parquet_type_mapping()` should eventually be generated from the same mapping
registry so its output cannot drift from the native implementation.

## Target mappings

The tables below describe the preferred direction. Some representations remain
design choices and are marked accordingly.

### Core scalar types

| Parquet type | Proposed R representation | Notes |
|---|---|---|
| `BOOLEAN` | logical | Already supported |
| signed `INTEGER(8/16/32)` | integer | Validate the annotation against the physical type |
| signed `INTEGER(64)` | numeric initially | Add an exact `integer64` option later |
| unsigned `INTEGER(8/16)` | integer | Values fit in an R integer |
| unsigned `INTEGER(32)` | numeric | Values do not all fit in an R integer |
| unsigned `INTEGER(64)` | exact class or character | Numeric cannot represent the complete range |
| unannotated `INT32` | integer | Already supported |
| unannotated `INT64` | numeric | Current precision policy applies |
| `FLOAT` | numeric | Already supported for reads |
| `DOUBLE` | numeric | Already supported |
| `FLOAT16` | numeric | Decode the 16-bit IEEE value and widen to double |
| `NULL` | logical containing only `NA` | Preserve row count without inventing values |

Ordinary R numeric vectors should continue to write as `DOUBLE`. Writing
`FLOAT`, `FLOAT16`, or `INT64` requires an explicit type because R numeric
storage alone cannot distinguish the intended Parquet representation.

### Dates and times

| Parquet logical type | Proposed R representation | Important details |
|---|---|---|
| `DATE` | `Date` | Physical `INT32`, measured in days since 1970-01-01 |
| `TIMESTAMP`, UTC-adjusted | `POSIXct` with `tz = "UTC"` | Rescale millis, micros, or nanos to seconds |
| `TIMESTAMP`, not UTC-adjusted | To be decided | It is a local civil time, not an instant; plain `POSIXct` is not semantically exact |
| `TIME` | Small qio time-of-day class | Preserve unit and UTC-adjusted metadata |
| legacy timestamp converted types | Same as modern timestamp | Normalize legacy annotations during planning |

`POSIXct` is stored as a double number of seconds. Millisecond timestamps are
usually representable, while microsecond or nanosecond precision may be lost,
especially far from the Unix epoch. The implementation should check overflow,
define its rounding behavior, and preserve the original Parquet unit as an
attribute when useful.

Writing `Date` can be inferred safely. Writing `POSIXct` should use an explicit
or documented default unit, likely microseconds, with a clear policy for
fractional values that cannot be represented in that unit.

### Strings, binary values, and UUIDs

| Parquet type | Proposed R representation | Notes |
|---|---|---|
| `BYTE_ARRAY` + `STRING` | character | Validate and create UTF-8 R strings |
| `BYTE_ARRAY` without a text annotation | list-column of raw vectors | Must not pass arbitrary bytes to R's string API |
| `FIXED_LEN_BYTE_ARRAY` | list-column of raw vectors | Validate every value against `type_length` |
| `UUID` | canonical character UUID | Physical value must be exactly 16 bytes |
| `ENUM` | character initially | Parquet does not carry a complete R factor-level definition |
| `JSON` | character | Preserve JSON text; parsing remains the caller's choice |
| `BSON` | list-column of raw vectors | Preserve BSON bytes without an additional dependency |

A future writer schema should distinguish string, variable binary, fixed
binary, and UUID columns. Inferring all four from an ordinary character vector
would be ambiguous.

### Decimal values

Parquet decimal values are signed unscaled integers plus a declared precision
and scale. Their physical storage may be `INT32`, `INT64`, `BYTE_ARRAY`, or
`FIXED_LEN_BYTE_ARRAY`. Binary decimal integers use big-endian two's-complement
encoding.

The first exact representation should be a character-backed `qio_decimal`
vector carrying precision and scale. This avoids silently rounding large
decimal values through R numeric storage and avoids requiring an arbitrary
precision dependency. Numeric conversion can be an explicit user operation.

Writing decimal values must know both precision and scale. These cannot be
reliably inferred from an ordinary numeric vector, so the writer will need an
explicit schema declaration or a decimal constructor that stores those
parameters.

### Nested types

Nested support is a separate materialization project rather than another scalar
conversion case.

| Parquet structure | Proposed R representation |
|---|---|
| `LIST` | list-column whose elements are vectors or nested objects |
| `MAP` | list-column of key/value data frames |
| group/struct | nested data-frame or named-list column |

Maps should not become ordinary named lists because Parquet keys need not be
strings and their representation should not rely on R names being unique.

Carquet exposes leaf streams and definition and repetition levels, along with
helpers for counting rows and finding list boundaries. qio must still:

- build and validate the schema tree;
- coordinate all leaves belonging to one nested field;
- distinguish null lists, empty lists, null elements, and missing structs;
- avoid splitting a repeated logical row across R batches;
- reconstruct parent objects after projected reads; and
- define whether selecting a parent path selects all descendant leaves.

This work should use carquet's low-level column readers because reconstruction
needs the original definition and repetition streams.

### Specialized and extension types

Carquet recognizes additional logical annotations that can be exposed after the
core mappings are stable:

| Parquet type | Initial direction |
|---|---|
| `INTERVAL` | A class preserving months, days, and milliseconds separately |
| `VARIANT` | Preserve metadata and value bytes before attempting structured decoding |
| `GEOMETRY` | Raw WKB list-column plus CRS metadata; optional conversion by spatial packages |
| `GEOGRAPHY` | Raw WKB list-column plus CRS and edge-algorithm metadata |

Keeping the initial representation dependency-light allows downstream packages
to perform richer conversions without making qio depend on large type-specific
ecosystems.

### Legacy `INT96`

`INT96` is deprecated but is now read (read-only) as a UTC `POSIXct`. It has no
standard logical annotation and historical writers differ in their timezone
assumptions, so qio interprets every `INT96` value as a UTC instant. The 12-byte
value stores nanoseconds since midnight in the first two little-endian words and
a Julian day number in the third; qio decodes it in C to seconds since the epoch
(`julian_day - 2440588` days plus `nanos / 1e9`) and adds the `POSIXct` class in
R. The decode is endian-safe because carquet reads the three words as
little-endian `uint32_t`. qio does not write `INT96`.

Remaining follow-ups:

- test more legacy writers (Impala, Hive) beyond the current Spark fixture; and
- consider a documented option for a non-UTC interpretation if real files need
  it.

## Roadmap

### 1. Unify scalar conversion

- Add a schema-driven conversion-plan structure shared by `collect()` and
  `walk_batches()`.
- Move allocation, null handling, and batch copying behind the plan.
- Normalize modern and legacy logical annotations before choosing an R type.
- Make `parquet_type_mapping()` report the authoritative registry.
- Add cross-writer fixtures for every supported mapping and boundary value.

### 2. Add the most useful logical scalars

- Read and write `DATE` as `Date`. **Done.**
- Read UTC-adjusted `TIMESTAMP` as `POSIXct` and define unit/rounding behavior.
  **Done** (read rescales the stored unit; write uses microseconds).
- Keep the current numeric `INT64` default and test its `2^53` boundary.
- Add an optional exact signed-`INT64` representation later.
- Add an explicit writer schema so numeric data can be requested as `INT64` or
  `FLOAT`; validate integer-valued and range constraints before writing
  `INT64`.

### 3. Correct binary handling

- Restrict character conversion to text annotations.
- Materialize variable and fixed binary as raw-vector list-columns.
- Add UUID parsing, formatting, validation, and symmetric writing.
- Add JSON, BSON, enum, and float16 scalar mappings.

### 4. Add exact decimals

- Decode all four permitted decimal physical representations.
- Introduce an exact character-backed decimal vector with precision and scale.
- Add explicit decimal writer declarations and boundary validation.
- Test negative values, leading and trailing zeroes, maximum precision, and
  malformed annotations.

### 5. Add remaining temporal and integer annotations

- Decide and implement a non-UTC local timestamp representation.
- Add time-of-day and interval classes.
- Handle signed and unsigned integer widths deliberately, including unsigned
  64-bit values that cannot fit in R numeric storage.

### 6. Reconstruct nested values

- Start with one-level lists of required primitive elements.
- Add nullable lists and nullable elements.
- Add structs, nested lists, and maps.
- Integrate parent-path projection and batch boundaries.
- Add writer support only after the corresponding read representation is
  stable.

### 7. Add specialized types and legacy timestamps

- Preserve variant and geospatial payloads with their metadata.
- Offer optional integrations in other packages rather than mandatory heavy
  dependencies.
- Read-only `INT96` timestamp support is **done**; qio never writes `INT96`.

## Compatibility policy

Adding logical interpretation can change the R class returned for a file that
qio already reads physically. For example, an `INT32` column annotated as
`DATE` will change from integer to `Date`. Such changes should be called out in
`NEWS.md`, covered by explicit fixtures, and released deliberately.

Where a better mapping would be lossy or ambiguous, qio should retain an exact
fallback or report an unsupported type rather than silently manufacture a
plausible but incorrect value.
