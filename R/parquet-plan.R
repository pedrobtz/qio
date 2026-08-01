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
      "list"
    ),
    converter = c(
      "boolean",
      "int32",
      "int64",
      "int96",
      "float",
      "double",
      "byte_array",
      "binary"
    ),
    written_from = c(
      "logical",
      "integer",
      "numeric (explicit schema)",
      NA,
      "numeric (explicit schema)",
      "double",
      "character or factor",
      NA
    ),
    stringsAsFactors = FALSE
  )
}

# Validate the options that change how a materializing read maps values to R.
#
# Every entry point that can materialize values calls this first, before any
# allocation or native call, so `read_parquet()`, `collect()`, `walk_batches()`,
# and `read_plan()` cannot diverge. See .agents/roadmap.md, "Read options".
qio_read_options <- function(int64 = c("double", "integer64")) {
  int64 <- match.arg(int64)
  if (int64 == "integer64" && !requireNamespace("bit64", quietly = TRUE)) {
    stop(
      "`int64 = \"integer64\"` needs the bit64 package. ",
      "Install it, or use `int64 = \"double\"`.",
      call. = FALSE
    )
  }
  list(int64 = int64)
}

# The native layer takes the mode as a small integer code; keep the mapping in
# one place so C and R cannot disagree about which is which.
qio_int64_code <- function(options) {
  if (options$int64 == "integer64") 1L else 0L
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
qio_resolve_logical <- function(schema, options = qio_read_options()) {
  n <- nrow(schema)
  r_type <- rep(NA_character_, n)
  converter <- rep(NA_character_, n)

  # A NULL-annotated column carries no values at all: every entry is null
  # whatever its physical type. Materialize it as all-NA logical so the row
  # count survives. TYPES.md, "Target mappings".
  is_null_type <- !is.na(schema$logical_type) & schema$logical_type == "NULL"
  r_type[is_null_type] <- "logical"
  converter[is_null_type] <- "null_logical"

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

  # Byte arrays are text only when the file says so. An unannotated
  # BYTE_ARRAY is arbitrary bytes, and returning it as character would assume a
  # UTF-8 encoding the file never claimed. TYPES.md, "Text and binary".
  is_text <- !is.na(schema$logical_type) &
    schema$logical_type %in% c("STRING", "ENUM", "JSON") &
    schema$physical_type == "BYTE_ARRAY"
  r_type[is_text] <- "character"
  converter[is_text] <- "text"

  # UUID is 16 fixed bytes with a canonical text form; FLOAT16 is 2 fixed bytes
  # widened to double. Both are decoded as raw in C and converted here.
  is_uuid <- !is.na(schema$logical_type) &
    schema$logical_type == "UUID" &
    schema$physical_type == "FIXED_LEN_BYTE_ARRAY"
  r_type[is_uuid] <- "character"
  converter[is_uuid] <- "uuid"

  is_float16 <- !is.na(schema$logical_type) &
    schema$logical_type == "FLOAT16" &
    schema$physical_type == "FIXED_LEN_BYTE_ARRAY"
  r_type[is_float16] <- "double"
  converter[is_float16] <- "float16"

  # Everything else stored as bytes stays bytes: unannotated BYTE_ARRAY, BSON,
  # and any FIXED_LEN_BYTE_ARRAY without a mapping above.
  is_binary <- is.na(r_type) &
    schema$physical_type %in% c("BYTE_ARRAY", "FIXED_LEN_BYTE_ARRAY")
  r_type[is_binary] <- "list"
  converter[is_binary] <- "binary"

  # 64-bit integers are selected by the read's `int64` mode, not by the file.
  # Bare INT64 and an unsigned INTEGER(64) annotation both land here: C reads
  # the same bits differently and reports anything it could not keep. This runs
  # last and only fills rows no more specific annotation claimed, so a
  # TIMESTAMP or DATE mapping always wins.
  is_plain_int64 <- is.na(r_type) &
    schema$physical_type == "INT64" &
    (is.na(schema$logical_type) | schema$logical_type == "INTEGER")
  if (any(is_plain_int64)) {
    integer64 <- options$int64 == "integer64"
    r_type[is_plain_int64] <- if (integer64) "integer64" else "double"
    converter[is_plain_int64] <- if (integer64) {
      "int64_bit64"
    } else {
      "int64_double"
    }
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
#' actually do today. Supported logical annotations override the physical type:
#' `DATE`, UTC-adjusted `TIMESTAMP`, and legacy physical `INT96` timestamps are
#' converted to their R date-time classes. Unimplemented annotations are
#' reported in `note` and retain their physical fallback type.
#'
#' @param x A Parquet file path, a `qio_parquet_file` object, or the data frame
#'   returned by [schema()].
#' @param ... Reserved for future use.
#' @param int64 How 64-bit integer columns reach R; see [collect()]. The plan
#'   reports the resulting `r_type` and `converter`, so it can be inspected for
#'   exactly the read that will follow.
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
#'     \item{`nested`}{Whether the leaf belongs to a nested or repeated field.}
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
read_plan.qio_parquet_file <- function(
  x,
  ...,
  int64 = c("double", "integer64")
) {
  qio_empty_dots(...)
  read_plan(schema(x), int64 = int64)
}

#' @rdname read_plan
#' @export
read_plan.character <- function(x, ..., int64 = c("double", "integer64")) {
  qio_empty_dots(...)
  if (length(x) != 1L || is.na(x)) {
    stop("`x` must be a single Parquet file path.", call. = FALSE)
  }
  pf <- parquet_open(x)
  on.exit(parquet_close(pf), add = TRUE)
  read_plan(pf, int64 = int64)
}

#' @rdname read_plan
#' @export
read_plan.data.frame <- function(x, ..., int64 = c("double", "integer64")) {
  qio_empty_dots(...)
  qio_build_plan(x, qio_read_options(int64 = int64))
}

#' @export
read_plan.default <- function(x, ...) {
  stop(
    paste0(
      "`x` must be a Parquet file path, a `qio_parquet_file`, or a schema ",
      "data frame from `schema()`."
    ),
    call. = FALSE
  )
}

qio_build_plan <- function(schema, options = qio_read_options()) {
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
  logical <- qio_resolve_logical(schema, options)
  applied <- logical$applied
  r_type[applied] <- logical$r_type[applied]
  converter[applied] <- logical$converter[applied]

  nullable <- schema$max_definition_level > 0L
  repeated <- schema$max_repetition_level > 0L
  nested <- repeated | schema$path != schema$name

  # A column is collectible when its physical type maps to an R type and it is
  # not repeated (nested). An unapplied logical annotation does not block
  # collection; the column is still read from its physical type.
  collectible <- !is.na(r_type) & !nested

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

  note[nested] <- paste0(
    "nested or repeated column is skipped; nested reading is deferred to ",
    "qio 0.2.0"
  )

  plan <- data.frame(
    column = seq_len(nrow(schema)),
    name = schema$name,
    path = schema$path,
    physical_type = schema$physical_type,
    logical_type = schema$logical_type,
    r_type = r_type,
    converter = converter,
    nullable = nullable,
    nested = nested,
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
    # C already range-checked against R's exact double range and substituted
    # NA where a value could not survive, so the vector is final.
    int64_double = x,
    # C wrote raw int64 bits into the double payload, which is exactly
    # bit64::integer64's storage; only the class is missing.
    int64_bit64 = structure(x, class = "integer64"),
    # A NULL-annotated column has no values; preserve only its length.
    null_logical = rep(NA, length(x)),
    # C already produced a character vector or a list of raw vectors.
    text = x,
    binary = x,
    # 16 raw bytes to the canonical 8-4-4-4-12 hyphenated form.
    uuid = qio_format_uuid(x),
    # IEEE 754 binary16, little-endian, widened to double.
    float16 = qio_decode_float16(x),
    # Physical converters return their column unchanged.
    x
  )
}

# 16 raw bytes to the canonical hyphenated UUID form. A NULL element is a null
# value and stays NA; any other length is a malformed file, not a value qio can
# silently reinterpret.
qio_format_uuid <- function(x) {
  vapply(
    x,
    function(bytes) {
      if (is.null(bytes)) {
        return(NA_character_)
      }
      if (length(bytes) != 16L) {
        stop(
          "A UUID column contains a value of ",
          length(bytes),
          " bytes; UUID requires exactly 16.",
          call. = FALSE
        )
      }
      hex <- paste(format(bytes), collapse = "")
      paste(
        substr(hex, 1L, 8L),
        substr(hex, 9L, 12L),
        substr(hex, 13L, 16L),
        substr(hex, 17L, 20L),
        substr(hex, 21L, 32L),
        sep = "-"
      )
    },
    character(1),
    USE.NAMES = FALSE
  )
}

# IEEE 754 binary16 (little-endian) widened to double. Parquet stores FLOAT16
# as two fixed bytes; R has no half type, so widening is lossless.
qio_decode_float16 <- function(x) {
  vapply(
    x,
    function(bytes) {
      if (is.null(bytes)) {
        return(NA_real_)
      }
      if (length(bytes) != 2L) {
        stop(
          "A FLOAT16 column contains a value of ",
          length(bytes),
          " bytes; FLOAT16 requires exactly 2.",
          call. = FALSE
        )
      }
      bits <- as.integer(bytes[[1L]]) + 256L * as.integer(bytes[[2L]])
      sign <- if (bits >= 32768L) -1 else 1
      exponent <- bits %/% 1024L %% 32L
      mantissa <- bits %% 1024L
      if (exponent == 0L) {
        # Subnormal, or a signed zero when the mantissa is zero too.
        sign * mantissa * 2^-24
      } else if (exponent == 31L) {
        if (mantissa == 0L) sign * Inf else NaN
      } else {
        sign * (1 + mantissa / 1024) * 2^(exponent - 15L)
      }
    },
    numeric(1),
    USE.NAMES = FALSE
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
