# qio 0.0.0.9000

* `parquet_open()`, `parquet_close()`, and `parquet_validate()` are renamed to
  `open_parquet()`, `close_parquet()`, and `validate_parquet()`, so every verb
  in the API reads the same way as `read_parquet()` and `write_parquet()`.
  `parquet_schema()` and `parquet_type_mapping()` keep their names: they
  construct and describe rather than act. qio has not been released, so there
  is no deprecation shim.

* `close_parquet()` takes its handle as `x` rather than `file`, which is what
  every other function accepting an open handle already called it. `file` now
  consistently means a path.

* `read_parquet()` gains `columns` and `row_groups`, which it passes to
  `collect()`. Reading a subset of a file previously required opening a handle,
  and selecting columns is the largest speedup available on a wide file because
  an unselected column is never decompressed. Every argument after `file` is
  now name-only, which is how `collect()`, `walk_batches()` and `read_plan()`
  already take the same arguments.

* Warnings about values coerced to `NA` now name the column, and are emitted
  once per affected column rather than once per read. A column that lost
  nothing stays silent, and a column that lost a million values across twenty
  batches still warns once. Previously a wide file produced a single warning
  that said data had been lost without saying where.

* `read_parquet()`, `collect()`, and `walk_batches()` gain `verbose`, which
  reports the read before it happens: the rows, columns, and row groups
  selected, the batch size, and the resolved `read_plan()` for the selected
  columns. It reflects the selection and the `int64`, `time`, and `tz` in
  effect, so it describes the read about to run rather than the file in the
  abstract. Written with `message()`, so `suppressMessages()` silences it.

* `open_parquet(threads =)` defaults to `NULL` for the machine's core count,
  matching every other automatic argument in the package. `0` still means the
  same thing.

* Integer-backed `DECIMAL` columns and non-UTC nanosecond `TIMESTAMP` columns
  are now covered by tests. Both were implemented and correct, but no test
  reached them; found by measuring which conversions the suite actually
  exercises rather than assuming.

* New `?qio-types` consolidates the Parquet-to-R type mapping into one table:
  every physical type, the logical annotations qio applies to it, the R type it
  produces, where precision is lost and why, and whether it can be written.

* 64-bit integer columns written with `DELTA_BINARY_PACKED` now read. Apache
  Arrow uses a larger block size for 64-bit columns than for 32-bit ones, and
  the bundled decoder rejected it, so such a column failed as an unsupported
  encoding while the 32-bit equivalent read fine.

* `write_parquet()` gains `append`, which adds row groups to an existing file.
  qio checks compatibility itself before writing a byte, because the bundled
  library's check compares logical type identity without comparing its
  parameters: it would accept microsecond timestamps appended to a millisecond
  file and rewrite the footer, so rows that were already correct decode wrongly
  afterwards. Nullability is taken from the existing file, so a batch that
  happens to contain no `NA` can still be appended to a nullable column.

* `write_parquet()` gains `sorted_by`, which records that the data is already
  sorted by given columns. It is a declaration only: qio neither sorts the data
  nor checks the claim.

* New `page_index()` reports the per-page bounds, null counts, file offsets, and
  starting rows recorded in a file's page index, one row per page. Files without
  one, including everything qio writes, return no rows.

* New `bloom_filter_may_contain()` tests values against a column chunk's bloom
  filter. `FALSE` means the value is definitely absent; `TRUE` means it may be
  present.

* `write_parquet()` gains `row_group_size`, which sets how many rows go in each
  row group. Row groups are the unit other readers skip on, and qio previously
  wrote every file as a single group, leaving nothing to skip. The default is
  unchanged.

* `write_parquet()` gains `metadata`, a named character vector written into the
  footer and read back by `metadata()`.

* New `column_chunks()` reports how each column is stored in each row group:
  physical type, compression, sizes, encodings, and whether a dictionary page,
  bloom filter, or page index is present.

* New `column_statistics()` reports the per-column, per-row-group value and null
  counts and the minimum and maximum bounds. These are claims made by whoever
  wrote the file; qio does not verify them and does not use them to skip data.

* New `validate_parquet()` checks that a file is structurally valid Parquet and
  says what is wrong in terms of the file -- too small, missing or wrong magic
  marker, truncated, encrypted footer, unparseable footer, or row groups that do
  not add up -- rather than failing inside the footer parser.

* New `?qio-limitations` records what the bundled Parquet library can do that
  qio deliberately does not expose, and why.

* File paths that the active Windows code page cannot represent now work, for
  both reading and writing. Previously such a file could not be opened at all,
  which affected anyone whose paths are not covered by their code page. Reading
  one with `mmap = TRUE` uses buffered I/O instead, since only the mapped path
  still needs a code-page-representable name; the result is identical and, since
  buffered reads became parallel, so is the speed. Other platforms are
  unaffected.

* Reading a Zstandard-compressed file with more than one column now works on
  Windows. The bundled decompressor kept one context for the whole process
  there, rather than one per thread, so a parallel read drove it from two
  threads at once: the read either failed to decode or ended the R session.
  Other platforms were never affected, and `threads = 1` avoided it.

* `logical` columns written with run-length encoding now read. Apache Arrow
  uses that encoding for every boolean column it writes into a version 2 data
  page, so boolean columns in files from Arrow, pyarrow, and Spark previously
  failed to decode.

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

* Reads through a `open_parquet()` handle now decode columns in parallel even
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
* Added persistent `open_parquet()` handles for metadata inspection, projected
  and row-group-aware `collect()` calls, and bounded-memory `walk_batches()`
  processing.
* `parquet_type_mapping()` reports qio's read and write mappings for every
  Parquet physical type.
* `read_parquet()` now uses the same open, collect, and close path as the lazy
  API.
