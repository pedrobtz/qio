#' Create a Parquet writer schema
#'
#' Creates a reusable schema that controls how [write_parquet()] stores selected
#' columns. Each argument must be named and may be a type string or a list whose
#' first element is the type. Schemas may be partial: unspecified columns keep
#' qio's automatic mapping.
#'
#' Supported declarations are `"AUTO"`, `"BOOLEAN"`, `"INT32"`, `"INT64"`,
#' `"FLOAT"`, `"DOUBLE"`, `"STRING"`, `"DATE"`, `"TIMESTAMP"`, `"BINARY"`,
#' `"GEOMETRY"`, and `"GEOGRAPHY"`.
#' `TIMESTAMP` accepts `unit` (`"MILLIS"`, `"MICROS"`, or `"NANOS"`) and must
#' be adjusted to UTC. All types accept `repetition_type` (`"AUTO"`,
#' `"REQUIRED"`, or `"OPTIONAL"`).
#'
#' `INT32` and `INT64` declarations accept finite whole-number inputs; `INT64`
#' is limited to R's exact double-integer range from `-2^53` through `2^53`.
#' `FLOAT` and `DOUBLE` accept numeric input, `STRING` accepts character or
#' factor input, `DATE` accepts `Date` or whole-number days, and `TIMESTAMP`
#' accepts `POSIXct`.
#'
#' `"BINARY"`, `"GEOMETRY"` and `"GEOGRAPHY"` take a list of raw vectors, with
#' `NULL` for a missing value; such a list is written as `BINARY` without a
#' schema. `GEOMETRY` and `GEOGRAPHY` hold well-known binary (WKB) and accept
#' `crs`, a string of at most 127 bytes such as `"OGC:CRS84"` (the default),
#' `"EPSG:4326"`, or `"projjson:<key>"` naming a footer [write_parquet()]
#' `metadata` entry that holds the PROJJSON. `GEOGRAPHY` also accepts
#' `algorithm`, the edge interpolation: `"SPHERICAL"` (the default),
#' `"VINCENTY"`, `"THOMAS"`, `"ANDOYER"`, or `"KARNEY"`. qio does not parse the
#' WKB beyond what [geospatial_statistics()] records.
#'
#' @param ... Named Parquet type specifications.
#'
#' @return A `qio_parquet_schema` data frame.
#' @export
#' @examples
#' parquet_schema(
#'   id = "INT64",
#'   price = "FLOAT",
#'   created_at = list("TIMESTAMP", unit = "MILLIS")
#' )
#' parquet_schema(
#'   shape = list("GEOMETRY", crs = "EPSG:4326"),
#'   route = list("GEOGRAPHY", algorithm = "KARNEY")
#' )
parquet_schema <- function(...) {
  specs <- list(...)
  if (!length(specs)) {
    return(qio_new_schema(character(), character(), character(), character()))
  }
  nms <- names(specs)
  if (is.null(nms) || any(is.na(nms) | nms == "")) {
    stop("Every schema entry must have a column name.", call. = FALSE)
  }
  if (anyDuplicated(nms)) {
    stop("Schema column names must be unique.", call. = FALSE)
  }
  rows <- Map(qio_parse_type_spec, specs, nms)
  result <- do.call(rbind, rows)
  row.names(result) <- NULL
  class(result) <- c("qio_parquet_schema", "data.frame")
  result
}

#' Infer the Parquet writer schema for an R object
#'
#' Shows the physical and logical Parquet types that [write_parquet()] would use
#' without an explicit schema. Nullability is inferred from missing values.
#'
#' @param x A data frame or list of equal-length atomic vectors.
#'
#' @return A `qio_parquet_schema` data frame with one row per column.
#' @export
#' @examples
#' infer_parquet_schema(data.frame(id = 1:3, when = as.Date("2020-01-01")))
infer_parquet_schema <- function(x) {
  x <- qio_as_data_frame(x)
  qio_infer_schema(x)
}

qio_new_schema <- function(
  name,
  physical_type,
  logical_type,
  logical_details,
  repetition_type = character()
) {
  result <- data.frame(
    name = name,
    physical_type = physical_type,
    logical_type = logical_type,
    logical_details = logical_details,
    repetition_type = repetition_type,
    stringsAsFactors = FALSE
  )
  class(result) <- c("qio_parquet_schema", "data.frame")
  result
}

