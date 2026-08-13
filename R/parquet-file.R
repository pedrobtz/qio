#' Open a Parquet file
#'
#' Opens a Parquet file for inexpensive metadata inspection and selective,
#' batched reading. The returned handle is valid only in the current R session.
#'
#' @param file Path to a Parquet file, or an `http://`, `https://`,
#'   `ftp://`, `ftps://` or `file://` URL. A URL is downloaded to the session
#'   temporary directory in full before any of it is read; the copy is removed
#'   by [close_parquet()], so a handle opened from a URL must be closed to
#'   reclaim the space. See [qio-limitations].
#' @param mmap Use memory-mapped input. On Windows a path the active code page
#'   cannot represent is read with buffered input instead, because only the
#'   mapped path needs a name that page can express. The result is the same.
#' @param verify_checksums Verify Parquet page checksums when present.
#' @param threads Number of reader threads, or `NULL` (the default) to pick the
#'   machine's core count. `0` means the same as `NULL`. [collect()] decodes
#'   columns in parallel either way: a mapped file shares one reader, and a
#'   buffered one gives each worker its own. Pass `threads = 1` to force serial
#'   reads.
#'
#' @return A `qio_parquet_file` object. Close it with [close_parquet()].
#'
#' @seealso [collect()] and [walk_batches()] to read from the handle,
#'   [close_parquet()] to release it, [schema()] and [metadata()] to inspect it
#'   without reading, and [read_parquet()] for a whole file in one call.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- open_parquet(path)
#' dim(pf)
#' close_parquet(pf)
open_parquet <- function(
  file,
  mmap = FALSE,
  verify_checksums = TRUE,
  threads = NULL
) {
  file <- qio_file_path(file)
  # A downloaded copy belongs to the handle from here on: it must outlive
  # open_parquet() and is removed by close_parquet(). If opening fails there is
  # no handle to own it, so it is removed on the way out instead.
  temporary <- if (isTRUE(attr(file, "qio_downloaded"))) as.character(file)
  opened <- FALSE
  on.exit(if (!opened && !is.null(temporary)) unlink(temporary), add = TRUE)
  attributes(file) <- NULL

  mmap <- qio_flag(mmap, "mmap")
  verify_checksums <- qio_flag(verify_checksums, "verify_checksums")
  threads <- qio_threads(threads)

  file <- .Call(
    C_qio_parquet_open,
    file,
    mmap,
    verify_checksums,
    threads
  )
  class(file) <- "qio_parquet_file"
  if (!is.null(temporary)) {
    attr(file, "qio_downloaded") <- temporary
  }
  opened <- TRUE
  file
}

#' Close a Parquet file
#'
#' Explicitly releases the native resources owned by an open Parquet handle.
#' Closing an already closed handle has no effect.
#'
#' @param x A `qio_parquet_file` object.
#'
#' @return `x`, invisibly.
#'
#' @seealso [open_parquet()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- open_parquet(path)
#' close_parquet(pf)
close_parquet <- function(x) {
  .Call(C_qio_parquet_close, x)
  # Only a copy qio downloaded is removed, and unlink() on an already-removed
  # file is a no-op, so closing twice stays harmless.
  temporary <- attr(x, "qio_downloaded")
  if (!is.null(temporary)) {
    unlink(temporary)
  }
  invisible(x)
}

