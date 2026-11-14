# Independent implementations used as oracles are not dependencies of qio.
# The files named test-ci-*.R use them, and .Rbuildignore leaves those files
# out of the tarball, so R CMD check and CRAN never see them. In CI the
# oracles workflow sets QIO_ORACLES=true, which makes a missing oracle a
# failure; locally, devtools::test() skips what is not installed.
skip_without_oracle <- function(package) {
  if (identical(Sys.getenv("QIO_ORACLES"), "true")) {
    if (!requireNamespace(package, quietly = TRUE)) {
      stop(sprintf("The oracle package %s is not installed.", package))
    }
    return(invisible())
  }
  skip_on_cran()
  skip_if_not_installed(package)
}

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