qio_parse_type_spec <- function(spec, name) {
  if (is.character(spec) && length(spec) == 1L && !is.na(spec)) {
    args <- list(type = spec)
  } else if (is.list(spec) && length(spec)) {
    args <- spec
    if (is.null(names(args)) || names(args)[1L] == "") {
      names(args)[1L] <- "type"
    }
  } else {
    stop(
      "Schema entry `",
      name,
      "` must be a type string or list.",
      call. = FALSE
    )
  }
  allowed <- c(
    "type",
    "unit",
    "is_adjusted_utc",
    "repetition_type",
    "crs",
    "algorithm"
  )
  unknown <- setdiff(names(args), allowed)
  if (length(unknown)) {
    stop(
      "Unknown parameter in schema entry `",
      name,
      "`: ",
      paste(unknown, collapse = ", "),
      ".",
      call. = FALSE
    )
  }
  type <- toupper(args$type)
  if (length(type) != 1L || is.na(type)) {
    stop("Schema entry `", name, "` must specify one type.", call. = FALSE)
  }
  repetition <- toupper(qio_or(args$repetition_type, "AUTO"))
  if (
    length(repetition) != 1L ||
      !repetition %in% c("AUTO", "REQUIRED", "OPTIONAL")
  ) {
    stop(
      "`repetition_type` for `",
      name,
      "` must be \"AUTO\", \"REQUIRED\", or \"OPTIONAL\".",
      call. = FALSE
    )
  }
  scalar <- c("AUTO", "BOOLEAN", "INT32", "INT64", "FLOAT", "DOUBLE")
  if (type %in% scalar) {
    if (any(c("unit", "is_adjusted_utc") %in% names(args))) {
      stop(
        "Schema type `",
        type,
        "` does not accept time parameters.",
        call. = FALSE
      )
    }
    return(qio_new_schema(name, type, NA_character_, NA_character_, repetition))
  }
  if (type %in% c("BINARY", "GEOMETRY", "GEOGRAPHY")) {
    return(qio_parse_binary_spec(type, args, name, repetition))
  }
  if (any(c("crs", "algorithm") %in% names(args))) {
    stop(
      "Schema type `",
      type,
      "` does not accept `crs` or `algorithm`.",
      call. = FALSE
    )
  }
  if (type == "STRING") {
    return(qio_new_schema(
      name,
      "BYTE_ARRAY",
      "STRING",
      NA_character_,
      repetition
    ))
  }
  if (type == "DATE") {
    return(qio_new_schema(name, "INT32", "DATE", NA_character_, repetition))
  }
  if (type == "TIMESTAMP") {
    unit <- toupper(qio_or(args$unit, "MICROS"))
    adjusted <- qio_or(args$is_adjusted_utc, TRUE)
    if (length(unit) != 1L || !unit %in% c("MILLIS", "MICROS", "NANOS")) {
      stop(
        "`unit` for `",
        name,
        "` must be MILLIS, MICROS, or NANOS.",
        call. = FALSE
      )
    }
    if (!is.logical(adjusted) || length(adjusted) != 1L || is.na(adjusted)) {
      stop(
        "`is_adjusted_utc` for `",
        name,
        "` must be TRUE or FALSE.",
        call. = FALSE
      )
    }
    if (!adjusted) {
      stop(
        "qio currently supports only UTC-adjusted TIMESTAMP output.",
        call. = FALSE
      )
    }
    details <- paste0("unit=", unit, ", adjusted_to_utc=true")
    return(qio_new_schema(name, "INT64", "TIMESTAMP", details, repetition))
  }
  stop(
    "Unsupported schema type `",
    type,
    "` for column `",
    name,
    "`.",
    call. = FALSE
  )
}

qio_as_data_frame <- function(x) {
  if (is.data.frame(x)) {
    return(x)
  }
  if (is.list(x)) {
    # as.data.frame() recycles a short column to the longest one, so
    # `list(a = 1:4, b = 10:11)` would silently be written as four rows with
    # `b` repeated. Writing values the caller never supplied is worse than
    # refusing, and the documented contract is equal-length vectors.
    lengths <- lengths(x)
    if (length(lengths) && length(unique(lengths)) > 1L) {
      names(lengths) <- names(x)
      longest <- max(lengths)
      short <- lengths[lengths != longest]
      stop(
        "`x` must be a list of equal-length vectors. ",
        "Longest is ",
        longest,
        "; ",
        paste0(
          "`",
          names(short),
          "` has ",
          short,
          collapse = ", "
        ),
        ".",
        call. = FALSE
      )
    }
    return(as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE))
  }
  stop("`x` must be a data frame.", call. = FALSE)
}

