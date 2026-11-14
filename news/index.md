# Changelog

## qio 0.1.2

### New features

- [`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
  writes a list of raw vectors as a binary (`BYTE_ARRAY`) column, with
  `NULL` for a missing value, and
  [`parquet_schema()`](https://pedrobtz.github.io/qio/reference/parquet_schema.md)
  declares it as `"BINARY"`, `"GEOMETRY"` or `"GEOGRAPHY"`. The
  geospatial types hold well-known binary (WKB) with a `crs`, stored as
  given, and for `GEOGRAPHY` an edge `algorithm`.
- qio records each geospatial column chunk’s statistics as the Parquet
  specification defines them. The geometry types are the top-level ones
  only: a MultiPolygon is listed, its polygons are not. `GEOMETRY`
  chunks get a bounding box, and a `NaN` coordinate is left out of its
  own dimension only. `GEOGRAPHY` chunks get no bounding box, because a
  geodesic edge can leave the box of its vertices. A chunk holding a
  value that is not valid WKB records no geospatial statistics, so
  readers cannot skip it by mistake.
- [`geospatial_statistics()`](https://pedrobtz.github.io/qio/reference/geospatial_statistics.md)
  reports the bounding box and geometry types of every `GEOMETRY` and
  `GEOGRAPHY` column chunk, from qio’s files or any other writer’s, so
  readers can choose row groups by box before reading data.

### Bug fixes

- Fixed `write_parquet(append = TRUE)` leaving the original file
  unreadable when the append failed with an error after writing its
  first new row group
  ([\#34](https://github.com/pedrobtz/qio/issues/34)). An error during
  an append now leaves the file as it was, and `"bytes"`-encoded strings
  in columns, names, metadata or `crs` are refused before any file is
  touched.
- [`bloom_filter_may_contain()`](https://pedrobtz.github.io/qio/reference/bloom_filter_may_contain.md)
  no longer reports `FALSE`, “definitely absent”, for values that are
  present.
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
  values are hashed exactly, and unsigned columns are checked by their
  stored bit pattern. A fraction, an out-of-range value, or a classed
  value such as a factor or `POSIXct` is now an error instead of a
  `FALSE`, so code that relied on that `FALSE` must convert its values
  first ([\#43](https://github.com/pedrobtz/qio/issues/43)).
- An explicit `INT32` column no longer writes -2147483648 as a missing
  value. That value is R’s integer `NA`, so it is now refused like any
  other out-of-range value, and the error names the row and the value
  ([\#38](https://github.com/pedrobtz/qio/issues/38)).
- [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md)
  reports a `GEOMETRY` or `GEOGRAPHY` CRS whole however long it is.
  Files that put inline PROJJSON there, as DuckDB does, had it cut to
  127 bytes.

## qio 0.1.1

CRAN release: 2026-09-29

- Fixed undefined behavior reported by CRAN’s sanitizer checks (M1-SAN,
  clang-UBSAN and gcc-UBSAN). Batch reads no longer load integer and
  floating-point values through misaligned pointers, and writing a
  string column that contains empty strings no longer passes a NULL
  pointer to `memcmp()` or `memcpy()`. Results were already correct;
  only the undefined behavior is removed.

## qio 0.1.0

CRAN release: 2026-09-28

- Initial release.
