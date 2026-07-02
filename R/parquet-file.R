#' Open a Parquet file
#'
#' Opens a Parquet file for inexpensive metadata inspection and selective,
#' batched reading. The returned handle is valid only in the current R session.
#'
#' @param file Path to a Parquet file.
#' @param mmap Use memory-mapped input.
#' @param verify_checksums Verify Parquet page checksums when present.
#' @param threads Number of reader threads. Zero picks the machine's core
#'   count. [collect()] decodes columns in parallel only when the file is
#'   opened with `mmap = TRUE` (buffered reads share file state and stay
#'   single-threaded); pass `threads = 1` to force serial reads.
#'
#' @return A `qio_parquet_file` object. Close it with [parquet_close()].
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- parquet_open(path)
#' dim(pf)
#' parquet_close(pf)
parquet_open <- function(
  file,
  mmap = FALSE,
  verify_checksums = TRUE,
  threads = 0L
) {
  file <- qio_file_path(file)
  mmap <- qio_flag(mmap, "mmap")
  verify_checksums <- qio_flag(verify_checksums, "verify_checksums")
  threads <- qio_whole_number(threads, "threads", minimum = 0L)

  file <- .Call(
    C_qio_parquet_open,
    file,
    mmap,
    verify_checksums,
    threads
  )
  class(file) <- "qio_parquet_file"
  file
}

#' Close a Parquet file
#'
#' Explicitly releases the native resources owned by an open Parquet handle.
#' Closing an already closed handle has no effect.
#'
#' @param file A `qio_parquet_file` object.
#'
#' @return `file`, invisibly.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- parquet_open(path)
#' parquet_close(pf)
parquet_close <- function(file) {
  .Call(C_qio_parquet_close, file)
  invisible(file)
}

#' Inspect a Parquet schema
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#'
#' @return A data frame with one row per physical leaf column.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- parquet_open(path)
#' schema(pf)
#' parquet_close(pf)
schema <- function(x, ...) {
  UseMethod("schema")
}

#' @rdname schema
#' @export
schema.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  .Call(C_qio_parquet_schema, x)
}

#' Inspect Parquet row groups
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#'
#' @return A data frame with row counts and compressed and uncompressed sizes.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- parquet_open(path)
#' row_groups(pf)
#' parquet_close(pf)
row_groups <- function(x, ...) {
  UseMethod("row_groups")
}

#' @rdname row_groups
#' @export
row_groups.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  .Call(C_qio_parquet_row_groups, x)
}

#' Inspect Parquet footer metadata
#'
#' Duplicate keys are preserved in their original order.
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#'
#' @return A data frame with `key` and `value` columns.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- parquet_open(path)
#' metadata(pf)
#' parquet_close(pf)
metadata <- function(x, ...) {
  UseMethod("metadata")
}

#' @rdname metadata
#' @export
metadata.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  .Call(C_qio_parquet_metadata, x)
}

#' Collect data from a Parquet file
#'
#' Columns are returned in requested order. Row groups are always returned in
#' their physical file order, even if their selector is not sorted.
#' `batch_size` controls decoding work; it does not bound the memory occupied by
#' the final data frame. Use [walk_batches()] for bounded-memory processing.
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#' @param columns Character vector of exact column paths, or `NULL` for all
#'   columns.
#' @param row_groups Integer vector of 1-based row-group IDs, or `NULL` for all
#'   row groups.
#' @param batch_size Positive number of rows decoded per batch.
#'
#' @return A data frame.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- parquet_open(path)
#' collect(pf, columns = c("mpg", "cyl"))
#' parquet_close(pf)
collect <- function(x, ...) {
  UseMethod("collect")
}

#' @rdname collect
#' @export
collect.qio_parquet_file <- function(
  x,
  ...,
  columns = NULL,
  row_groups = NULL,
  batch_size = 65536L
) {
  qio_empty_dots(...)
  plan <- read_plan(x)
  columns <- qio_columns(columns)
  row_groups <- qio_row_groups(row_groups)
  batch_size <- qio_whole_number(batch_size, "batch_size", minimum = 1L)
  result <- .Call(C_qio_parquet_collect, x, columns, row_groups, batch_size)
  qio_apply_plan(result, plan)
}