qio_edge_algorithms <- c("SPHERICAL", "VINCENTY", "THOMAS", "ANDOYER", "KARNEY")

# BINARY is unannotated BYTE_ARRAY. GEOMETRY and GEOGRAPHY are WKB in
# BYTE_ARRAY with a CRS (Parquet's default is OGC:CRS84) and, for GEOGRAPHY,
# an edge algorithm (default SPHERICAL). The details string is the one
# schema() reports when reading the file back.
qio_parse_binary_spec <- function(type, args, name, repetition) {
  if (any(c("unit", "is_adjusted_utc") %in% names(args))) {
    stop(
      "Schema type `",
      type,
      "` does not accept time parameters.",
      call. = FALSE
    )
  }
  if (type == "BINARY") {
    if (any(c("crs", "algorithm") %in% names(args))) {
      stop(
        "Schema type `BINARY` does not accept `crs` or `algorithm`.",
        call. = FALSE
      )
    }
    return(qio_new_schema(
      name,
      "BYTE_ARRAY",
      NA_character_,
      NA_character_,
      repetition
    ))
  }
  crs <- qio_or(args$crs, "OGC:CRS84")
  if (!is.character(crs) || length(crs) != 1L || is.na(crs) || !nzchar(crs)) {
    stop("`crs` for `", name, "` must be one non-empty string.", call. = FALSE)
  }
  # Counted and stored as UTF-8, the form the file holds, so the limit is in
  # the same unit as the native writer's.
  crs <- enc2utf8(crs)
  if (nchar(crs, type = "bytes") > 127L) {
    stop(
      "`crs` for `",
      name,
      "` is longer than the 127 bytes Parquet's geospatial types hold here. ",
      "Store a long CRS, such as PROJJSON, in the footer `metadata` and set ",
      "`crs` to \"projjson:<key>\".",
      call. = FALSE
    )
  }
  if (type == "GEOMETRY") {
    if ("algorithm" %in% names(args)) {
      stop("Schema type `GEOMETRY` does not accept `algorithm`.", call. = FALSE)
    }
    return(qio_new_schema(
      name,
      "BYTE_ARRAY",
      "GEOMETRY",
      paste0("crs=", crs),
      repetition
    ))
  }
  algorithm <- toupper(qio_or(args$algorithm, "SPHERICAL"))
  if (length(algorithm) != 1L || !algorithm %in% qio_edge_algorithms) {
    stop(
      "`algorithm` for `",
      name,
      "` must be one of ",
      paste(qio_edge_algorithms, collapse = ", "),
      ".",
      call. = FALSE
    )
  }
  qio_new_schema(
    name,
    "BYTE_ARRAY",
    "GEOGRAPHY",
    paste0("crs=", crs, ", algorithm=", algorithm),
    repetition
  )
}

# The CRS and edge algorithm of GEOMETRY and GEOGRAPHY details strings. Only
# GEOGRAPHY carries an algorithm, so only its suffix is one: a GEOMETRY CRS
# may itself end in ", algorithm=..." and must survive whole (#37). Text is
# made UTF-8 first, because sub() on a marked string otherwise translates it
# to the native encoding, which under LC_ALL=C writes "<e9>" for "é".
qio_parse_geo_details <- function(details, logical_type) {
  details <- enc2utf8(details)
  body <- sub("^crs=", "", details, useBytes = TRUE)
  suffix <- ", algorithm=([A-Z]+)$"
  geography <- logical_type == "GEOGRAPHY" &
    grepl(suffix, body, useBytes = TRUE)
  algorithm <- rep(NA_character_, length(details))
  algorithm[geography] <- sub(
    paste0("^.*", suffix),
    "\\1",
    body[geography],
    useBytes = TRUE
  )
  crs <- body
  crs[geography] <- sub(suffix, "", body[geography], useBytes = TRUE)
  Encoding(crs) <- "UTF-8"
  list(crs = crs, algorithm = algorithm)
}

