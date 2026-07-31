# API Design Decisions

Resolved choices define the intended API but may still require implementation.
Open choices must be settled before their associated roadmap items begin.

## Resolved

- **Signed `INT64` read mode** (2026-07-31)
  - Materializing read entry points will accept
    `int64 = c("double", "integer64")`; `"double"` is the default.
  - In `"double"` mode, values in the inclusive range from `-2^53` through
    `2^53` are returned as R doubles. Values outside that exactly representable
    range become `NA_real_`.
  - If one or more values are replaced, emit exactly one warning per top-level
    read operation, not one warning per value, column, row group, or batch:
    `Some INT64 or UINT64 values were coerced to NA because they cannot be
    represented exactly as R doubles; use int64 = "integer64" to preserve the
    supported 64-bit range.`
  - In `"integer64"` mode, require the suggested `bit64` package with
    `requireNamespace("bit64", quietly = TRUE)`. If unavailable, fail with a
    clear error rather than falling back to doubles.
  - Preserve the original signed 64-bit payload and return a
    `bit64::integer64` vector. Do not convert through an R double first, because
    that would lose precision before the class is applied.
  - `bit64` reserves the `-2^63` bit pattern as `NA_integer64_`. A real Parquet
    value of `-2^63` therefore cannot be distinguished from missing data in
    `"integer64"` mode; coerce it to `NA_integer64_` and include it in the single
    operation-level integer64 warning when encountered.
  - `read_plan()` must reflect the selected mode, and `read_parquet()`,
    `collect()`, and `walk_batches()` must apply it consistently.

- **Unsigned `INTEGER(64)` / `UINT64` read mode** (2026-07-31)
  - Use the same `int64 = c("double", "integer64")` argument and default as
    signed `INT64`.
  - In `"double"` mode, values from zero through `2^53` are returned exactly as
    R doubles. Values above `2^53` become `NA_real_`.
  - Unsigned replacements in double mode share the signed mode's warning
    accumulator. A read containing both signed and unsigned replacements still
    emits only the single warning shown above.
  - In `"integer64"` mode, values through `2^63 - 1` are returned exactly as
    `bit64::integer64`. Values above `2^63 - 1` cannot be represented as
    nonnegative signed `integer64` values and become `NA_integer64_`.
  - If signed `-2^63` or unsigned values above `2^63 - 1` are replaced in
    integer64 mode, emit exactly one warning per top-level read operation:
    `Some INT64 or UINT64 values were coerced to NA because they cannot be
    represented by bit64::integer64.` Never expose the upper unsigned half as
    negative signed values.
  - Detect both limits from the original 64-bit payload before conversion.

- **Parquet timestamp timezone handling** (2026-07-31)
  - Materializing reads and writes will accept `tz = "UTC"`; UTC is the default
    so results are stable across machines and do not depend on the R session's
    local timezone.
  - Validate a user-supplied timezone before reading, allocating output, or
    creating an output file.
  - A UTC-adjusted Parquet `TIMESTAMP` identifies an instant. On read, `tz`
    controls how its `POSIXct` result is displayed without changing the instant.
    On write, the instant is normalized and stored independently of `tz`.
  - A non-UTC Parquet `TIMESTAMP` contains wall-clock fields without a timezone.
    On read, interpret those fields in `tz` and return `POSIXct`. This deliberately
    chooses a concrete instant because base R has no timezone-agnostic datetime
    class.
  - A user-supplied non-UTC timezone may encounter ambiguous or nonexistent
    civil times at daylight-saving transitions. Follow base R's timezone
    conversion behavior and document this limitation; `tz = "UTC"` avoids it.
  - On writing a non-UTC Parquet `TIMESTAMP`, render each input `POSIXct` value
    as wall-clock fields in `tz`, encode those fields without an offset, and
    discard the timezone. Do not convert through the machine's local timezone.
  - When writing a non-UTC timestamp with `tz != "UTC"`, emit exactly one message
    per top-level write operation:
    `Converting POSIXct values to local time in "<tz>" before writing a non-UTC
    Parquet TIMESTAMP; the timezone is not stored in the file.`
  - Do not emit that message for `tz = "UTC"` or for UTC-adjusted timestamps.
  - `read_plan()` and inferred/explicit writer schemas must report the selected
    timezone and whether the Parquet timestamp is UTC-adjusted.

