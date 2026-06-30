#' Read a Parquet file
#'
#' Reads an Apache Parquet file into a data frame.
#'
#' Column types are mapped from Parquet as follows: `BOOLEAN` to logical,
#' `INT32` to integer, `INT64`/`FLOAT`/`DOUBLE` to double, and `BYTE_ARRAY`
#' (assumed UTF-8) to character. Parquet nulls become `NA`. `INT64` values are
#' returned as doubles and lose precision beyond 2^53.
#'
#' @param file Path to a Parquet file.
#'
#' @return A data frame.
#'
#' @seealso [write_parquet()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(data.frame(x = 1:3, y = c("a", "b", NA)), path)
#' read_parquet(path)
read_parquet <- function(file) {
  file <- parquet_open(file)
  on.exit(parquet_close(file), add = TRUE)
  collect(file)
}

#' Write a Parquet file
#'
#' Writes a data frame to an Apache Parquet file.
#'
#' Supported column types are logical, integer, double, character, and factor
#' (written as character). A column is written as nullable when it contains any
#' `NA`. Date, time, and other classed columns are written using their
#' underlying storage type and lose their class on a round trip.
#'
#' @param x A data frame (or a list of equal-length atomic vectors).
#' @param file Output path.
#' @param compression Compression codec: one of `"snappy"` (default), `"zstd"`,
#'   `"gzip"`, `"lz4"`, or `"uncompressed"`.
#'
#' @return The output path, invisibly.
#'
#' @seealso [read_parquet()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
write_parquet <- function(
  x,
  file,
  compression = c("snappy", "zstd", "gzip", "lz4", "uncompressed")
) {
  if (!is.data.frame(x)) {
    if (is.list(x)) {
      x <- as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE)
    } else {
      stop("`x` must be a data frame.", call. = FALSE)
    }
  }
  if (!is.character(file) || length(file) != 1L || is.na(file)) {
    stop("`file` must be a single file path.", call. = FALSE)
  }
  compression <- match.arg(compression)
  file <- path.expand(file)
  .Call(C_qio_write_parquet, x, file, compression)
  invisible(file)
}