# A list column holds binary when every element is a raw vector or NULL.
qio_is_binary_list <- function(x) {
  is.list(x) &&
    !is.data.frame(x) &&
    all(vapply(x, function(e) is.null(e) || is.raw(e), logical(1)))
}

qio_infer_schema <- function(x) {
  if (!ncol(x)) {
    stop("`x` has no columns.", call. = FALSE)
  }
  rows <- Map(qio_infer_column, x, names(x), USE.NAMES = FALSE)
  result <- do.call(rbind, rows)
  row.names(result) <- NULL
  class(result) <- c("qio_parquet_schema", "data.frame")
  result
}

qio_infer_column <- function(x, name) {
  repetition <- if (qio_has_null(x)) "OPTIONAL" else "REQUIRED"
  if (inherits(x, "Date")) {
    return(qio_new_schema(name, "INT32", "DATE", NA_character_, repetition))
  }
  if (inherits(x, "POSIXct")) {
    return(qio_new_schema(
      name,
      "INT64",
      "TIMESTAMP",
      "unit=MICROS, adjusted_to_utc=true",
      repetition
    ))
  }
  if (is.factor(x) || is.character(x)) {
    return(qio_new_schema(
      name,
      "BYTE_ARRAY",
      "STRING",
      NA_character_,
      repetition
    ))
  }
  if (qio_is_binary_list(x)) {
    return(qio_new_schema(
      name,
      "BYTE_ARRAY",
      NA_character_,
      NA_character_,
      repetition
    ))
  }
  physical <- switch(
    typeof(x),
    logical = "BOOLEAN",
    integer = "INT32",
    double = "DOUBLE",
    NULL
  )
  if (is.null(physical)) {
    stop(
      "Column `",
      name,
      "` has unsupported type `",
      typeof(x),
      "`.",
      if (is.list(x)) {
        " A list column is written only as binary: a list of raw vectors, with NULL for a missing value."
      },
      call. = FALSE
    )
  }
  qio_new_schema(name, physical, NA_character_, NA_character_, repetition)
}

qio_resolve_write_schema <- function(x, schema) {
  # Checked whether or not a schema is supplied. qio can write a file with two
  # leaves of the same name and read every column back, but `collect(columns =)`
  # resolves by path and then cannot name either of them: the file is only
  # readable in full. Refusing to write it is better than writing one that
  # cannot be projected.
  duplicated <- unique(names(x)[duplicated(names(x))])
  if (length(duplicated)) {
    stop(
      "`x` must have unique column names. Duplicated: ",
      paste0("`", duplicated, "`", collapse = ", "),
      ".",
      call. = FALSE
    )
  }
  inferred <- qio_infer_schema(x)
  if (is.null(schema)) {
    schema <- inferred
  } else {
    qio_validate_schema_object(schema)
    missing <- setdiff(schema$name, names(x))
    if (length(missing)) {
      stop(
        "Schema refers to missing column(s): ",
        paste(missing, collapse = ", "),
        ".",
        call. = FALSE
      )
    }
    idx <- match(schema$name, inferred$name)
    for (i in seq_len(nrow(schema))) {
      if (schema$physical_type[i] != "AUTO") {
        inferred[idx[i], ] <- schema[i, ]
      } else if (schema$repetition_type[i] != "AUTO") {
        inferred$repetition_type[idx[i]] <- schema$repetition_type[i]
      }
    }
    schema <- inferred
  }
  auto_rep <- schema$repetition_type == "AUTO"
  schema$repetition_type[auto_rep] <- vapply(
    x[auto_rep],
    qio_column_repetition,
    character(1)
  )
  qio_prepare_write_columns(x, schema)
}

