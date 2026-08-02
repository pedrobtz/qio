#' Parquet type mapping
#'
#' The complete mapping between Parquet types and R, in one table: what each
#' physical type carries, which logical annotations qio applies to it, what
#' reading produces, and whether writing can produce it.
#'
#' A Parquet column has a *physical* type, which is how its bytes are stored,
#' and optionally a *logical* annotation, which says what those bytes mean. The
#' annotation decides the R type wherever qio implements one; the physical type
#' is the fallback when there is no annotation or qio does not implement it.
#'
#' [read_plan()] answers the same question for one real file, including the
#' effect of the `int64`, `time`, and `tz` arguments. Prefer it when you have
#' the file in hand; this table is the general contract.
#'
#' @section Read and write mapping:
#'
#' Reading covers the whole table. Writing is deliberately narrower: qio writes
#' the types R can express unambiguously, and an explicit [parquet_schema()]
#' selects among them. Everything marked "no" under writing is readable but not
#' writable.
#'
#' | Physical | Logical | Reads as | Notes and precision | Writes |
#' |---|---|---|---|---|
#' | `BOOLEAN` | none | `logical` | Exact. | from `logical` |
#' | `INT32` | none | `integer` | `-2147483648` becomes `NA`: R reserves it as `NA_integer_`. One warning per read. | from `integer` |
#' | `INT32` | `DATE` | `Date` | Exact. Days since 1970-01-01. | from `Date` |
#' | `INT32` | `TIME(MILLIS)` | `double` or `hms` | Seconds since midnight. Never `POSIXct`: a time of day is not an instant. `time = "hms"` needs the `hms` package. | no |
#' | `INT32` | `INTEGER(8/16/32, signed)` | `integer` | Exact. The sentinel rule above applies. | no |
#' | `INT32` | `INTEGER(8/16, unsigned)` | `integer` | Exact; both fit in R's signed 32-bit integer. | no |
#' | `INT32` | `INTEGER(32, unsigned)` | `double` | Exact. Widened so the upper half stays positive: `4294967295` reads as itself, not `-1`. | no |
#' | `INT32` | `DECIMAL(p, s)` | `double` | Scale applied, so unscaled `1230` scale 2 reads `12.30`. Approximate; one message per read. | no |
#' | `INT64` | none | `double`, or `integer64` | Default `int64 = "double"` is exact in `[-2^53, 2^53]` and `NA` outside it. `int64 = "integer64"` covers the full signed range and needs `bit64`. One warning per read when anything is dropped. | from `numeric`, explicit schema |
#' | `INT64` | `TIMESTAMP(unit, UTC)` | `POSIXct` | An instant; `tz` changes only display. Stored as `double` seconds, so sub-second precision degrades far from the epoch, most visibly for `NANOS`. | from `POSIXct`, UTC only |
#' | `INT64` | `TIMESTAMP(unit, local)` | `POSIXct` | A wall clock with no zone stored. Civil components are read in `tz`; the machine's local zone is never used implicitly. | no |
#' | `INT64` | `TIME(MICROS/NANOS)` | `double` or `hms` | As `INT32` `TIME` above. | no |
#' | `INT64` | `INTEGER(64, signed)` | `double` or `integer64` | As bare `INT64`. | no |
#' | `INT64` | `INTEGER(64, unsigned)` | `double` or `integer64` | Never negative. Exact to `2^53` in double mode, to `2^63 - 1` with `bit64`; above that, `NA`. | no |
#' | `INT64` | `DECIMAL(p, s)` | `double` | As `INT32` `DECIMAL`. | no |
#' | `INT96` | none | `POSIXct` | Deprecated; only ever a timestamp. Read as UTC from its Julian-day and nanosecond parts. | no |
#' | `FLOAT` | none | `double` | Exact: every 32-bit float is representable as a double. | from `numeric`, explicit schema |
#' | `DOUBLE` | none | `double` | Exact. | from `double` |
#' | `BYTE_ARRAY` | `STRING`, `ENUM`, `JSON` | `character` | Validated as UTF-8; invalid bytes fail with the column and row. Embedded nul bytes are rejected: R cannot hold them. | from `character` or `factor`, as `STRING` |
#' | `BYTE_ARRAY` | `DECIMAL(p, s)` | `double` | Big-endian two's complement, scale applied. As `INT32` `DECIMAL`. | no |
#' | `BYTE_ARRAY` | none, `BSON`, other | `list` of `raw` | Arbitrary bytes stay bytes; `NULL` for nulls. Returning character would assume an encoding the file never claimed. | no |
#' | `FIXED_LEN_BYTE_ARRAY` | `UUID` | `character` | Canonical hyphenated form from exactly 16 bytes. | no |
#' | `FIXED_LEN_BYTE_ARRAY` | `FLOAT16` | `double` | Exact: every half-precision value is representable as a double. | no |
#' | `FIXED_LEN_BYTE_ARRAY` | `DECIMAL(p, s)` | `double` | As `BYTE_ARRAY` `DECIMAL`. | no |
#' | `FIXED_LEN_BYTE_ARRAY` | none, `INTERVAL`, other | `list` of `raw` | Fixed-width raw vectors, each validated against the declared length. `INTERVAL` has no R class in 0.1.0. | no |
#' | any | `NULL` | `logical` | All `NA`, whatever the physical type: the annotation means the column carries no values. The row count is preserved. | no |
#' | any | `LIST`, `MAP`, struct | not read | Skipped with one message per operation. Nested reading is deferred to 0.2.0. | no |
#'
#' @section Where precision is lost:
#'
#' Four cases lose information, all of them because R's types are narrower than
#' Parquet's. Each is reported rather than silent.
#'
#' \describe{
#'   \item{`INT32` holding `-2147483648`}{R reserves that value as
#'     `NA_integer_`, so it cannot be stored. It reads as `NA` with one warning
#'     per read. Promoting the column to `double` was rejected: [read_plan()] is
#'     a pure function of the schema, and a data-dependent type would let one
#'     column arrive as different types in different batches.}
#'   \item{64-bit integers past 2^53}{R's `double` is exact only within
#'     `[-2^53, 2^53]`. Values outside it read as `NA` with one warning; pass
#'     `int64 = "integer64"` to keep the full signed range.}
#'   \item{`DECIMAL`}{Read as `double` with the declared scale applied, which is
#'     exact only while the unscaled integer stays within `[-2^53, 2^53]`. Larger
#'     precisions lose low-order digits. One message per read. Exact fixed-point
#'     reads are planned for 0.2.0.}
#'   \item{Sub-second timestamps far from the epoch}{`POSIXct` is a `double` of
#'     seconds, so the further a timestamp is from 1970 the less sub-second
#'     precision survives. A `NANOS` column shows this first.}
#' }
#'
#' Writing loses nothing that reading would not: qio writes only the types it
#' can represent exactly. `POSIXct` is the one rounding case, to the declared
#' timestamp unit, which defaults to microseconds.
#'
#' @section What writing supports:
#'
#' Without a schema, qio infers: `logical` to `BOOLEAN`, `integer` to `INT32`,
#' `double` to `DOUBLE`, `character` and `factor` to `BYTE_ARRAY` with `STRING`,
#' `Date` to `INT32` with `DATE`, and `POSIXct` to `INT64` with a UTC-adjusted
#' `TIMESTAMP` in microseconds.
#'
#' An explicit [parquet_schema()] may additionally select `INT64` or `FLOAT` for
#' a numeric column, and a different `TIMESTAMP` unit. Those are the only
#' combinations the writer accepts; anything else is an error rather than a
#' silent fallback.
#'
#' A column is written `OPTIONAL` when it contains any `NA` and `REQUIRED`
#' otherwise, except when appending, where the existing file decides. For
#' `double` columns `NA` becomes a Parquet null while `NaN` is preserved as a
#' value.
#'
#' @name qio-types
#' @seealso [read_plan()] for one file, [parquet_type_mapping()] for the
#'   physical fallbacks alone, [qio-limitations] for what is out of scope.
NULL
