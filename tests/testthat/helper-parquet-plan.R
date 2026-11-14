# A synthetic schema data frame covering every physical type, a pending logical
# annotation, an unsupported physical type, and a repeated (nested) column. This
# keeps the resolver test independent of what files carquet can produce.
fake_schema <- function() {
  data.frame(
    column = 1:13,
    name = c(
      "b",
      "i32",
      "i64",
      "f",
      "d",
      "s",
      "raw",
      "dt",
      "ts",
      "i96",
      "flba",
      "lst",
      "value"
    ),
    path = c(
      "b",
      "i32",
      "i64",
      "f",
      "d",
      "s",
      "raw",
      "dt",
      "ts",
      "i96",
      "flba",
      "lst.element",
      "struct.value"
    ),
    physical_type = c(
      "BOOLEAN",
      "INT32",
      "INT64",
      "FLOAT",
      "DOUBLE",
      "BYTE_ARRAY",
      "BYTE_ARRAY",
      "INT32",
      "INT64",
      "INT96",
      "FIXED_LEN_BYTE_ARRAY",
      "INT32",
      "DOUBLE"
    ),
    logical_type = c(
      NA,
      NA,
      NA,
      NA,
      NA,
      "STRING",
      NA,
      "DATE",
      "TIMESTAMP",
      NA,
      NA,
      NA,
      NA
    ),
    logical_details = NA_character_,
    repetition = c(rep("REQUIRED", 11), "REPEATED", "OPTIONAL"),
    type_length = c(rep(NA_integer_, 10), 16L, NA_integer_, NA_integer_),
    max_definition_level = c(
      0L,
      1L,
      0L,
      0L,
      0L,
      1L,
      0L,
      0L,
      0L,
      0L,
      0L,
      1L,
      1L
    ),
    max_repetition_level = c(rep(0L, 11), 1L, 0L),
    stringsAsFactors = FALSE
  )
}

ts_schema <- function(details) {
  data.frame(
    column = 1L,
    name = "t",
    path = "t",
    physical_type = "INT64",
    logical_type = "TIMESTAMP",
    logical_details = details,
    repetition = "OPTIONAL",
    type_length = NA_integer_,
    max_definition_level = 1L,
    max_repetition_level = 0L,
    stringsAsFactors = FALSE
  )
}

resolve_one <- function(physical, logical, details = NA_character_) {
  qio_resolve_logical(data.frame(
    physical_type = physical,
    logical_type = logical,
    logical_details = details,
    stringsAsFactors = FALSE
  ))
}