qio_validate_schema_object <- function(schema) {
  if (!inherits(schema, "qio_parquet_schema")) {
    stop("`schema` must be created by `parquet_schema()`.", call. = FALSE)
  }
  required <- c(
    "name",
    "physical_type",
    "logical_type",
    "logical_details",
    "repetition_type"
  )
  if (
    !identical(names(schema), required) ||
      !all(vapply(schema, is.character, logical(1)))
  ) {
    stop("`schema` is not a valid qio Parquet schema.", call. = FALSE)
  }
  if (
    anyNA(schema$name) || any(schema$name == "") || anyDuplicated(schema$name)
  ) {
    stop("Schema column names must be non-missing and unique.", call. = FALSE)
  }
  allowed_physical <- c(
    "AUTO",
    "BOOLEAN",
    "INT32",
    "INT64",
    "FLOAT",
    "DOUBLE",
    "BYTE_ARRAY"
  )
  if (
    anyNA(schema$physical_type) ||
      any(!schema$physical_type %in% allowed_physical) ||
      anyNA(schema$repetition_type) ||
      any(!schema$repetition_type %in% c("AUTO", "REQUIRED", "OPTIONAL"))
  ) {
    stop("`schema` contains an unsupported type or repetition.", call. = FALSE)
  }
  pair <- paste(schema$physical_type, schema$logical_type)
  pair[is.na(schema$logical_type)] <- paste(
    schema$physical_type[is.na(schema$logical_type)],
    "NA"
  )
  allowed_pairs <- c(
    "AUTO NA",
    "BOOLEAN NA",
    "INT32 NA",
    "INT64 NA",
    "FLOAT NA",
    "DOUBLE NA",
    "BYTE_ARRAY STRING",
    "BYTE_ARRAY NA",
    "BYTE_ARRAY GEOMETRY",
    "BYTE_ARRAY GEOGRAPHY",
    "INT32 DATE",
    "INT64 TIMESTAMP"
  )
  if (any(!pair %in% allowed_pairs)) {
    stop(
      "`schema` contains an invalid physical and logical type combination.",
      call. = FALSE
    )
  }
  ts <- !is.na(schema$logical_type) & schema$logical_type == "TIMESTAMP"
  if (any(ts)) {
    details <- qio_parse_time_details(schema$logical_details[ts])
    if (
      any(!details$unit %in% c("MILLIS", "MICROS", "NANOS")) ||
        any(!details$adjusted_to_utc)
    ) {
      stop("`schema` contains an invalid TIMESTAMP declaration.", call. = FALSE)
    }
  }
  invisible(schema)
}

qio_prepare_write_columns <- function(x, schema) {
  columns <- vector("list", length(x))
  for (i in seq_along(x)) {
    columns[[i]] <- qio_prepare_write_column(x[[i]], schema[i, ])
    if (schema$repetition_type[i] == "REQUIRED" && qio_has_null(columns[[i]])) {
      stop(
        "Required column `",
        schema$name[i],
        "` contains missing values.",
        call. = FALSE
      )
    }
  }
  names(columns) <- names(x)
  codes <- c(0L, 1L, 2L, 4L, 5L, 6L)[match(
    schema$physical_type,
    c("BOOLEAN", "INT32", "INT64", "FLOAT", "DOUBLE", "BYTE_ARRAY")
  )]
  logical_codes <- match(
    schema$logical_type,
    c("DATE", "TIMESTAMP", "STRING", "GEOMETRY", "GEOGRAPHY"),
    nomatch = 0L
  )
  geo <- logical_codes %in% c(4L, 5L)
  crs <- rep(NA_character_, nrow(schema))
  algorithm <- rep(NA_integer_, nrow(schema))
  if (any(geo)) {
    parsed <- qio_parse_geo_details(
      schema$logical_details[geo],
      schema$logical_type[geo]
    )
    crs[geo] <- parsed$crs
    algorithm[geo] <- match(parsed$algorithm, qio_edge_algorithms) - 1L
  }
  units <- rep(0L, nrow(schema))
  ts <- !is.na(schema$logical_type) & schema$logical_type == "TIMESTAMP"
  units[ts] <- match(
    qio_parse_time_details(schema$logical_details[ts])$unit,
    c("MILLIS", "MICROS", "NANOS")
  )
  list(
    x = columns,
    native = list(
      physical_type = as.integer(codes),
      logical_type = as.integer(logical_codes),
      time_unit = as.integer(units),
      nullable = schema$repetition_type == "OPTIONAL",
      crs = crs,
      algorithm = as.integer(algorithm)
    ),
    schema = schema
  )
}

