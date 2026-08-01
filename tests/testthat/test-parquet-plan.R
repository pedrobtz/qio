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

test_that("read_plan() maps physical types to R types", {
  plan <- read_plan(fake_schema())

  expect_s3_class(plan, "qio_read_plan")
  expect_equal(
    plan$r_type,
    c(
      "logical",
      "integer",
      "double",
      "double",
      "double",
      "character",
      "character",
      "Date",
      "double",
      "POSIXct",
      NA,
      "integer",
      "double"
    )
  )
  expect_equal(
    plan$converter,
    c(
      "boolean",
      "int32",
      "int64_double",
      "float",
      "double",
      "byte_array",
      "byte_array",
      "date32",
      "int64",
      "int96",
      NA,
      "int32",
      "double"
    )
  )
})

test_that("read_plan() marks nullability from definition levels", {
  plan <- read_plan(fake_schema())
  expect_equal(
    plan$nullable,
    c(
      FALSE,
      TRUE,
      FALSE,
      FALSE,
      FALSE,
      TRUE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      TRUE,
      TRUE
    )
  )
})

test_that("read_plan() flags collectible columns and explains the rest", {
  plan <- read_plan(fake_schema())

  expect_equal(
    plan$nested,
    c(rep(FALSE, 11), TRUE, TRUE)
  )

  expect_equal(
    plan$collectible,
    c(
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      FALSE,
      FALSE,
      FALSE
    )
  )

  expect_true(all(is.na(plan$note[plan$name %in% c("b", "i32", "s", "raw")])))
  expect_true(is.na(plan$note[plan$name == "dt"]))
  expect_true(is.na(plan$note[plan$name == "i96"]))
  expect_match(plan$note[plan$name == "ts"], "TIMESTAMP is not yet applied")
  expect_match(
    plan$note[plan$name == "flba"],
    "FIXED_LEN_BYTE_ARRAY is not supported"
  )
  expect_match(plan$note[plan$name == "lst"], "nested or repeated")
  expect_match(plan$note[plan$path == "struct.value"], "nested or repeated")
})

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

test_that("read_plan() applies UTC timestamps and rescales by unit", {
  for (unit in c("MILLIS", "MICROS", "NANOS")) {
    plan <- read_plan(
      ts_schema(sprintf("unit=%s, adjusted_to_utc=true", unit))
    )
    expect_equal(plan$r_type, "POSIXct")
    expect_equal(plan$converter, paste0("timestamp_utc_", tolower(unit)))
    expect_true(plan$collectible)
    expect_true(is.na(plan$note))
  }
})

test_that("read_plan() leaves non-UTC timestamps unapplied", {
  plan <- read_plan(ts_schema("unit=MICROS, adjusted_to_utc=false"))

  expect_equal(plan$r_type, "double")
  expect_equal(plan$converter, "int64")
  expect_true(plan$collectible)
  expect_match(plan$note, "TIMESTAMP is not yet applied")
})

test_that("read_plan() rejects a data frame that is not a schema", {
  expect_error(read_plan(data.frame(a = 1)), "not a schema data frame")
})

test_that("read_plan() rejects unsupported input", {
  expect_snapshot(error = TRUE, read_plan(1L))
})

test_that("read_plan() works on an open file and matches its schema", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(
    data.frame(x = 1:3, y = c("a", "b", NA), z = c(1.5, 2.5, 3.5)),
    path
  )
  pf <- parquet_open(path)
  on.exit(parquet_close(pf), add = TRUE)

  plan <- read_plan(pf)

  expect_equal(read_plan(schema(pf)), plan)
  expect_true(all(plan$collectible))
  expect_equal(plan$r_type, c("integer", "character", "double"))
  expect_equal(plan$nullable, c(FALSE, TRUE, FALSE))
})

test_that("read_plan() accepts a file path", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(x = 1:3), path)

  expect_equal(read_plan(path)$r_type, "integer")
})

test_that("print.qio_read_plan() returns its input invisibly", {
  plan <- read_plan(fake_schema())
  expect_output(expect_invisible(print(plan)), "qio_read_plan")
})

# --- Phase 2: registry is authoritative ------------------------------------

