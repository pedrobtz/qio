# Authoritative Parquet physical-type registry.
#
# One row per Parquet physical type. `r_type` and `converter` describe how the
# reader materializes a column; `written_from` records which R type the writer
# encodes into that physical type. This is the single source of truth for the
# scalar mappings: both `read_plan()` and `parquet_type_mapping()` derive from
# it so they cannot drift. Rows are kept in canonical Parquet type order.
#
# Logical annotations (DATE, TIMESTAMP, ...) are resolved separately by
# `qio_resolve_logical()`, which overrides these fallbacks when an annotation is
# present. INT96 is the exception handled here: it is a deprecated physical type
# whose only use is timestamps, so it maps to POSIXct directly (decoded in C).
qio_type_registry <- function() {
  data.frame(
    physical_type = c(
      "BOOLEAN",
      "INT32",
      "INT64",
      "INT96",
      "FLOAT",
      "DOUBLE",
      "BYTE_ARRAY",
      "FIXED_LEN_BYTE_ARRAY"
    ),
    r_type = c(
      "logical",
      "integer",
      "double",
      "POSIXct",
      "double",
      "double",
      "character",
      NA
    ),
    converter = c(
      "boolean",
      "int32",
      "int64",
      "int96",
      "float",
      "double",
      "byte_array",
      NA
    ),
    written_from = c(
      "logical",
      "integer",
      NA,
      NA,
      NA,
      "double",
      "character or factor",
      NA
    ),
    stringsAsFactors = FALSE
  )
}

# Logical-annotation overrides, keyed by (physical_type, logical_type).
#
# A matching row takes precedence over the physical fallback in
# `qio_type_registry()`: the reader applies `converter` to turn the physical
# vector into `r_type`, and the writer encodes `written_from` into that
# (physical_type, logical_type) pair. Rows added here are automatically
# reflected by `read_plan()`; the converter must be handled in
# `qio_apply_converter()`.
qio_logical_registry <- function() {
  data.frame(
    logical_type = "DATE",
    physical_type = "INT32",
    r_type = "Date",
    converter = "date32",
    written_from = "Date",
    stringsAsFactors = FALSE
  )
}

# Resolve logical-annotation conversions for each schema row. Returns per-row
# `r_type`, `converter`, and an `applied` flag. Rows left `NA`/`FALSE` keep the
# physical fallback and are reported by `read_plan()` as a pending annotation.
qio_resolve_logical <- function(schema) {
  n <- nrow(schema)
  r_type <- rep(NA_character_, n)
  converter <- rep(NA_character_, n)

  # Static (physical_type, logical_type) overrides, e.g. DATE.
  reg <- qio_logical_registry()
  idx <- match(
    paste(schema$physical_type, schema$logical_type),
    paste(reg$physical_type, reg$logical_type)
  )
  hit <- !is.na(idx)
  r_type[hit] <- reg$r_type[idx[hit]]
  converter[hit] <- reg$converter[idx[hit]]

  # Parameterized: a UTC-adjusted INT64 TIMESTAMP becomes POSIXct, with the unit
  # selecting the rescaling converter. A non-UTC timestamp is a local civil
  # time, not an instant, so it is left unapplied.
  is_ts <- !hit &
    !is.na(schema$logical_type) &
    schema$logical_type == "TIMESTAMP" &
    schema$physical_type == "INT64"
  if (any(is_ts)) {
    time <- qio_parse_time_details(schema$logical_details[is_ts])
    ok <- time$adjusted_to_utc & time$unit %in% c("MILLIS", "MICROS", "NANOS")
    rows <- which(is_ts)[ok]
    r_type[rows] <- "POSIXct"
    converter[rows] <- paste0("timestamp_utc_", tolower(time$unit[ok]))
  }

  list(r_type = r_type, converter = converter, applied = !is.na(r_type))
}

# Parse a TIMESTAMP/TIME `logical_details` string of the form
# "unit=MICROS, adjusted_to_utc=true" into its components. `unit` is NA when the
# string carries no unit.
qio_parse_time_details <- function(details) {
  details[is.na(details)] <- ""
  unit <- sub("^.*unit=([A-Za-z]+).*$", "\\1", details)
  unit[!grepl("unit=", details, fixed = TRUE)] <- NA_character_
  list(
    unit = unit,
    adjusted_to_utc = grepl("adjusted_to_utc=true", details, fixed = TRUE)
  )
}

#' Plan how a Parquet file is read into R
#'
#' Builds a read plan from a Parquet schema: one row per physical leaf column
#' describing the R type each column will materialize as, whether it can be
#' collected, and why not when it cannot. The plan is a pure function of the
#' schema, so it is cheap to compute and inspect before reading any data.
#'
#' The plan reflects what [collect()], [read_parquet()], and [walk_batches()]
#' actually do today. Read types are currently chosen from the Parquet
#' *physical* type; logical annotations such as `DATE`, `TIMESTAMP`, and
#' `DECIMAL` are reported but not yet applied to the materialized values. When a
#' collectible column carries such an annotation, the `note` column records that
#' it is not yet applied.
#'
#' @param x A `qio_parquet_file` object, or the data frame returned by
#'   [schema()].
#' @param ... Reserved for future use.
#'
#' @return A `qio_read_plan` data frame with one row per physical leaf column
#'   and the columns:
#'   \describe{
#'     \item{`column`}{1-based physical column index.}
#'     \item{`name`, `path`}{Column name and dotted path.}
#'     \item{`physical_type`, `logical_type`}{Parquet physical type and logical
#'       annotation (`NA` when absent).}
#'     \item{`r_type`}{Target R type, or `NA` when the column cannot be
#'       collected.}
#'     \item{`converter`}{Stable identifier of the conversion the reader uses.}
#'     \item{`nullable`}{Whether the column can contain nulls.}
#'     \item{`collectible`}{Whether [collect()] can currently materialize the
#'       column.}
#'     \item{`note`}{Reason a column is not collectible, or a pending logical
#'       annotation; `NA` otherwise.}
#'   }
#'
#' @seealso [schema()], [collect()], [parquet_type_mapping()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(data.frame(x = 1:3, y = c("a", "b", NA)), path)
#' pf <- parquet_open(path)
#' read_plan(pf)
#' parquet_close(pf)
read_plan <- function(x, ...) {
  UseMethod("read_plan")
}

