#' Read a Parquet file
#'
#' Reads an Apache Parquet file into a data frame.
#'
#' Column types are mapped from Parquet as follows: `BOOLEAN` to logical,
#' `INT32` to integer, `INT64`/`FLOAT`/`DOUBLE` to double, and `BYTE_ARRAY`
#' (assumed UTF-8) to character. An `INT32` column annotated `DATE` is returned
#' as a `Date`, a UTC-adjusted `TIMESTAMP` (physical `INT64`) as a `POSIXct` in
#' UTC, and a legacy `INT96` timestamp as a `POSIXct` in UTC (interpreting its
#' Julian-day and nanosecond-of-day parts as an instant). Parquet nulls become
#' `NA`. `INT64` values are returned as doubles and lose precision beyond 2^53,
#' which for microsecond and nanosecond timestamps can drop sub-second precision
#' far from the epoch. Use [read_plan()] to preview the R type of each column
#' before reading.
#'
#' Nested and repeated columns are skipped with one message. Nested reading is
#' deferred to qio 0.2.0.
#'
#' The file is memory-mapped for the duration of the read (falling back to
#' buffered reads if mapping fails) so columns decode in parallel; the mapping
#' is released before the function returns.
#'
#' `columns` and `row_groups` read part of a file and are passed straight to
#' [collect()]. Selecting columns is the single largest speedup available on a
#' wide file, because a column that is not selected is never decompressed.
#' Use [open_parquet()] with [collect()] for the rest: `batch_size`, `mmap`,
#' `threads`, and `verify_checksums`.
#'
#' @param file Path to a Parquet file.
#' @param columns Character vector of complete column paths, or `NULL` (the
#'   default) for all columns; see [collect()].
#' @param row_groups Integer vector of 1-based row-group IDs, or `NULL` (the
#'   default) for all row groups.
#' @param int64 How 64-bit integer columns reach R; see [collect()].
#' @param time How `TIME` columns reach R; see [collect()].
#' @param tz Time zone for `TIMESTAMP` columns; see [collect()].
#'
#' @return A data frame.
#'
#' @seealso [write_parquet()], [open_parquet()] and [collect()] to read part of
#'   a file, [walk_batches()] for a file larger than memory, and [read_plan()]
#'   to preview the R type of every column before reading.
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(data.frame(x = 1:3, y = c("a", "b", NA)), path)
#' read_parquet(path)
read_parquet <- function(
  file,
  columns = NULL,
  row_groups = NULL,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC"
) {
  # mmap enables parallel column decode in collect(); the handle is closed on
  # exit, so the mapping (and any Windows delete-lock) lives only for the read.
  file <- open_parquet(file, mmap = TRUE)
  on.exit(close_parquet(file), add = TRUE)
  collect(
    file,
    columns = columns,
    row_groups = row_groups,
    int64 = int64,
    time = time,
    tz = tz
  )
}