qio_prepare_write_column <- function(x, spec) {
  name <- spec$name
  physical <- spec$physical_type
  logical <- spec$logical_type
  if (identical(logical, "DATE")) {
    if (!inherits(x, "Date") && !is.numeric(x)) {
      stop("DATE column `", name, "` must be Date or numeric.", call. = FALSE)
    }
    value <- as.double(x)
    if (any(is.nan(value))) {
      stop("DATE column `", name, "` cannot contain NaN.", call. = FALSE)
    }
    qio_validate_integral(
      value,
      name,
      -.Machine$integer.max - 1,
      .Machine$integer.max
    )
    return(value)
  }
  if (identical(logical, "TIMESTAMP")) {
    if (!inherits(x, "POSIXct")) {
      stop("TIMESTAMP column `", name, "` must be POSIXct.", call. = FALSE)
    }
    value <- as.double(x)
    if (any(is.nan(value))) {
      stop("TIMESTAMP column `", name, "` cannot contain NaN.", call. = FALSE)
    }
    unit <- qio_parse_time_details(spec$logical_details)$unit
    per_second <- c(MILLIS = 1e3, MICROS = 1e6, NANOS = 1e9)[[unit]]
    present <- !is.na(value)
    scaled <- value[present] * per_second
    if (
      any(!is.finite(value[present])) ||
        any(!is.finite(scaled)) ||
        any(scaled <= -2^63 | scaled >= 2^63)
    ) {
      stop(
        "TIMESTAMP column `",
        name,
        "` is outside the INT64 range.",
        call. = FALSE
      )
    }
    return(value)
  }
  if (physical == "BOOLEAN") {
    if (!is.logical(x)) {
      stop("BOOLEAN column `", name, "` must be logical.", call. = FALSE)
    }
    return(x)
  }
  if (physical == "INT32") {
    if (!is.numeric(x)) {
      stop("INT32 column `", name, "` must be numeric.", call. = FALSE)
    }
    value <- as.double(x)
    if (any(is.nan(value))) {
      stop("INT32 column `", name, "` cannot contain NaN.", call. = FALSE)
    }
    qio_validate_integral(
      value,
      name,
      -.Machine$integer.max - 1,
      .Machine$integer.max
    )
    return(as.integer(value))
  }
  if (physical == "INT64") {
    if (!is.numeric(x)) {
      stop("INT64 column `", name, "` must be numeric.", call. = FALSE)
    }
    value <- as.double(x)
    if (any(is.nan(value))) {
      stop("INT64 column `", name, "` cannot contain NaN.", call. = FALSE)
    }
    qio_validate_integral(value, name, -2^53, 2^53)
    return(value)
  }
  if (physical %in% c("FLOAT", "DOUBLE")) {
    if (!is.numeric(x)) {
      stop(physical, " column `", name, "` must be numeric.", call. = FALSE)
    }
    return(as.double(x))
  }
  if (physical == "BYTE_ARRAY" && identical(logical, "STRING")) {
    if (is.factor(x)) {
      x <- as.character(x)
    }
    if (!is.character(x)) {
      stop(
        "STRING column `",
        name,
        "` must be character or factor.",
        call. = FALSE
      )
    }
    return(x)
  }
  if (physical == "BYTE_ARRAY") {
    if (!qio_is_binary_list(x)) {
      stop(
        if (is.na(logical)) "BINARY" else logical,
        " column `",
        name,
        "` must be a list of raw vectors, with NULL for a missing value.",
        call. = FALSE
      )
    }
    attributes(x) <- NULL
    return(x)
  }
  stop("Unsupported writer mapping for column `", name, "`.", call. = FALSE)
}

qio_validate_integral <- function(x, name, min, max) {
  present <- !is.na(x)
  if (any(!is.finite(x[present])) || any(x[present] != trunc(x[present]))) {
    stop(
      "Column `",
      name,
      "` must contain finite whole numbers.",
      call. = FALSE
    )
  }
  if (any(x[present] < min | x[present] > max)) {
    stop(
      "Column `",
      name,
      "` contains values outside the supported range.",
      call. = FALSE
    )
  }
}

qio_has_null <- function(x) {
  if (is.list(x)) {
    return(any(vapply(x, is.null, logical(1))))
  }
  if (is.double(x)) {
    return(any(is.na(x) & !is.nan(x)))
  }
  anyNA(x)
}

qio_column_repetition <- function(x) {
  if (qio_has_null(x)) "OPTIONAL" else "REQUIRED"
}

qio_or <- function(x, y) if (is.null(x)) y else x

#' @export
print.qio_parquet_schema <- function(x, ...) {
  qio_empty_dots(...)
  cat(sprintf(
    "<qio_parquet_schema: %d column%s>\n",
    nrow(x),
    if (nrow(x) == 1L) "" else "s"
  ))
  body <- x
  class(body) <- "data.frame"
  print(body)
  invisible(x)
}
