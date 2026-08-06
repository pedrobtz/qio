#' Show Parquet physical type mappings
#'
#' Lists every Parquet physical type and the R storage type qio uses for it
#' **when the column carries no logical annotation**. Missing values indicate
#' unsupported mappings.
#'
#' These are physical fallbacks, and most real columns are annotated, so this
#' table is not a prediction of what a given file will produce. Use
#' [read_plan()] for that: it resolves the annotation, the `int64`, `time`, and
#' `tz` options, and reports the R type each column will actually materialize
#' as.
#'
#' Two entries are worth reading carefully. `BYTE_ARRAY` and
#' `FIXED_LEN_BYTE_ARRAY` are bytes here, returned as a list of raw vectors,
#' because bytes are only text when the file says so; a `STRING`, `ENUM`, or
#' `JSON` annotation is what makes a `BYTE_ARRAY` character. `INT96` is a
#' deprecated physical type used only for timestamps, so it is read as
#' `POSIXct` with no annotation involved.
#'
#' @return A data frame with one row per Parquet physical type and the columns:
#'   \describe{
#'     \item{`physical_type`}{Parquet physical type, spelled as [schema()] and
#'       [read_plan()] report it.}
#'     \item{`r_type`}{R type produced with no logical annotation, spelled as
#'       [read_plan()] reports it. `NA` when the type cannot be read.}
#'     \item{`written_from`}{R input that infers this physical type, or `NA`
#'       when [write_parquet()] cannot produce it.}
#'   }
#' @seealso [read_parquet()], [write_parquet()], [schema()]
#' @export
#' @examples
#' parquet_type_mapping()
parquet_type_mapping <- function() {
  registry <- qio_type_registry()
  # `physical_type` and `r_type` rather than `parquet_type` and `read_as`: the
  # same two concepts are named that way by schema() and read_plan(), and one
  # spelling per concept is worth more than a locally prettier name.
  data.frame(
    physical_type = registry$physical_type,
    r_type = registry$r_type,
    written_from = registry$written_from,
    stringsAsFactors = FALSE
  )
}