#' Write a Parquet file
#'
#' Writes a data frame to an Apache Parquet file.
#'
#' Supported column types are logical, integer, double, character, and factor
#' (written as character). A column is written as nullable when it contains any
#' `NA`. `Date` columns are written as `INT32` with a `DATE` annotation, and
#' `POSIXct` columns as `INT64` microseconds with a UTC-adjusted `TIMESTAMP`
#' annotation; both round-trip back to their R class. Sub-microsecond fractions
#' of a second are rounded. Other classed columns are still written using their
#' underlying storage type and lose their class. An explicit [parquet_schema()]
#' may instead select `INT64`, `FLOAT`, or a different timestamp unit, among the
#' supported declarations.
#'
#' `append` adds row groups to a file that already exists, rather than replacing
#' it. Because it writes into data the user already has, qio checks
#' compatibility itself and refuses anything it cannot prove safe. The bundled
#' library compares column count, order, names, physical types, repetition, and
#' logical type *identity* -- but not logical *parameters*, so it would happily
#' append microsecond timestamps to a millisecond file, or a decimal of one
#' scale to another. qio compares the full declaration, including those
#' parameters, and the schema path of every column.
#'
#' Nullability is taken from the existing file rather than inferred from the new
#' data, so appending a batch that happens to contain no `NA` to a nullable
#' column works. Appending data that does contain `NA` to a column the file
#' declares `REQUIRED` is refused.
#'
#' Row groups are the unit other readers skip on: a reader that can rule a group
#' out from its statistics never touches its pages. `row_group_size` sets how
#' many rows go in each. The default writes one row group, which keeps files
#' compact but leaves nothing to skip, so a file meant to be filtered by other
#' tools should set it.
#'
#' `metadata` writes application key/value pairs into the footer, where
#' [metadata()] reads them back. Keys and values are stored as UTF-8 text;
#' Parquet defines no meaning for them.
#'
#' @param x A data frame (or a list of equal-length atomic vectors).
#' @param file Output path.
#' @param compression Compression codec: one of `"snappy"` (default), `"zstd"`,
#'   `"gzip"`, `"lz4"`, or `"uncompressed"`.
#' @param schema An optional schema created by [parquet_schema()]. Named entries
#'   override qio's inferred mapping; omitted columns retain automatic mapping.
#' @param row_group_size Rows per row group, or `NULL` (default) to write a
#'   single row group. Smaller groups let other readers skip more but add
#'   per-group metadata and can compress worse.
#' @param metadata A named character vector of footer key/value metadata, or
#'   `NULL`. Duplicate keys are written in the order given. An `NA` value is
#'   written as a key with no value, and reads back as `NA`.
#' @param sorted_by Columns the data is already sorted by, or `NULL`. Either a
#'   character vector of column names, meaning ascending with nulls last, or a
#'   data frame with a `name` column and optional logical `descending` and
#'   `nulls_first` columns. This **records a claim and nothing more**: qio does
#'   not sort the data and does not check that the claim is true. A wrong
#'   declaration misleads every reader that trusts it.
#' @param append Append new row groups to an existing file instead of replacing
#'   it. The file must already exist and describe exactly the columns being
#'   written; see Details.
#'
#' @return The output path, invisibly.
#'
#' @seealso [read_parquet()], [metadata()], [row_groups()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#'
#' # Several row groups, with provenance in the footer.
#' write_parquet(
#'   mtcars,
#'   path,
#'   row_group_size = 8,
#'   metadata = c(source = "mtcars", written_by = "qio")
#' )
write_parquet <- function(
  x,
  file,
  compression = c("snappy", "zstd", "gzip", "lz4", "uncompressed"),
  schema = NULL,
  row_group_size = NULL,
  metadata = NULL,
  sorted_by = NULL,
  append = FALSE
) {
  x <- qio_as_data_frame(x)
  if (!is.character(file) || length(file) != 1L || is.na(file)) {
    stop("`file` must be a single file path.", call. = FALSE)
  }
  compression <- match.arg(compression)
  file <- path.expand(file)
  row_group_size <- qio_row_group_size(row_group_size)
  metadata <- qio_write_metadata(metadata)
  append <- qio_flag(append, "append")
  prepared <- qio_resolve_write_schema(x, schema)
  if (append) {
    prepared <- qio_prepare_append(file, prepared)
  }
  sorted_by <- qio_sorted_by(sorted_by, names(prepared$x))
  .Call(
    C_qio_write_parquet,
    prepared$x,
    file,
    compression,
    prepared$native,
    row_group_size,
    metadata,
    sorted_by,
    append
  )
  invisible(file)
}

# Rows per row group. Kept as a double so a count above INT_MAX is rejected by
# the row limit rather than silently wrapping here.
qio_row_group_size <- function(row_group_size) {
  if (is.null(row_group_size)) {
    return(NULL)
  }
  if (
    !is.numeric(row_group_size) ||
      length(row_group_size) != 1L ||
      is.na(row_group_size) ||
      !is.finite(row_group_size) ||
      row_group_size < 1
  ) {
    stop(
      "`row_group_size` must be a single positive number, or NULL.",
      call. = FALSE
    )
  }
  as.double(floor(row_group_size))
}

# Split a named character vector into the parallel key/value pair the native
# writer takes. Names are required: an unnamed value has no key to store under.
qio_write_metadata <- function(metadata) {
  if (is.null(metadata)) {
    return(NULL)
  }
  # `c(key = NA)` is a logical vector, which is how anyone would write a key
  # with no value; a mixed `c(a = "x", b = NA)` is already character.
  if (is.logical(metadata) && all(is.na(metadata))) {
    # as.character() drops names, so carry them across explicitly.
    keys <- names(metadata)
    metadata <- as.character(metadata)
    names(metadata) <- keys
  }
  if (!is.character(metadata) || is.null(names(metadata))) {
    stop("`metadata` must be a named character vector, or NULL.", call. = FALSE)
  }
  keys <- names(metadata)
  if (anyNA(keys) || any(!nzchar(keys))) {
    stop("`metadata` names must be non-empty and not NA.", call. = FALSE)
  }
  list(keys, unname(metadata))
}

