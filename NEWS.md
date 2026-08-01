# qio 0.0.0.9000

* 64-bit integer columns are now read correctly. `read_parquet()`, `collect()`,
  `walk_batches()`, and `read_plan()` gain `int64`, which selects `"double"`
  (the default, exact from `-2^53` through `2^53`) or `"integer64"`
  (`bit64::integer64`, covering the full signed 64-bit range). Values that
  cannot be represented become `NA` and one warning is emitted per read.
* Unsigned 64-bit columns are no longer returned as negative numbers. A stored
  `18446744073709551615` previously read as `-1`; values above the selected
  mode's range now become `NA` with a warning. Values between `2^53` and
  `2^63 - 1` also no longer round silently.
* Columns annotated with the Parquet `NULL` logical type now read as all-`NA`
  logical, preserving the row count, instead of their physical fallback.
* Column selection now resolves by complete schema path instead of by leaf
  name. A file with two leaves sharing a name under different parents could
  previously return the wrong column, or reject a flat column as nested. An
  unknown path and a path matching more than one leaf are both errors now.
* Errors about unsupported columns name the complete path, physical type,
  logical annotation with its parameters, and fixed-width length.
* `walk_batches(threads = 1)` is now genuinely single-threaded. The vendored
  batch pipeline raised any request below two threads up to two, so a serial
  read still started a worker.

* Reading an `INT32` column containing `-2147483648` now warns once per read
  instead of returning `NA` silently. R's `integer` reserves that value as
  `NA_integer_`, so it cannot be represented; the column keeps its `integer`
  type so all three read APIs continue to agree.
* A failed `write_parquet()` no longer leaves an empty file behind or leaks the
  native writer. Errors raised while encoding a column now abort the writer and
  release the schema.
* `collect()` and `walk_batches()` now reject a non-positive `batch_size`, and
  validate the types of `columns` and `row_groups` in C as well as in R.
* A Parquet string containing an embedded nul now reports the column and row
  instead of raising R's generic message.
* Errors raised inside a `walk_batches()` callback no longer deparse the whole
  batch into the traceback.
* `collect()`, `read_parquet()`, and `walk_batches()` now skip selected nested
  or repeated columns with one message per operation. Nested reading is deferred
  to qio 0.2.0.
* `infer_parquet_schema()` and `parquet_schema()` now describe automatic writer
  mappings and create reusable partial schemas. `write_parquet(schema =)` can
  explicitly write `BOOLEAN`, `INT32`, `INT64`, `FLOAT`, `DOUBLE`, `STRING`,
  `DATE`, and UTC-adjusted `TIMESTAMP` columns.
* `read_plan()` turns a `schema()` data frame (or an open file) into a per-column
  plan describing the R type each column materializes as, whether it can be
  collected, and why not. It now also accepts a Parquet file path and accurately
  rejects non-repeated nested leaves. It is the shared conversion driver for
  `collect()`, `read_parquet()`, and `walk_batches()`.
* `DATE` columns are now interpreted: an `INT32` column annotated `DATE` reads as
  `Date`, and R `Date` columns are written as `INT32` with a `DATE` annotation.
* UTC-adjusted `TIMESTAMP` columns read as `POSIXct` in UTC (millisecond,
  microsecond, and nanosecond units are rescaled to seconds), and `POSIXct`
  columns are written as `INT64` microseconds with a UTC-adjusted `TIMESTAMP`
  annotation.
* Legacy `INT96` timestamps (Impala/Spark) now read as `POSIXct` in UTC. They
  are read-only; qio does not write `INT96`.
* Fixed compilation with MinGW on Windows when SSE4.2 is not enabled.
* Added persistent `parquet_open()` handles for metadata inspection, projected
  and row-group-aware `collect()` calls, and bounded-memory `walk_batches()`
  processing.
* `parquet_type_mapping()` reports qio's read and write mappings for every
  Parquet physical type.
* `read_parquet()` now uses the same open, collect, and close path as the lazy
  API.
