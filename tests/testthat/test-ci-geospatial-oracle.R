# GeospatialStatistics and geospatial logical types as DuckDB reads them from
# qio's files. DuckDB's Parquet reader is an independent decoder of the footer,
# so these check the bytes on disk rather than qio reading back its own
# writes. Expected values follow the Parquet Geospatial specification.

duck_metadata <- function(path) {
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(
    con,
    sprintf("SELECT * FROM parquet_metadata('%s')", normalizePath(path))
  )
}

duck_schema <- function(path) {
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(
    con,
    sprintf("SELECT * FROM parquet_schema('%s')", normalizePath(path))
  )
}

geo_file <- function(values, type = "GEOMETRY", crs = NULL) {
  path <- withr::local_tempfile(
    fileext = ".parquet",
    .local_envir = parent.frame()
  )
  df <- data.frame(id = seq_along(values))
  df$g <- values
  spec <- if (is.null(crs)) type else list(type, crs = crs)
  write_parquet(df, path, schema = parquet_schema(g = spec))
  path
}

# The bbox and types DuckDB reads for column `g`, one entry per row group.
duck_geo <- function(path) {
  meta <- duck_metadata(path)
  rows <- meta$path_in_schema == "g"
  bbox <- meta$geo_bbox[rows, , drop = FALSE]
  list(bbox = bbox, types = meta$geo_types[rows])
}

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