- **Parquet `TIME` read mode** (2026-07-31)
  - Materializing read entry points will accept
    `time = c("numeric", "hms")`; `"numeric"` is the default.
  - Parquet `TIME` is a time of day without a date. Neither mode returns
    `POSIXct`, because there is no date with which to identify an instant.
  - In `"numeric"` mode, return an ordinary R double containing seconds since
    midnight. Parquet nulls become `NA_real_`.
  - In `"hms"` mode, require the suggested `hms` package with
    `requireNamespace("hms", quietly = TRUE)` and return a genuine `hms`
    vector containing the same seconds-since-midnight values. If the package is
    unavailable, fail with a clear error rather than falling back to numeric.
  - Both modes rescale Parquet milliseconds, microseconds, or nanoseconds to
    seconds and therefore have the same R double precision. Preserve the
    original unit and `isAdjustedToUTC` annotation in the conversion plan or
    result metadata.
  - Reject malformed non-null values outside the valid time-of-day range rather
    than silently wrapping them.
  - `read_plan()` must reflect the selected mode, and `read_parquet()`,
    `collect()`, and `walk_batches()` must apply it consistently.

- **Parquet `DECIMAL` representation** (2026-07-31)
  - Read `DECIMAL` values as ordinary R character vectors. Parquet nulls become
    `NA_character_`; no qio-specific or arbitrary-precision class is required.
  - Format every non-null value in exact fixed-point decimal notation using the
    declared scale, including trailing zeroes. For example, unscaled `1230`
    with scale two becomes `"12.30"`.
  - Decode the unscaled integer directly from each permitted physical storage
    type without converting through R double, so large values are not rounded.
  - Keep precision, scale, and physical storage visible in `schema()` and
    `read_plan()`; the plain character result itself does not carry a class.
  - Writing a character vector as `DECIMAL` requires an explicit
    `parquet_schema()` declaration containing precision and scale. Ordinary
    character vectors continue to infer Parquet `STRING`.
  - Parse decimal strings without converting through R double. Reject values
    that are malformed, exceed the declared precision, or cannot be represented
    exactly at the declared scale.

- **Dictionary-encoded text results** (2026-07-31)
  - Return Parquet text as ordinary R character vectors regardless of whether
    its pages use dictionary, `PLAIN`, or mixed encoding. Parquet nulls become
    `NA_character_`.
  - Do not expose dictionary-encoded text as factors or provide a separate
    dictionary-result mode. Dictionary encoding is a storage optimization, not
    a declaration that the values are categorical; users can explicitly call
    `factor()` when that interpretation is appropriate.
  - Dictionary entry order, unused entries, and differences between row groups
    must not affect the R result. `read_plan()` reports character for text
    independently of the file's physical encoding.
  - qio may use carquet's dictionary values and indexes internally to reduce
    decoding work, but it must materialize R-owned character strings before the
    carquet batch advances. Mixed or plain-encoded pages must transparently use
    the materialized path without changing the result type.
  - This decision concerns reading. Existing factor inputs may continue to be
    converted to character and written as Parquet `STRING`; writer dictionary
    encoding remains a separate configuration decision.

- **Nested writer scope for v0.1.0** (2026-07-31)
  - v0.1.0 writes flat Parquet schemas only. It will not write logical `LIST`,
    `MAP`, struct/group, repeated fields, or nested combinations of them.
  - Reject nested R inputs and nested writer-schema declarations with a clear
    error before creating or truncating the output file.
  - A list-column whose elements represent one flat scalar value, such as raw
    bytes for a `BYTE_ARRAY`, is not a Parquet nested type and may be supported
    by a scalar writer mapping.
  - Nested writing is deferred until after v0.1.0 and until the corresponding R
    read representations and null semantics are stable.

