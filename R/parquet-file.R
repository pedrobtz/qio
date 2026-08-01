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
#'
#' `collect()` reads each column in full and does not currently sub-divide the
#' read by `batch_size`; the argument is accepted for symmetry with
#' [walk_batches()] and forward compatibility. Neither function bounds the
#' memory occupied by the returned data frame — use [walk_batches()] for
#' bounded-memory processing.
#'
#' Nested and repeated columns are not materialized in qio 0.1.0. When a
#' selection includes them, they are omitted and one message reports how many
#' physical leaf columns were skipped. Nested reading is deferred to qio 0.2.0.
#' If every selected column is nested, the result is a zero-column data frame
#' with the selected number of rows.
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#' @param columns Character vector of complete column paths, or `NULL` for all
#'   columns. Paths are matched exactly as [schema()] and [names()] report
#'   them, dot-separated for nested leaves, and never by leaf name alone: two
#'   leaves may share a name under different parents. An unknown path is an
#'   error, and so is a path matching more than one leaf.
#' @param row_groups Integer vector of 1-based row-group IDs, or `NULL` for all
#'   row groups.
#' @param batch_size Positive batch size in rows. Currently unused by
#'   `collect()` (see Details); [walk_batches()] decodes this many rows per
#'   batch.
#' @param int64 How 64-bit integer columns reach R. `"double"` (the default)
#'   is exact from `-2^53` through `2^53` and returns `NA` outside it.
#'   `"integer64"` returns [bit64::integer64], which covers the full signed
#'   64-bit range, and needs the suggested `bit64` package. Either way values
#'   that cannot be represented become `NA` and one warning is emitted per
#'   read. Unsigned 64-bit columns are never returned as negative numbers.
#' @param time How `TIME` columns reach R: `"numeric"` (the default) returns
#'   seconds since midnight, `"hms"` returns [hms::hms] and needs the suggested
#'   `hms` package. Neither returns `POSIXct`, because a time of day is not an
#'   instant.
#' @param tz Time zone name, `"UTC"` by default. A UTC-adjusted `TIMESTAMP` is
#'   an instant, so `tz` changes only how it prints. A non-UTC `TIMESTAMP` is a
#'   wall clock with no zone stored, so its civil components are interpreted in
#'   `tz`; base R decides ambiguous and nonexistent times at daylight-saving
#'   boundaries. The machine's local zone is never used implicitly.
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
  batch_size = 65536L,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC"
) {
  qio_empty_dots(...)
  options <- qio_read_options(int64 = int64, time = time, tz = tz)
  plan <- read_plan(
    x,
    int64 = options$int64,
    time = options$time,
    tz = options$tz
  )
  columns <- qio_select_columns(plan, qio_columns(columns))
  qio_message_decimal(plan, columns)
  row_groups <- qio_row_groups(row_groups)
  batch_size <- qio_whole_number(batch_size, "batch_size", minimum = 1L)
  result <- .Call(
    C_qio_parquet_collect,
    x,
    columns,
    row_groups,
    batch_size,
    qio_int64_code(options),
    qio_column_kinds(plan, columns)
  )
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
#' @param batch_size Positive number of rows decoded per batch.
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
  batch_size = 65536L,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC"
) {
  if (!is.function(FUN)) {
    stop("`FUN` must be a function.", call. = FALSE)
  }
  options <- qio_read_options(int64 = int64, time = time, tz = tz)
  plan <- read_plan(
    x,
    int64 = options$int64,
    time = options$time,
    tz = options$tz
  )
  columns <- qio_select_columns(plan, qio_columns(columns))
  qio_message_decimal(plan, columns)
  row_groups <- qio_row_groups(row_groups)
  batch_size <- qio_whole_number(batch_size, "batch_size", minimum = 1L)
  callback <- function(batch, index) {
    FUN(qio_apply_plan(batch, plan), index, ...)
  }
  .Call(
    C_qio_parquet_walk,
    x,
    columns,
    row_groups,
    batch_size,
    callback,
    qio_int64_code(options),
    qio_column_kinds(plan, columns)
  )
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

# Resolve requested column paths to 1-based physical leaf indexes.
#
# Selection is by complete schema path, never by leaf name. Two leaves can
# share a name under different parents, and carquet's own lookup compares leaf
# names only, so passing a name to it can silently resolve to the wrong column.
# Resolving here means the native layer only ever receives unambiguous indexes.
qio_resolve_columns <- function(plan, columns) {
  if (is.null(columns)) {
    return(NULL)
  }
  matches <- lapply(columns, function(path) which(plan$path == path))

  unknown <- columns[lengths(matches) == 0L]
  if (length(unknown)) {
    stop(
      "Unknown Parquet column",
      if (length(unknown) == 1L) "" else "s",
      ": ",
      paste0("`", unknown, "`", collapse = ", "),
      ".",
      call. = FALSE
    )
  }

  # A flat column literally named "a.b" and a nested leaf b under group a both
  # render as the path "a.b". Refuse to guess which one was meant.
  ambiguous <- columns[lengths(matches) > 1L]
  if (length(ambiguous)) {
    stop(
      "Ambiguous Parquet column",
      if (length(ambiguous) == 1L) "" else "s",
      ": ",
      paste0("`", ambiguous, "`", collapse = ", "),
      ". More than one leaf has that path.",
      call. = FALSE
    )
  }

  as.integer(unlist(matches))
}

# One code per selected column telling the native layer what R object to build.
# Must stay in step with the QIO_KIND_* constants in src/qio_file.c.
#
# The plan decides, and the native layer is told. A TIMESTAMP is physically
# INT64 but is a count of sub-second units, so applying the `int64` range rules
# would turn every nanosecond timestamp past 2^53 into NA; a UUID is physically
# a fixed byte array whose text form the plan produces. Inferring any of this
# from the schema in C would duplicate the plan and let the two drift.
qio_column_kinds <- function(plan, columns) {
  selected <- if (is.null(columns)) seq_len(nrow(plan)) else columns
  converter <- plan$converter[selected]
  kind <- rep(0L, length(selected)) # QIO_KIND_DEFAULT
  kind[converter %in% c("int64_double", "int64_bit64")] <- 1L # INT64
  kind[converter == "text"] <- 2L # TEXT
  # UUID and FLOAT16 are decoded as raw bytes and converted by the plan.
  kind[converter %in% c("binary", "uuid", "float16")] <- 3L # BINARY
  # Byte-array decimals need their raw bytes; integer-backed ones decode as
  # ordinary numbers and are scaled by the plan.
  kind[startsWith(converter, "decimal_binary_")] <- 3L # BINARY
  kind[converter == "uint32"] <- 4L # UINT32
  kind
}

# One message per read when decimal columns are present. v0.1.0 reads them as
# double with the scale applied; exact fixed-point character is v0.2.0, so the
# values may be inexact and the user is told once. See .agents/TYPES.md.
qio_message_decimal <- function(plan, columns) {
  selected <- if (is.null(columns)) seq_len(nrow(plan)) else columns
  n <- sum(startsWith(plan$converter[selected], "decimal_"), na.rm = TRUE)
  if (n > 0L) {
    message(
      "Reading ",
      n,
      " Parquet DECIMAL column",
      if (n == 1L) "" else "s",
      " as double; values may be inexact. Exact decimals are deferred to ",
      "qio 0.2.0."
    )
  }
  invisible(NULL)
}

# Resolve a selection and drop leaves qio cannot materialize yet, reporting the
# count once. Returns NULL for "every column", which lets the native layer take
# its own all-columns path, or an integer vector of 1-based leaf indexes.
qio_select_columns <- function(plan, columns) {
  indexes <- qio_resolve_columns(plan, columns)
  if (is.null(indexes)) {
    if (!any(plan$nested)) {
      return(NULL)
    }
    indexes <- seq_len(nrow(plan))
  }

  nested <- plan$nested[indexes]
  n <- sum(nested)
  if (n > 0L) {
    message(
      "Skipping ",
      n,
      " nested Parquet column",
      if (n == 1L) "" else "s",
      "; nested reading is deferred to qio 0.2.0."
    )
  }
  indexes[!nested]
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
