# qio 0.0.0.9000

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
