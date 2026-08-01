# qio 0.0.0.9000

* Files whose dictionary page is not declared in the column metadata now read.
  Some writers emit a dictionary page as a chunk's first page while setting only
  `data_page_offset`; qio read that page as data and failed. Two files from the
  Apache Parquet reference corpus are readable as a result.

* A column whose encoding is not supported now fails with a message naming the
  column and its encodings, instead of reporting a row-count mismatch that
  looked like file corruption.

* `write_parquet()` no longer allocates scratch proportional to the number of
  rows, and can be interrupted. Columns are encoded in fixed chunks; peak
  memory for a 4-million-row string column fell from 101MB to 40MB.
* Fixed silent corruption of `logical` columns written in more than one chunk,
  whose bit packing restarted at each chunk instead of continuing.

* Writing an all-`NA` logical column now works. It failed outright with an
  out-of-memory error, because a Parquet page holding no present values needs
  no bytes and the vendored encoder treated a zero-size request as failure.

* Fixed silent corruption of large `double` and `float` columns. With any
  compression codec, the vendored writer selected an encoding whose
  implementation was wrong for pages assembled from more than one call, so a
  nullable double column past roughly a megabyte of non-null values was written
  incorrectly: every non-null value came back wrong, and other Parquet readers
  saw the same wrong values. The encoder now transposes each page once, when the
  page is finished, which is what the format requires.

* Reading dictionary-encoded text is roughly twice as fast: repeated values are
  interned once rather than once per row. A 1-million-row low-cardinality
  column went from 0.113 s to 0.062 s. Plain-encoded columns are unaffected.

* Reads through a `parquet_open()` handle now decode columns in parallel even
  without `mmap = TRUE`, by giving each worker its own reader. Collecting a
  1-million-row file went from 0.181 s to 0.063 s. Previously only memory-mapped
  handles decoded in parallel, and memory mapping on its own made no measurable
  difference.
* `collect(batch_size =)` now bounds the scratch memory the reader allocates
  for string and binary columns, which previously scaled with the largest
  selected row group rather than with anything the caller controlled. It still
  does not bound the size of the result; use `walk_batches()` for that.

* Non-UTC `TIMESTAMP` columns are now read as `POSIXct`. A UTC-adjusted column
  is an instant, so the new `tz` argument changes only how it prints; a non-UTC
  column is a wall clock with no zone stored, so its civil components are
  interpreted in `tz`. The machine's local zone is never used implicitly.
  Previously a non-UTC timestamp returned a raw count of sub-second units.
* `TIME` columns are now read as seconds since midnight. The new `time`
  argument selects `"numeric"` or `"hms"`; neither returns `POSIXct`, because a
  time of day is not an instant.
* `INTEGER` annotations are now applied. Unsigned 32-bit columns read as
  `double` and are never negative: a stored `4294967295` previously read as
  `-1`. The narrower widths continue to read as `integer`.

* `DECIMAL` columns are now readable. They return `double` with the declared
  scale applied, so a price stored as unscaled `1230` with scale 2 reads as
  `12.30`, and one message per read notes that values may be inexact. All four
  physical storages are supported. Previously an integer-backed decimal
  returned the unscaled integer and a byte-array-backed one returned raw bytes,
  both silently the wrong quantity. Exact fixed-point reads are planned for
  0.2.0.
* `UUID` columns read as canonical hyphenated text.

* **Breaking:** a `BYTE_ARRAY` column now reads as character only when it
  carries a `STRING`, `ENUM`, or `JSON` annotation. An unannotated column is
  arbitrary bytes and reads as a list of raw vectors, with `NULL` for nulls.
  qio previously returned every `BYTE_ARRAY` as character by assuming UTF-8,
  which silently mangled binary data; Apache Arrow reads these columns as
  binary too. Text columns are now validated as UTF-8 and fail with the column
  path and row when they are not.
* `FIXED_LEN_BYTE_ARRAY` columns are now readable. They return a list of
  fixed-width raw vectors, except `UUID`, which returns canonical hyphenated
  text, and `FLOAT16`, which widens to double.

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