- **Nested reader scope for v0.1.0** (2026-07-31)
  - v0.1.0 materializes flat, non-repeated Parquet leaves only. Nested `LIST`,
    `MAP`, struct/group, repeated fields, and nested combinations are deferred
    to v0.2.0.
  - `read_parquet()`, `collect()`, and `walk_batches()` omit selected nested
    physical leaf columns rather than failing solely because they are nested.
  - Emit exactly one message per top-level materializing read operation when
    one or more nested leaves are omitted: `Skipping <n> nested Parquet
    column(s); nested reading is deferred to qio 0.2.0.` Use grammatically
    correct singular or plural wording.
  - The count is the number of selected physical leaf columns, not the number
    of top-level nested parents. Do not emit a message when no selected column
    is nested.
  - If every selected column is nested, `collect()` and `read_parquet()` return
    a zero-column data frame with the selected number of rows;
    `walk_batches()` invokes the callback with zero-column batches.
  - `read_plan()` marks these leaves as `nested = TRUE`,
    `collectible = FALSE`, and explains that reading is deferred to v0.2.0.

- **Reusable writer configuration** (2026-07-31)
  - `write_parquet()` will accept a reusable writer-configuration object rather
    than gaining a separate top-level argument for every operational setting.
  - The configuration owns writer tuning such as compression and compression
    level, row-group and page sizing, statistics, checksums, and global or
    per-column encoding choices.
  - `parquet_schema()` remains separate: the schema describes logical and
    physical column types, while the writer configuration controls how those
    columns are encoded into a file.
  - A configuration must be self-contained, reusable across writes, and
    validated before creating or truncating an output file. Do not rely on
    process-wide R options or mutable global state.
  - Per-column settings use complete schema paths so duplicate leaf names do
    not make the target ambiguous.
  - The default configuration must preserve qio's documented default behavior
    without requiring users to construct an object for ordinary writes.

## Open

- **Writer configuration contents**
  - Choose the public constructor and `write_parquet()` argument names.
  - Decide whether row-group sizing is expressed in rows, bytes, or both.
  - Define the v0.1.0 fields and defaults, including the exact global and
    per-column dictionary-encoding controls. Dictionary control must use
    carquet's effective per-column encoding API; its global
    `dictionary_encoding` option is not applied by the vendored default policy.

## Deferred Beyond v0.1.0

- **Nested reading in v0.2.0** (2026-07-31)
  - Define parent projection and duplicate-name addressing before nested
    projection is exposed.
  - Define R representations for structs, lists, and maps, including null list
    versus empty list and null element semantics.
  - Start with canonical Parquet nesting and reject unsupported legacy or
    recursive shapes clearly rather than collapsing their semantics.

- **Predicate/filter API** (2026-07-31)
  - v0.1.0 focuses on the core read and write APIs. It will not add a predicate
    expression language, automatic row filtering, or predicate pushdown.
  - Explicit column and row-group selection remain part of the read API; they
    do not require a predicate language.
  - After v0.1.0, define filter construction, null semantics, unsupported
    operations, and fallback behavior when statistics or page indexes are
    unavailable before exposing carquet's pruning facilities.

- **In-memory raw-vector I/O** (2026-07-31)
  - v0.1.0 supports path-based `read_parquet()` and `write_parquet()` only.
    Reading or returning a complete Parquet file as an R `raw` vector is not
    required for the first release.
  - Carquet's memory-backed reader and writer remain available for a later API
    when HTTP, object-storage, database-BLOB, caching, or testing use cases
    justify exposing them.
  - After v0.1.0, decide whether existing functions accept raw vectors or
    whether explicit `read_parquet_buffer()` and `write_parquet_buffer()`
    functions provide the clearer contract.
  - Any future implementation must keep input bytes alive while a reader uses
    them and return writer output as an R-owned raw vector. It will hold the
    complete Parquet file in memory and is not a streaming interface.