#' Inspect a Parquet schema
#'
#' Reports every physical leaf column in the file, in file order.
#'
#' **`name` and `path` are not interchangeable.** `name` is the bare leaf name
#' and is not unique: two leaves under different parents may share one, and a
#' map's key/value leaves routinely do. `path` is the complete dotted path and
#' is what identifies a column everywhere else in qio -- [collect()],
#' [read_parquet()], [walk_batches()], and [bloom_filter_may_contain()] all
#' select by path, and [column_chunks()], [column_statistics()], and
#' [page_index()] report it under the same name.
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#'
#' @return A data frame with one row per physical leaf column and the columns:
#'   \describe{
#'     \item{`column`}{1-based physical column index.}
#'     \item{`name`}{Bare leaf name; not unique. See Details.}
#'     \item{`path`}{Complete dotted path; unique, and what selection uses.}
#'     \item{`physical_type`}{Parquet physical type.}
#'     \item{`logical_type`}{Logical annotation, or `NA` when absent.}
#'     \item{`logical_details`}{Annotation parameters, such as a timestamp unit
#'       or a decimal precision and scale; `NA` when there are none.}
#'     \item{`repetition_type`}{`"REQUIRED"`, `"OPTIONAL"`, or `"REPEATED"`.}
#'     \item{`type_length`}{Declared width of a `FIXED_LEN_BYTE_ARRAY`, else 0.}
#'     \item{`max_definition_level`}{Above 0 when the leaf is nullable.}
#'     \item{`max_repetition_level`}{Above 0 when the leaf is repeated.}
#'   }
#'
#' @seealso [read_plan()] for the R type each column will produce,
#'   [column_chunks()] for how each is stored, and [parquet_type_mapping()] for
#'   the physical fallbacks.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- open_parquet(path)
#' schema(pf)
#' close_parquet(pf)
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
#' @return A data frame with one row per row group and the columns:
#'   \describe{
#'     \item{`row_group`}{1-based row-group ID, which is what `row_groups =`
#'       selects on in [collect()], [read_parquet()], and [walk_batches()].}
#'     \item{`rows`}{Rows in the group.}
#'     \item{`compressed_bytes`, `uncompressed_bytes`}{Total size of the group's
#'       column chunks on disk and after decompression.}
#'   }
#'
#'   Counts and sizes are doubles rather than integers, because a row group can
#'   exceed `.Machine$integer.max`.
#' @seealso [column_chunks()] for the same sizes per column, and
#'   [column_statistics()] for what the writer claims about each chunk.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- open_parquet(path)
#' row_groups(pf)
#' close_parquet(pf)
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
#' pf <- open_parquet(path)
#' metadata(pf)
#' close_parquet(pf)
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
#' `collect()` returns the whole selection, so `batch_size` does not bound the
#' result; use [walk_batches()] for that. It does bound the scratch memory the
#' reader allocates while decoding string and binary columns, which would
#' otherwise scale with the largest selected row group rather than with
#' anything the caller controls. Smaller batches lower peak memory and cost a
#' little throughput on dictionary-encoded text.
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
#' @param batch_size Positive number of rows decoded at a time. It bounds the
#'   reader's scratch memory, not the size of the result (see Details);
#'   [walk_batches()] additionally uses it as the size of each batch.
#' @param int64 How 64-bit integer columns reach R. `"double"` (the default)
#'   is exact from `-2^53` through `2^53` and returns `NA` outside it.
#'   `"integer64"` returns [bit64::integer64], which needs the suggested
#'   `bit64` package and covers the signed 64-bit range **except its lowest
#'   value**: `bit64` reserves `-9223372036854775808` as its own `NA`, so a
#'   column storing `INT64_MIN` reads as `NA` in either mode. Either way values
#'   that cannot be represented become `NA`, and one warning naming the column
#'   is emitted for each column that lost values -- once per column, however
#'   many values, row groups, or batches were affected, and never for a column
#'   that lost nothing. Unsigned 64-bit columns are never returned as negative
#'   numbers.
#' @param time How `TIME` columns reach R: `"numeric"` (the default) returns
#'   seconds since midnight, `"hms"` returns [hms::hms] and needs the suggested
#'   `hms` package. Neither returns `POSIXct`, because a time of day is not an
#'   instant.
#' @param tz Time zone name, `"UTC"` by default. A UTC-adjusted `TIMESTAMP` is
#'   an instant, so `tz` changes only how it prints. A non-UTC `TIMESTAMP` is a
#'   wall clock with no zone stored, so its civil components are interpreted in
#'   `tz`; base R decides ambiguous and nonexistent times at daylight-saving
#'   boundaries. The machine's local zone is never used implicitly.
#' @param verbose Report what the read is about to do before doing it: the
#'   rows, columns, and row groups selected, the batch size, and the resolved
#'   [read_plan()] for the selected columns only -- not for the whole file, so
#'   it answers "what am I about to get". Written with `message()`, so it goes
#'   to stderr and `suppressMessages()` silences it.
#'
#' @return A data frame.
#'
#' @seealso [open_parquet()] for the handle and for `mmap` and `threads`,
#'   [walk_batches()] to process a file that does not fit in memory,
#'   [read_plan()] to preview the R type of every column, and [read_parquet()],
#'   which is [open_parquet()] plus `collect()` for a whole file.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- open_parquet(path)
#' collect(pf, columns = c("mpg", "cyl"))
#' close_parquet(pf)
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
  tz = "UTC",
  verbose = FALSE
) {
  qio_empty_dots(...)
  verbose <- qio_flag(verbose, "verbose")
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
  if (verbose) {
    qio_message_plan(x, plan, columns, row_groups, batch_size)
  }
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
#' @param ... Passed on to `FUN` after the batch and its index. This differs
#'   from [collect()], where `...` must be empty: here it is how a callback
#'   receives extra arguments. Every argument after it is still name-only.
#' @param batch_size Positive number of rows decoded per batch.
#'
#' @return `x`, invisibly.
#'
#' @seealso [collect()] for the same selection returned as one data frame, and
#'   [open_parquet()] for the handle.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' pf <- open_parquet(path)
#' walk_batches(pf, function(batch, index) print(head(batch)))
#' close_parquet(pf)
walk_batches <- function(
  x,
  FUN,
  ...,
  columns = NULL,
  row_groups = NULL,
  batch_size = 65536L,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC",
  verbose = FALSE
) {
  if (!is.function(FUN)) {
    stop("`FUN` must be a function.", call. = FALSE)
  }
  verbose <- qio_flag(verbose, "verbose")
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
  if (verbose) {
    qio_message_plan(x, plan, columns, row_groups, batch_size)
  }
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

# Schemes qio will fetch. Anything else -- including a bare "example.com/x" or
# a Windows drive letter such as "C:/data.parquet" -- is a local path, which is
# why this matches a scheme followed by "://" rather than looking for a colon.
qio_url_schemes <- "^(https?|ftps?|file)://"

qio_is_url <- function(x) {
  grepl(qio_url_schemes, x, ignore.case = TRUE)
}

# Fetch a remote file into the session temp directory and return its path.
#
# The whole file is downloaded before any of it is read. That is not a
# shortcut that a later version optimizes away column by column: carquet reads
# from a path, a FILE* or a buffer, and exposes no way to supply read and seek
# callbacks, so there is no seam through which HTTP range requests could reach
# it. Reading only the footer and the selected column chunks needs a custom IO
# interface added to carquet itself; see `.agents/roadmap.md`.
qio_download <- function(url) {
  destination <- tempfile(fileext = ".parquet")
  complete <- FALSE
  on.exit(if (!complete) unlink(destination), add = TRUE)

  message(
    "Downloading '",
    url,
    "'; qio reads Parquet from local files, so the whole file is fetched ",
    "before any of it is read."
  )

  status <- tryCatch(
    utils::download.file(url, destination, mode = "wb", quiet = TRUE),
    error = function(e) {
      stop(
        "Could not download '",
        url,
        "': ",
        conditionMessage(e),
        call. = FALSE
      )
    }
  )
  if (!identical(as.integer(status), 0L)) {
    stop(
      "Could not download '",
      url,
      "': download.file() reported status ",
      status,
      ".",
      call. = FALSE
    )
  }
  if (!file.exists(destination)) {
    stop(
      "Could not download '",
      url,
      "': no file was written.",
      call. = FALSE
    )
  }

  complete <- TRUE
  destination
}

# Resolve a user-supplied location to a readable local path. A URL is fetched
# first and the result carries `qio_downloaded`, which tells the caller it owns
# a temporary copy and must remove it. A local path is returned unchanged and
# carries no attribute, so nothing qio did not create is ever unlinked.
qio_file_path <- function(file) {
  if (!is.character(file) || length(file) != 1L || is.na(file)) {
    stop("`file` must be a single file path or URL.", call. = FALSE)
  }
  if (qio_is_url(file)) {
    downloaded <- qio_download(file)
    attr(downloaded, "qio_downloaded") <- TRUE
    return(downloaded)
  }
  file <- path.expand(file)
  if (!file.exists(file)) {
    stop("File does not exist: ", file, call. = FALSE)
  }
  file
}

# `NULL` and `0` both mean "pick the machine's core count". The native layer
# spells that as 0, so the R default is `NULL` -- which is what every other
# automatic argument here uses -- and is normalized to 0 on the way through.
qio_threads <- function(threads) {
  if (is.null(threads)) {
    return(0L)
  }
  qio_whole_number(threads, "threads", minimum = 0L)
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
  # FLOAT16 is decoded as raw bytes and converted by the plan.
  kind[converter %in% c("binary", "float16")] <- 3L # BINARY
  # UUID text is formatted in C, where the bytes already are.
  kind[converter == "uuid"] <- 5L # UUID
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

# Report what a read is about to do: how much of the file it touches, and the
# resolved plan for the columns actually selected rather than for the whole
# file. Called after selection and validation so every number shown is the one
# the read will use.
#
# Routed through message() like the package's other read diagnostics, so it
# goes to stderr, is silenced by suppressMessages(), and never contaminates a
# result being piped or captured.
qio_message_plan <- function(x, plan, columns, groups, batch_size) {
  all_groups <- row_groups(x)
  chosen <- if (is.null(groups)) seq_len(nrow(all_groups)) else groups
  selected <- if (is.null(columns)) seq_len(nrow(plan)) else columns

  count <- function(n, singular) {
    paste0(
      format(n, big.mark = ",", scientific = FALSE),
      " ",
      singular,
      if (n == 1L) {
        ""
      } else {
        "s"
      }
    )
  }
  part <- function(n, total, singular) {
    if (n == total) {
      count(n, singular)
    } else {
      paste0(
        format(n, big.mark = ",", scientific = FALSE),
        " of ",
        count(
          total,
          singular
        )
      )
    }
  }

  header <- paste0(
    "Reading ",
    .Call(C_qio_parquet_path, x),
    "\n  ",
    count(sum(all_groups$rows[chosen]), "row"),
    ", ",
    part(length(selected), nrow(plan), "column"),
    ", ",
    part(length(chosen), nrow(all_groups), "row group"),
    "\n  batch size ",
    format(batch_size, big.mark = ",", scientific = FALSE)
  )

  body <- plan[
    selected,
    c("name", "physical_type", "logical_type", "r_type", "converter"),
    drop = FALSE
  ]
  # A note explains a fallback type, so it is only worth showing when one
  # of the selected columns actually carries one.
  if (any(!is.na(plan$note[selected]))) {
    body$note <- plan$note[selected]
  }
  # One message, not two: expect_message() and any handler that stops after the
  # first condition would otherwise let the table escape the header.
  message(paste(c(header, qio_format_table(body)), collapse = "\n"))
  invisible(NULL)
}

# Render a small data frame as aligned text, for message(). print() writes to
# stdout and capture.output() lives in utils, which the package does not
# import -- but neither is needed: format() pads a character vector to one
# common width, so passing each column together with its own header aligns the
# whole table in a single pass.
qio_format_table <- function(df) {
  columns <- lapply(names(df), function(name) {
    values <- as.character(df[[name]])
    values[is.na(values)] <- "-"
    format(c(name, values))
  })
  sub("\\s+$", "", paste0("  ", do.call(paste, c(columns, sep = "  "))))
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

#' Inspect Parquet column chunks
#'
#' Reports how each column is stored in each row group: its physical type,
#' compression, sizes, encodings, and which optional structures are present.
#' One row per column per row group.
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#'
#' @return A data frame with one row per column chunk, ordered by row group and
#'   then by column, with the columns:
#'   \describe{
#'     \item{`row_group`}{1-based row-group ID, as [row_groups()] reports it.}
#'     \item{`column`}{1-based physical column index, as [schema()] reports it.}
#'     \item{`path`}{Complete dotted column path; see [schema()] for why this is
#'       the identifier rather than the bare leaf name.}
#'     \item{`physical_type`}{Parquet physical type of the leaf.}
#'     \item{`compression`}{Codec name, such as `"SNAPPY"` or `"UNCOMPRESSED"`.
#'       Set per chunk, so one file may mix codecs.}
#'     \item{`num_values`}{Values stored in the chunk, nulls included.}
#'     \item{`compressed_bytes`, `uncompressed_bytes`}{Size of the chunk on disk
#'       and after decompression. Equal for an uncompressed chunk.}
#'     \item{`encodings`}{Encodings the chunk declares, comma separated. A
#'       dictionary-encoded chunk typically lists `RLE_DICTIONARY` alongside the
#'       `PLAIN` its dictionary page uses.}
#'     \item{`dictionary_page`}{Whether the chunk has a dictionary page.}
#'     \item{`bloom_filter`}{Whether a bloom filter is present, which is what
#'       [bloom_filter_may_contain()] needs.}
#'     \item{`page_index`}{Whether a column index or an offset index is present;
#'       [page_index()] reports either.}
#'   }
#'
#'   Sizes and counts are doubles rather than integers, because a chunk can
#'   exceed `.Machine$integer.max`.
#' @seealso [column_statistics()], [row_groups()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path, row_group_size = 16)
#' pf <- open_parquet(path)
#' column_chunks(pf)
#' close_parquet(pf)
column_chunks <- function(x, ...) {
  UseMethod("column_chunks")
}

#' @rdname column_chunks
#' @export
column_chunks.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  .Call(C_qio_parquet_column_chunks, x)
}

#' Inspect Parquet column statistics
#'
#' Reports the per-column, per-row-group statistics recorded in the file: value
#' and null counts, and the minimum and maximum bounds.
#'
#' These are **claims made by whoever wrote the file**, not facts qio verifies.
#' A reader that skips a row group on them is trusting that writer. qio does not
#' use them to skip anything.
#'
#' `min` and `max` are list columns, because one file can hold columns of
#' different types. Each element holds the bound decoded at the *physical*
#' level: an `INT64` bound stays a number rather than becoming a `POSIXct`, and
#' a decimal is not scaled, since a bound is a sort key rather than a value to
#' compute with. Text columns are the exception and decode to character. An
#' element is `NULL` when the bound is absent, or is present but the wrong width
#' for its type.
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#'
#' @return A data frame with one row per column chunk, ordered by row group and
#'   then by column, with the columns:
#'   \describe{
#'     \item{`row_group`}{1-based row-group ID, as [row_groups()] reports it.}
#'     \item{`column`}{1-based physical column index, as [schema()] reports it.}
#'     \item{`path`}{Complete dotted column path; see [schema()].}
#'     \item{`num_values`}{Values the statistics cover, nulls included.}
#'     \item{`null_count`}{Nulls the writer recorded, or `NA` when it recorded
#'       none. `NA` means unknown, not zero.}
#'     \item{`distinct_count`}{Distinct values the writer recorded, or `NA`.
#'       Most writers omit it, so `NA` is the common case.}
#'     \item{`min`, `max`}{List columns of physical-level bounds, one element
#'       per row; `NULL` when absent or undecodable. See Details.}
#'   }
#'
#'   Counts are doubles rather than integers, because a chunk can hold more
#'   values than `.Machine$integer.max`.
#' @seealso [column_chunks()], [row_groups()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(data.frame(n = 1:100), path, row_group_size = 25)
#' pf <- open_parquet(path)
#' stats <- column_statistics(pf)
#' stats[c("row_group", "path", "null_count")]
#' unlist(stats$min)
#' close_parquet(pf)
column_statistics <- function(x, ...) {
  UseMethod("column_statistics")
}

#' @rdname column_statistics
#' @export
column_statistics.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  .Call(C_qio_parquet_column_statistics, x)
}

#' Inspect Parquet page indexes
#'
#' Reports the per-page index of each column chunk: where each data page sits
#' in the file, which row it starts at, and the bounds and null count it
#' declares. One row per page.
#'
#' A page index is optional, and many writers omit it. Columns without one
#' contribute no rows, so a file with no page index at all returns a
#' zero-row data frame rather than an error. qio's own writer does not emit
#' page indexes; see [qio-limitations].
#'
#' Like [column_statistics()], the bounds are claims made by whoever wrote the
#' file. qio reports them and does not use them to skip pages.
#'
#' @param x A `qio_parquet_file` object.
#' @param ... Reserved for future use.
#'
#' @return A data frame with one row per page, ordered by row group, then
#'   column, then page, with the columns:
#'   \describe{
#'     \item{`row_group`}{1-based row-group ID, as [row_groups()] reports it.}
#'     \item{`column`}{1-based physical column index, as [schema()] reports it.}
#'     \item{`path`}{Complete dotted column path; see [schema()].}
#'     \item{`page`}{1-based page number within this column chunk, restarting at
#'       1 for every chunk.}
#'     \item{`first_row`}{0-based row within the row group where the page
#'       starts. The first page of a chunk is 0.}
#'     \item{`offset`}{Byte offset of the page from the start of the file.}
#'     \item{`compressed_bytes`}{Size of the page on disk.}
#'     \item{`null_count`}{Nulls on the page, or `NA` when not recorded.}
#'     \item{`null_page`}{Whether the page holds only nulls, in which case its
#'       bounds carry no information.}
#'     \item{`min`, `max`}{List columns of physical-level bounds, decoded as in
#'       [column_statistics()]; `NULL` when absent.}
#'   }
#'
#'   The two indexes are independent and either may be missing. `first_row`,
#'   `offset`, and `compressed_bytes` come from the offset index and are `NA`
#'   without it; `null_count`, `null_page`, `min`, and `max` come from the
#'   column index and are `NA` or `NULL` without it.
#' @seealso [column_statistics()], [column_chunks()]
#' @export
#' @examples
#' # qio does not write page indexes, so a file it wrote has none and the
#' # result is empty rather than an error.
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(data.frame(n = 1:10), path)
#' pf <- open_parquet(path)
#' nrow(page_index(pf))
#' close_parquet(pf)
page_index <- function(x, ...) {
  UseMethod("page_index")
}

#' @rdname page_index
#' @export
page_index.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  .Call(C_qio_parquet_page_index, x)
}

#' Test values against a Parquet bloom filter
#'
#' A bloom filter answers one question: is this value *definitely absent* from
#' the column chunk? It never proves presence. `FALSE` means the value is not
#' there; `TRUE` means it may be, and only reading can settle it.
#'
#' Values are matched against the column's physical type, because that is what
#' the writer hashed. A value qio cannot reduce to that type is an error rather
#' than a `FALSE`, which would read as "definitely absent".
#'
#' qio's own writer does not emit bloom filters; see [qio-limitations]. Use
#' [column_chunks()] to find out whether a chunk has one.
#'
#' @param x A `qio_parquet_file` object.
#' @param column A single complete column path, as [schema()] reports it in
#'   `path` and [names()] returns it -- not the bare `name`, which is not
#'   unique across a nested file.
#' @param values Values to test. Numeric for numeric columns, character for
#'   byte-array columns. `NA` returns `NA`.
#' @param row_group Row group to test, 1-based. A bloom filter belongs to one
#'   column chunk, so it covers one row group.
#' @param ... Reserved for future use.
#'
#' @return A logical vector the length of `values`: `FALSE` where the value is
#'   definitely absent, `TRUE` where it may be present.
#' @seealso [column_chunks()]
#' @export
#' @examples
#' # qio's writer emits no bloom filters, so this uses a bundled file written
#' # by pyarrow. Its `key` column runs 0..3999 across four row groups.
#' path <- system.file("extdata", "bloom_sorted.parquet", package = "qio")
#' pf <- open_parquet(path)
#'
#' # Row group 1 holds keys 0..999. A present value may be present; absent
#' # values are ruled out, and never wrongly, because there are no false
#' # negatives.
#' bloom_filter_may_contain(pf, "key", c(42, 123456))
#'
#' # Which chunks even have a filter to test.
#' chunks <- column_chunks(pf)
#' chunks[chunks$row_group == 1, c("path", "bloom_filter")]
#'
#' close_parquet(pf)
bloom_filter_may_contain <- function(x, column, values, row_group = 1L, ...) {
  UseMethod("bloom_filter_may_contain")
}

#' @rdname bloom_filter_may_contain
#' @export
bloom_filter_may_contain.qio_parquet_file <- function(
  x,
  column,
  values,
  row_group = 1L,
  ...
) {
  qio_empty_dots(...)
  if (!is.character(column) || length(column) != 1L || is.na(column)) {
    stop("`column` must be a single column name.", call. = FALSE)
  }
  index <- match(column, names(x))
  if (is.na(index)) {
    stop("Unknown column: ", column, call. = FALSE)
  }
  row_group <- qio_whole_number(row_group, "row_group", minimum = 1L)
  .Call(C_qio_parquet_bloom_check, x, index, values, row_group)
}

# Which read path the last operation took for each text column chunk, and a
# reset. Internal and undocumented: this exists so tests can tell the paths
# apart, because all three return identical data and a regression to the
# slowest one would otherwise be invisible. See src/qio_file.c.
qio_read_path_counters <- function() {
  .Call(C_qio_read_path_counters)
}