#' @rdname read_plan
#' @export
read_plan.qio_parquet_file <- function(x, ...) {
  qio_empty_dots(...)
  read_plan(schema(x))
}

#' @rdname read_plan
#' @export
read_plan.data.frame <- function(x, ...) {
  qio_empty_dots(...)
  qio_build_plan(x)
}

#' @export
read_plan.default <- function(x, ...) {
  stop(
    "`x` must be a `qio_parquet_file` or a schema data frame from `schema()`.",
    call. = FALSE
  )
}

qio_build_plan <- function(schema) {
  required <- c(
    "name",
    "path",
    "physical_type",
    "logical_type",
    "max_definition_level",
    "max_repetition_level"
  )
  missing <- setdiff(required, names(schema))
  if (length(missing)) {
    stop(
      "`x` is not a schema data frame; missing columns: ",
      paste(missing, collapse = ", "),
      ". Pass the value returned by `schema()`.",
      call. = FALSE
    )
  }

  registry <- qio_type_registry()
  idx <- match(schema$physical_type, registry$physical_type)
  r_type <- registry$r_type[idx]
  converter <- registry$converter[idx]

  # Logical annotations take precedence over the physical fallback.
  logical <- qio_resolve_logical(schema)
  applied <- logical$applied
  r_type[applied] <- logical$r_type[applied]
  converter[applied] <- logical$converter[applied]

  nullable <- schema$max_definition_level > 0L
  repeated <- schema$max_repetition_level > 0L

  # A column is collectible when its physical type maps to an R type and it is
  # not repeated (nested). An unapplied logical annotation does not block
  # collection; the column is still read from its physical type.
  collectible <- !is.na(r_type) & !repeated

  # Notes, in increasing priority so the most specific reason wins.
  note <- rep(NA_character_, nrow(schema))

  # A recognized annotation that qio does not yet apply (STRING and applied
  # overrides are excluded because those already produce the intended R type).
  pending <- collectible &
    !applied &
    !(schema$logical_type %in% c(NA, "STRING"))
  note[pending] <- paste0(
    "logical type ",
    schema$logical_type[pending],
    " is not yet applied; read as ",
    r_type[pending]
  )

  unsupported <- is.na(r_type)
  note[unsupported] <- paste0(
    "physical type ",
    schema$physical_type[unsupported],
    " is not supported for reading"
  )

  note[repeated] <- "repeated or nested column cannot be collected"

  plan <- data.frame(
    column = seq_len(nrow(schema)),
    name = schema$name,
    path = schema$path,
    physical_type = schema$physical_type,
    logical_type = schema$logical_type,
    r_type = r_type,
    converter = converter,
    nullable = nullable,
    collectible = collectible,
    note = note,
    stringsAsFactors = FALSE
  )
  class(plan) <- c("qio_read_plan", "data.frame")
  plan
}

# Apply a plan's logical conversions to a collected data frame. Columns are
# matched to plan rows by their dotted path, which `collect()` uses for names,
# so projected and reordered reads are handled correctly. Physical converters
# are the identity; only logical converters transform the vector.
qio_apply_plan <- function(df, plan) {
  paths <- names(df)
  idx <- match(paths, plan$path)
  for (i in seq_along(paths)) {
    if (is.na(idx[i])) {
      next
    }
    df[[i]] <- qio_apply_converter(df[[i]], plan$converter[idx[i]])
  }
  df
}

qio_apply_converter <- function(x, converter) {
  if (is.na(converter)) {
    return(x)
  }
  switch(
    converter,
    # INT32 days since 1970-01-01; R's Date is a double count of the same days.
    date32 = structure(as.double(x), class = "Date"),
    # INT64 counts since the epoch in the named unit; POSIXct is UTC seconds.
    timestamp_utc_millis = qio_as_posixct_utc(x, 1e3),
    timestamp_utc_micros = qio_as_posixct_utc(x, 1e6),
    timestamp_utc_nanos = qio_as_posixct_utc(x, 1e9),
    # Legacy INT96 is already decoded to UTC seconds in C; just add the class.
    int96 = qio_as_posixct_utc(x, 1),
    # Physical converters return their column unchanged.
    x
  )
}

qio_as_posixct_utc <- function(x, per_second) {
  structure(
    as.double(x) / per_second,
    class = c("POSIXct", "POSIXt"),
    tzone = "UTC"
  )
}

#' @export
print.qio_read_plan <- function(x, ...) {
  qio_empty_dots(...)
  n <- nrow(x)
  # `collectible` may be absent if the plan was column-subset before printing.
  if (is.null(x$collectible)) {
    cat(sprintf("<qio_read_plan: %d column%s>\n", n, if (n == 1L) "" else "s"))
  } else {
    cat(sprintf(
      "<qio_read_plan: %d column%s, %d collectible>\n",
      n,
      if (n == 1L) "" else "s",
      sum(x$collectible)
    ))
  }
  body <- x
  class(body) <- "data.frame"
  print(body)
  invisible(x)
}
