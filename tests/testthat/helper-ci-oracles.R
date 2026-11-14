# DuckDB readers for test-ci-geospatial-oracle.R. Like that file, this one is
# left out of the tarball, so DBI and duckdb never reach R CMD check.

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
