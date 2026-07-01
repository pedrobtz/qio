#' Show Parquet physical type mappings
#'
#' Lists every Parquet physical type and the corresponding R storage type used
#' by qio when reading or writing. Missing values indicate unsupported
#' mappings. `INT96` is a deprecated physical type used only for timestamps and
#' is read as `POSIXct`. Other logical annotations, such as `DATE` and
#' `TIMESTAMP`, are applied on top of the physical type and are not shown by
#' this table; use [read_plan()] to see the resolved R type per column.
#'
#' @return A data frame with columns `parquet_type`, `read_as`, and
#'   `written_from`.
#' @seealso [read_parquet()], [write_parquet()], [schema()]
#' @export
#' @examples
#' parquet_type_mapping()
parquet_type_mapping <- function() {
  registry <- qio_type_registry()
  data.frame(
    parquet_type = registry$physical_type,
    read_as = registry$r_type,
    written_from = registry$written_from,
    stringsAsFactors = FALSE
  )
}
