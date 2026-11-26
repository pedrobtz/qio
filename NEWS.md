# qio (development version)

* `read_parquet()` and `collect()` read nested columns (#73). A struct is a
  data-frame column, a `LIST` a list-column of vectors and a `MAP` a
  list-column of key/value data frames, keeping a null struct, a null list, an
  empty list and a null element apart; the new `is_null_struct()` returns an
  optional struct's null rows. `columns` takes group paths (`"add"`) as well
  as leaf paths (`"add.path"`, which returns `add` with only that field).
  Lists of structs and other shapes with a repetition level above 1 are left
  out with one message of class `qio_message_nested_skipped`, and are an error
  when named in `columns`. `walk_batches()` still reads flat columns only.
  `read_plan()` has a new `shape` column.
* **Compatibility:** files whose nested columns used to be dropped with a
  message now return them, so their results gain columns.
* Columns that share a path, as Arrow writes two columns of one name, each get
  their own conversion; the second used to get the first one's, turning an
  `INT32` into a `Date` (#44).
* A data page with no values, which Arrow writes between two pages of a
  repeated column, no longer stops a read (vendored carquet fix).
* The message `read_parquet()`, `collect()` and `walk_batches()` emit when they
  read `DECIMAL` columns as `double` is now a condition of class
  `qio_message_decimal_double` (a `message`). It names the columns with their
  precision and scale, and its `columns` field is a data frame of `path`,
  `physical_type`, `precision` and `scale`, so a caller can muffle it with
  `withCallingHandlers()` for the columns it has checked (#74).

# qio 0.1.2

## New features

* `write_parquet()` writes a list of raw vectors as a binary (`BYTE_ARRAY`)
  column, with `NULL` for a missing value, and `parquet_schema()` declares it
  as `"BINARY"`, `"GEOMETRY"` or `"GEOGRAPHY"`. The geospatial types hold
  well-known binary (WKB) with a `crs`, stored as given, and for `GEOGRAPHY`
  an edge `algorithm`.
* qio records each geospatial column chunk's statistics as the Parquet
  specification defines them. The geometry types are the top-level ones only:
  a MultiPolygon is listed, its polygons are not. `GEOMETRY` chunks get a
  bounding box, and a `NaN` coordinate is left out of its own dimension only.
  `GEOGRAPHY` chunks get no bounding box, because a geodesic edge can leave
  the box of its vertices. A chunk holding a value that is not valid WKB
  records no geospatial statistics, so readers cannot skip it by mistake.
* `geospatial_statistics()` reports the bounding box and geometry types of
  every `GEOMETRY` and `GEOGRAPHY` column chunk, from qio's files or any
  other writer's, so readers can choose row groups by box before reading
  data.

## Bug fixes

* Fixed `write_parquet(append = TRUE)` leaving the original file unreadable
  when the append failed with an error after writing its first new row group
  (#34). An error during an append now leaves the file as it was, and
  `"bytes"`-encoded strings in columns, names, metadata or `crs` are refused
  before any file is touched.
* `bloom_filter_may_contain()` no longer reports `FALSE`, "definitely
  absent", for values that are present. `bit64::integer64` values are hashed
  exactly, and unsigned columns are checked by their stored bit pattern. A
  fraction, an out-of-range value, or a classed value such as a factor or
  `POSIXct` is now an error instead of a `FALSE`, so code that relied on
  that `FALSE` must convert its values first (#43).
* An explicit `INT32` column no longer writes -2147483648 as a missing value.
  That value is R's integer `NA`, so it is now refused like any other
  out-of-range value, and the error names the row and the value (#38).
* `schema()` reports a `GEOMETRY` or `GEOGRAPHY` CRS whole however long it is.
  Files that put inline PROJJSON there, as DuckDB does, had it cut to 127
  bytes.

# qio 0.1.1

* Fixed undefined behavior reported by CRAN's sanitizer checks (M1-SAN,
  clang-UBSAN and gcc-UBSAN). Batch reads no longer load integer and
  floating-point values through misaligned pointers, and writing a string
  column that contains empty strings no longer passes a NULL pointer to
  `memcmp()` or `memcpy()`. Results were already correct; only the undefined
  behavior is removed.

# qio 0.1.0

* Initial release.
