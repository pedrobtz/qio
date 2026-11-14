# GeospatialStatistics and geospatial logical types as DuckDB reads them from
# qio's files. DuckDB's Parquet reader is an independent decoder of the footer,
# so these check the bytes on disk rather than qio reading back its own
# writes. Expected values follow the Parquet Geospatial specification.

test_that("DuckDB reads the statistics of a dictionary-sized chunk (#36)", {
  skip_without_oracle("duckdb")
  path <- geo_file(list(wkb_point(1, 2), wkb_point(3, 4), wkb_point(1, 2)))
  geo <- duck_geo(path)
  expect_equal(
    unlist(geo$bbox[1, c("xmin", "xmax", "ymin", "ymax")], use.names = FALSE),
    c(1, 3, 2, 4)
  )
  expect_identical(geo$types[[1]], "point")
})

test_that("DuckDB reads a GEOMETRY crs whole (#37)", {
  skip_without_oracle("duckdb")
  path <- geo_file(list(wkb_point(1, 2)), crs = "urn:x, algorithm=KARNEY")
  s <- duck_schema(path)
  expect_match(
    paste(unlist(s[s$name == "g", ]), collapse = " "),
    "urn:x, algorithm=KARNEY",
    fixed = TRUE
  )
})

test_that("DuckDB reads a MultiPolygon column as multipolygon alone (#39)", {
  skip_without_oracle("duckdb")
  square <- wkb_polygon(c(0, 1, 1, 0, 0), c(0, 0, 1, 1, 0))
  path <- geo_file(list(wkb_multi(6L, list(square, square))))
  expect_identical(duck_geo(path)$types[[1]], "multipolygon")
})

test_that("DuckDB reads NaN skipped per dimension in the box (#40)", {
  skip_without_oracle("duckdb")
  path <- geo_file(list(wkb_point(1, NaN), wkb_point(5, 6)))
  geo <- duck_geo(path)
  expect_equal(
    unlist(geo$bbox[1, c("xmin", "xmax", "ymin", "ymax")], use.names = FALSE),
    c(1, 5, 6, 6)
  )
})

test_that("DuckDB reads a file with a non-WKB value, and no statistics (#41)", {
  skip_without_oracle("duckdb")
  curve <- c(
    as.raw(1),
    wkb_u32(8L),
    wkb_u32(3L),
    writeBin(c(100, 0, 150, 50, 200, 0), raw(), size = 8, endian = "little")
  )
  path <- geo_file(list(wkb_point(1, 2), curve, wkb_point(3, 4)))
  # Before #41 the invalid type code 8 made parquet_metadata() fail outright.
  geo <- duck_geo(path)
  expect_true(all(is.na(unlist(geo$bbox[1, ]))))
  expect_length(geo$types[[1]], 0L)
})

test_that("DuckDB reads no box for a pole-crossing GEOGRAPHY (#42)", {
  skip_without_oracle("duckdb")
  path <- geo_file(list(wkb_linestring(c(0, 180), c(60, 60))), "GEOGRAPHY")
  geo <- duck_geo(path)
  expect_true(all(is.na(unlist(geo$bbox[
    1,
    c("xmin", "xmax", "ymin", "ymax")
  ]))))
  expect_identical(geo$types[[1]], "linestring")
})