#' Walk over batches from a Parquet file
#'
#' Calls `FUN(batch, index, ...)` for every batch. Each batch is an independent
#' data frame and can be retained by the callback when desired. Callback return
#' values are discarded.
#'
#' @inheritParams collect
#' @param FUN Function called with a data frame and a 1-based global batch
#'   index, followed by `...`.
#'
#' @return `x`, invisibly.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- parquet_open(path)
#' walk_batches(pf, function(batch, index) print(head(batch)))
#' parquet_close(pf)
walk_batches <- function(
  x,
  FUN,
  ...,
  columns = NULL,
  row_groups = NULL,
  batch_size = 65536L
) {
  if (!is.function(FUN)) {
    stop("`FUN` must be a function.", call. = FALSE)
  }
  plan <- read_plan(x)
  columns <- qio_columns(columns)
  row_groups <- qio_row_groups(row_groups)
  batch_size <- qio_whole_number(batch_size, "batch_size", minimum = 1L)
  callback <- function(batch, index) {
    FUN(qio_apply_plan(batch, plan), index, ...)
  }
  .Call(C_qio_parquet_walk, x, columns, row_groups, batch_size, callback)
  invisible(x)
}

#' @export
dim.qio_parquet_file <- function(x) {
  .Call(C_qio_parquet_dim, x)
}

#' @export
names.qio_parquet_file <- function(x) {
  .Call(C_qio_parquet_names, x)
}

#' @export
print.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  path <- .Call(C_qio_parquet_path, x)
  if (!.Call(C_qio_parquet_is_open, x)) {
    cat("<qio_parquet_file [closed]>\n", path, "\n", sep = "")
    return(invisible(x))
  }

  dimensions <- dim(x)
  groups <- nrow(row_groups(x))
  cat(
    "<qio_parquet_file>\n",
    path,
    "\n",
    format(dimensions[[1L]], scientific = FALSE),
    " rows x ",
    format(dimensions[[2L]], scientific = FALSE),
    " columns; ",
    groups,
    if (groups == 1L) " row group\n" else " row groups\n",
    sep = ""
  )
  invisible(x)
}

qio_file_path <- function(file) {
  if (!is.character(file) || length(file) != 1L || is.na(file)) {
    stop("`file` must be a single file path.", call. = FALSE)
  }
  file <- path.expand(file)
  if (!file.exists(file)) {
    stop("File does not exist: ", file, call. = FALSE)
  }
  file
}

qio_flag <- function(x, name) {
  if (!is.logical(x) || length(x) != 1L || is.na(x)) {
    stop("`", name, "` must be `TRUE` or `FALSE`.", call. = FALSE)
  }
  x
}

qio_whole_number <- function(x, name, minimum) {
  if (
    !is.numeric(x) ||
      length(x) != 1L ||
      is.na(x) ||
      !is.finite(x) ||
      x < minimum ||
      x > .Machine$integer.max ||
      x != trunc(x)
  ) {
    stop(
      "`",
      name,
      "` must be a whole number between ",
      minimum,
      " and ",
      .Machine$integer.max,
      ".",
      call. = FALSE
    )
  }
  as.integer(x)
}

qio_columns <- function(columns) {
  if (is.null(columns)) {
    return(NULL)
  }
  if (!is.character(columns) || anyNA(columns)) {
    stop(
      "`columns` must be a character vector without missing values.",
      call. = FALSE
    )
  }
  if (anyDuplicated(columns)) {
    stop("`columns` must not contain duplicates.", call. = FALSE)
  }
  columns
}

qio_row_groups <- function(row_groups) {
  if (is.null(row_groups)) {
    return(NULL)
  }
  if (
    !is.numeric(row_groups) ||
      anyNA(row_groups) ||
      any(!is.finite(row_groups)) ||
      any(row_groups < 1) ||
      any(row_groups > .Machine$integer.max) ||
      any(row_groups != trunc(row_groups))
  ) {
    stop("`row_groups` must contain positive whole numbers.", call. = FALSE)
  }
  if (anyDuplicated(row_groups)) {
    stop("`row_groups` must not contain duplicates.", call. = FALSE)
  }
  as.integer(row_groups)
}

qio_empty_dots <- function(...) {
  dots <- list(...)
  if (length(dots)) {
    stop("`...` must be empty.", call. = FALSE)
  }
  invisible(NULL)
}
