# qio (development version)

* An explicit `INT32` column no longer writes -2147483648 as a missing value.
  That value is R's integer `NA`, so it is now refused like any other
  out-of-range value, and the error names the row and the value (#38).
* `write_parquet()` writes a list of raw vectors as a binary (`BYTE_ARRAY`)
  column, with `NULL` for a missing value, and `parquet_schema()` declares it
  as `"BINARY"`, `"GEOMETRY"` or `"GEOGRAPHY"`. The geospatial types hold
  well-known binary with a `crs` (and, for `GEOGRAPHY`, an edge `algorithm`),
  and qio records each column chunk's geospatial statistics.
* `geospatial_statistics()` reports the bounding box and geometry types of
  every `GEOMETRY` and `GEOGRAPHY` column chunk, so readers can choose row
  groups by box before reading data.
* Fixed the vendored carquet writer recording, for every row group after the
  first, geospatial statistics that included the earlier row groups.
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