# Validate that new data can be appended to an existing file, and adopt that
# file's nullability.
#
# This exists because the bundled library's own compatibility check is not
# sufficient: it compares logical type IDs without comparing their parameters,
# so a MICROS-versus-MILLIS timestamp mismatch passes it and silently writes
# wrong values into a file that was correct. Everything here is about refusing
# before a single byte is written.
qio_prepare_append <- function(file, prepared) {
  if (!file.exists(file)) {
    stop(
      "`append = TRUE` but the file does not exist: ",
      file,
      call. = FALSE
    )
  }
  handle <- open_parquet(file)
  on.exit(close_parquet(handle), add = TRUE)
  existing <- schema(handle)
  intended <- prepared$schema

  # qio writes flat schemas, so it can only append to one.
  if (any(existing$path != existing$name)) {
    stop(
      "Cannot append to a file with nested columns.",
      call. = FALSE
    )
  }
  if (nrow(existing) != nrow(intended)) {
    stop(
      "Cannot append: the file has ",
      nrow(existing),
      " columns but ",
      nrow(intended),
      " are being written.",
      call. = FALSE
    )
  }
  if (!identical(existing$name, intended$name)) {
    stop(
      "Cannot append: column names differ, or are in a different order.\n",
      "  file:    ",
      paste(existing$name, collapse = ", "),
      "\n  writing: ",
      paste(intended$name, collapse = ", "),
      call. = FALSE
    )
  }

  # The comparison the bundled library does not make. `logical_details` carries
  # the timestamp unit and UTC adjustment, decimal precision and scale, and
  # integer width and signedness, which is exactly what it ignores.
  for (field in c("physical_type", "logical_type", "logical_details")) {
    same <- identical(existing[[field]], intended[[field]]) |
      (is.na(existing[[field]]) & is.na(intended[[field]]))
    differs <- which(
      !(existing[[field]] == intended[[field]]) %in% TRUE &
        !(is.na(existing[[field]]) & is.na(intended[[field]]))
    )
    if (length(differs) > 0L) {
      first <- differs[1L]
      stop(
        "Cannot append: column `",
        existing$name[first],
        "` is ",
        field,
        " ",
        format(existing[[field]][first]),
        " in the file but ",
        format(intended[[field]][first]),
        " in the data being written.",
        call. = FALSE
      )
    }
  }

  # Nullability comes from the file: a batch with no NA in it must still be
  # written as OPTIONAL if that is how the column was declared, or the row
  # groups would disagree with the footer.
  required <- existing$repetition == "REQUIRED"
  writing_nulls <- intended$repetition_type == "OPTIONAL"
  bad <- which(required & writing_nulls)
  if (length(bad) > 0L) {
    stop(
      "Cannot append: column `",
      intended$name[bad[1L]],
      "` contains missing values but the file declares it REQUIRED.",
      call. = FALSE
    )
  }
  prepared$native$nullable <- !required
  prepared$schema$repetition_type <- existing$repetition
  prepared
}