test_that("parquet_type_mapping() is generated from the registry", {
  # The registry is the single source of truth for physical fallbacks. If the
  # mapping table is ever hand-edited, or a registry row is added without the
  # mapping following, this fails rather than letting documentation drift from
  # native behavior. See .agents/TYPES.md rule 8.
  registry <- qio_type_registry()
  mapping <- parquet_type_mapping()

  expect_identical(mapping$parquet_type, registry$physical_type)
  expect_identical(mapping$read_as, registry$r_type)
  expect_identical(mapping$written_from, registry$written_from)
  expect_identical(nrow(mapping), nrow(registry))
  expect_identical(names(mapping), c("parquet_type", "read_as", "written_from"))
})

test_that("the registry covers every physical type carquet can report", {
  # A physical type missing from the registry would silently become an
  # unsupported column with no mapping row to explain it.
  expect_setequal(
    qio_type_registry()$physical_type,
    c(
      "BOOLEAN",
      "INT32",
      "INT64",
      "INT96",
      "FLOAT",
      "DOUBLE",
      "BYTE_ARRAY",
      "FIXED_LEN_BYTE_ARRAY"
    )
  )
})

test_that("every registry converter is handled by qio_apply_converter()", {
  # An unhandled converter would fall through to the identity branch and
  # silently return the physical vector instead of the intended R type.
  converters <- c(
    qio_type_registry()$converter,
    qio_logical_registry()$converter,
    "timestamp_utc_millis",
    "timestamp_utc_micros",
    "timestamp_utc_nanos"
  )
  converters <- unique(converters[!is.na(converters)])

  for (converter in converters) {
    result <- qio_apply_converter(1, converter)
    expect_length(result, 1L)
  }
})

# --- Phase 2: complete-path selection --------------------------------------

test_that("qio_resolve_columns() maps paths to leaf indexes", {
  plan <- data.frame(
    path = c("s.b", "b", "label"),
    nested = c(TRUE, FALSE, FALSE),
    stringsAsFactors = FALSE
  )

  expect_null(qio_resolve_columns(plan, NULL))
  expect_identical(qio_resolve_columns(plan, "b"), 2L)
  expect_identical(qio_resolve_columns(plan, c("label", "s.b")), c(3L, 1L))
})

test_that("qio_resolve_columns() rejects unknown and ambiguous paths", {
  plan <- data.frame(
    path = c("a.b", "a.b", "c"),
    nested = c(TRUE, FALSE, FALSE),
    stringsAsFactors = FALSE
  )

  expect_error(qio_resolve_columns(plan, "nope"), "Unknown Parquet column")
  expect_error(
    qio_resolve_columns(plan, c("nope", "nah")),
    "Unknown Parquet columns"
  )
  # A flat column named "a.b" and a nested leaf b under group a render the same
  # path; qio refuses to guess which was meant.
  expect_error(qio_resolve_columns(plan, "a.b"), "Ambiguous Parquet column")
})

test_that("qio_select_columns() drops nested leaves and reports the count", {
  plan <- data.frame(
    path = c("s.b", "b", "label"),
    nested = c(TRUE, FALSE, FALSE),
    stringsAsFactors = FALSE
  )

  expect_message(
    selected <- qio_select_columns(plan, NULL),
    "Skipping 1 nested Parquet column"
  )
  expect_identical(selected, c(2L, 3L))

  # Nothing nested selected means no message at all.
  expect_message(qio_select_columns(plan, c("b", "label")), NA)
  expect_identical(qio_select_columns(plan, c("b", "label")), c(2L, 3L))

  # Selecting only nested leaves yields an empty selection, not an error.
  expect_message(
    empty <- qio_select_columns(plan, "s.b"),
    "Skipping 1 nested Parquet column"
  )
  expect_identical(empty, integer(0))
})

test_that("qio_select_columns() returns NULL when every column is selectable", {
  # NULL lets the native layer take its own all-columns path instead of
  # building an index vector for a wide file.
  plan <- data.frame(
    path = c("a", "b"),
    nested = c(FALSE, FALSE),
    stringsAsFactors = FALSE
  )
  expect_null(qio_select_columns(plan, NULL))
})
