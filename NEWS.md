# qio (development version)

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

# qio 0.1.1

* Fixed undefined behavior reported by CRAN's sanitizer checks (M1-SAN,
  clang-UBSAN and gcc-UBSAN). Batch reads no longer load integer and
  floating-point values through misaligned pointers, and writing a string
  column that contains empty strings no longer passes a NULL pointer to
  `memcmp()` or `memcpy()`. Results were already correct; only the undefined
  behavior is removed.

# qio 0.1.0

* Initial release.