# Resolve a sort declaration to the parallel vectors the native writer takes.
# Column positions are 0-based there and resolved from names here, so a typo is
# an error rather than a declaration about the wrong column.
qio_sorted_by <- function(sorted_by, columns) {
  if (is.null(sorted_by)) {
    return(NULL)
  }
  if (is.character(sorted_by)) {
    sorted_by <- data.frame(name = sorted_by, stringsAsFactors = FALSE)
  }
  if (!is.data.frame(sorted_by) || is.null(sorted_by$name)) {
    stop(
      "`sorted_by` must be a character vector or a data frame with a `name` ",
      "column, or NULL.",
      call. = FALSE
    )
  }
  if (nrow(sorted_by) == 0L) {
    return(NULL)
  }

  descending <- sorted_by$descending %||% rep(FALSE, nrow(sorted_by))
  nulls_first <- sorted_by$nulls_first %||% rep(FALSE, nrow(sorted_by))
  if (!is.logical(descending) || !is.logical(nulls_first)) {
    stop("`descending` and `nulls_first` must be logical.", call. = FALSE)
  }
  if (anyNA(descending) || anyNA(nulls_first)) {
    stop("`descending` and `nulls_first` must not be NA.", call. = FALSE)
  }

  index <- match(sorted_by$name, columns)
  if (anyNA(index)) {
    stop(
      "`sorted_by` names a column that is not being written: ",
      paste(sorted_by$name[is.na(index)], collapse = ", "),
      call. = FALSE
    )
  }
  if (anyDuplicated(index)) {
    stop("`sorted_by` names the same column more than once.", call. = FALSE)
  }

  list(
    as.integer(index - 1L),
    as.logical(rep_len(descending, nrow(sorted_by))),
    as.logical(rep_len(nulls_first, nrow(sorted_by)))
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Check that a file is structurally valid Parquet
#'
#' Reports why a file cannot be read, in terms of the file rather than of the
#' parser. Opening a damaged or misidentified file otherwise fails somewhere
#' inside footer parsing, with a message that describes a byte offset instead of
#' the problem.
#'
#' What is checked: the file exists and is large enough to be Parquet, both
#' magic markers are present, the footer parses, and the schema and row-group
#' metadata agree with the file's own row count.
#'
#' What is **not** checked: the data pages. Structural validity says a reader can
#' find the columns, not that their bytes decode or that the recorded statistics
#' are true. To check the pages, read the file with
#' `open_parquet(verify_checksums = TRUE)` and [collect()]; that costs a full
#' read, which is why it is not done here.
#'
#' @param file Path to a file.
#'
#' @return `TRUE`, invisibly. Raises an error describing the first problem
#'   found otherwise.
#' @seealso [open_parquet()], [column_chunks()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(mtcars, path)
#' validate_parquet(path)
#'
#' # A file that is not Parquet at all.
#' plain <- tempfile()
#' writeLines("not parquet", plain)
#' try(validate_parquet(plain))
validate_parquet <- function(file) {
  # qio_file_path() already rejects a non-path and a file that does not exist.
  file <- qio_file_path(file)

  if (dir.exists(file)) {
    stop("`file` is a directory, not a Parquet file: ", file, call. = FALSE)
  }

  size <- file.size(file)
  # 4 leading magic + 4 footer length + 4 trailing magic is the shortest a
  # Parquet file can be even before the footer itself.
  if (is.na(size) || size < 12) {
    stop(
      "`file` is too small to be a Parquet file: ",
      if (is.na(size)) "unknown size" else paste0(size, " bytes"),
      call. = FALSE
    )
  }

  connection <- file(file, "rb")
  on.exit(close(connection), add = TRUE)
  head <- readBin(connection, "raw", 4L)
  seek(connection, where = size - 4, origin = "start")
  tail <- readBin(connection, "raw", 4L)

  par1 <- charToRaw("PAR1")
  pare <- charToRaw("PARE")
  if (identical(head, pare) || identical(tail, pare)) {
    stop(
      "`file` has an encrypted footer, which qio cannot read.",
      call. = FALSE
    )
  }
  if (!identical(head, par1)) {
    stop(
      "`file` does not start with the Parquet marker 'PAR1', so it is not a ",
      "Parquet file.",
      call. = FALSE
    )
  }
  if (!identical(tail, par1)) {
    stop(
      "`file` does not end with the Parquet marker 'PAR1'. It is truncated, ",
      "or was still being written.",
      call. = FALSE
    )
  }

  handle <- tryCatch(
    open_parquet(file),
    error = function(e) {
      stop(
        "`file` has both Parquet markers but its footer does not parse: ",
        conditionMessage(e),
        call. = FALSE
      )
    }
  )
  on.exit(close_parquet(handle), add = TRUE)

  # The footer states a row count and also describes row groups. A file whose
  # groups do not add up is readable but not trustworthy, and nothing else
  # reports it.
  groups <- row_groups(handle)
  declared <- dim(handle)[1]
  if (nrow(groups) > 0 && sum(groups$rows) != declared) {
    stop(
      "`file` declares ",
      declared,
      " rows but its row groups hold ",
      sum(groups$rows),
      ".",
      call. = FALSE
    )
  }

  columns <- dim(handle)[2]
  if (nrow(schema(handle)) != columns) {
    stop(
      "`file` declares ",
      columns,
      " columns but its schema describes ",
      nrow(schema(handle)),
      ".",
      call. = FALSE
    )
  }

  invisible(TRUE)
}
