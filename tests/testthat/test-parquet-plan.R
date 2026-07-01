# A synthetic schema data frame covering every physical type, a pending logical
# annotation, an unsupported physical type, and a repeated (nested) column. This
# keeps the resolver test independent of what files carquet can produce.
fake_schema <- function() {
  data.frame(
    column = 1:12,
    name = c(
      "b", "i32", "i64", "f", "d", "s", "raw",
      "dt", "ts", "i96", "flba", "lst"
    ),
    path = c(
      "b", "i32", "i64", "f", "d", "s", "raw",
      "dt", "ts", "i96", "flba", "lst.element"
    ),
    physical_type = c(
      "BOOLEAN", "INT32", "INT64", "FLOAT", "DOUBLE", "BYTE_ARRAY",
      "BYTE_ARRAY", "INT32", "INT64", "INT96", "FIXED_LEN_BYTE_ARRAY", "INT32"
    ),
    logical_type = c(
      NA, NA, NA, NA, NA, "STRING", NA, "DATE", "TIMESTAMP", NA, NA, NA
    ),
    logical_details = NA_character_,
    repetition = c(rep("REQUIRED", 11), "REPEATED"),
    type_length = c(rep(NA_integer_, 10), 16L, NA_integer_),
    max_definition_level = c(0L, 1L, 0L, 0L, 0L, 1L, 0L, 0L, 0L, 0L, 0L, 1L),
    max_repetition_level = c(rep(0L, 11), 1L),
    stringsAsFactors = FALSE
  )
}

test_that("read_plan() maps physical types to R types", {
  plan <- read_plan(fake_schema())

  expect_s3_class(plan, "qio_read_plan")
  expect_equal(
    plan$r_type,
    c(
      "logical", "integer", "double", "double", "double", "character",
      "character", "Date", "double", "POSIXct", NA, "integer"
    )
  )
  expect_equal(
    plan$converter,
    c(
      "boolean", "int32", "int64", "float", "double", "byte_array",
      "byte_array", "date32", "int64", "int96", NA, "int32"
    )
  )
})

test_that("read_plan() marks nullability from definition levels", {
  plan <- read_plan(fake_schema())
  expect_equal(
    plan$nullable,
    c(FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE,
      FALSE, FALSE, TRUE)
  )
})

test_that("read_plan() flags collectible columns and explains the rest", {
  plan <- read_plan(fake_schema())

  expect_equal(
    plan$collectible,
    c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
      TRUE, FALSE, FALSE)
  )

  expect_true(all(is.na(plan$note[plan$name %in% c("b", "i32", "s", "raw")])))
  expect_true(is.na(plan$note[plan$name == "dt"]))
  expect_true(is.na(plan$note[plan$name == "i96"]))
  expect_match(plan$note[plan$name == "ts"], "TIMESTAMP is not yet applied")
  expect_match(
    plan$note[plan$name == "flba"],
    "FIXED_LEN_BYTE_ARRAY is not supported"
  )
  expect_match(plan$note[plan$name == "lst"], "repeated or nested")
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
  expect_error(read_plan(1L), "must be a `qio_parquet_file`")
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

test_that("print.qio_read_plan() returns its input invisibly", {
  plan <- read_plan(fake_schema())
  expect_output(expect_invisible(print(plan)), "qio_read_plan")
})
