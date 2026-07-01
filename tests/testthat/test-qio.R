test_that("write_parquet() creates a Parquet file", {
  path <- withr::local_tempfile(fileext = ".parquet")

  expect_invisible(write_parquet(mtcars, path))
  expect_gt(file.info(path)$size, 0)
})

test_that("mtcars can be written and read", {
  path <- withr::local_tempfile(fileext = ".parquet")
  expected <- mtcars
  row.names(expected) <- NULL

  write_parquet(expected, path)
  actual <- read_parquet(path)

  expect_equal(actual, expected)
})

test_that("supported column types and missing values round-trip", {
  path <- withr::local_tempfile(fileext = ".parquet")
  input <- data.frame(
    logical = c(TRUE, FALSE, NA),
    integer = c(1L, NA_integer_, 3L),
    double = c(1.5, NaN, NA_real_),
    character = c("a", "", NA_character_),
    factor = factor(c("x", "y", NA))
  )
  expected <- input
  expected$factor <- as.character(expected$factor)

  write_parquet(input, path)
  actual <- read_parquet(path)

  expect_equal(actual, expected)
})

test_that("Date columns round-trip as INT32 + DATE", {
  path <- withr::local_tempfile(fileext = ".parquet")
  input <- data.frame(
    d = as.Date(c("1970-01-01", "2023-06-15", NA, "1960-12-31"))
  )

  write_parquet(input, path)
  actual <- read_parquet(path)

  expect_s3_class(actual$d, "Date")
  expect_equal(actual, input)
})

test_that("a written Date column is stored as INT32 with a DATE annotation", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(d = as.Date("2020-01-01")), path)

  pf <- parquet_open(path)
  on.exit(parquet_close(pf), add = TRUE)
  info <- schema(pf)

  expect_identical(info$physical_type, "INT32")
  expect_identical(info$logical_type, "DATE")
  expect_identical(read_plan(pf)$r_type, "Date")
})

test_that("integer-backed Date columns are written correctly", {
  path <- withr::local_tempfile(fileext = ".parquet")
  d <- structure(19000L, class = "Date") # integer storage, not double
  write_parquet(data.frame(d = d), path)

  expect_equal(read_parquet(path)$d, structure(19000, class = "Date"))
})

test_that("POSIXct columns round-trip as INT64 + UTC TIMESTAMP", {
  path <- withr::local_tempfile(fileext = ".parquet")
  input <- data.frame(
    t = as.POSIXct(
      c("2023-06-15 12:34:56.789", NA, "1969-12-31 23:59:59"),
      tz = "UTC"
    )
  )

  write_parquet(input, path)
  actual <- read_parquet(path)

  expect_s3_class(actual$t, "POSIXct")
  expect_identical(attr(actual$t, "tzone"), "UTC")
  expect_equal(actual, input)
})

test_that("a written POSIXct column is stored as a UTC-adjusted TIMESTAMP", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(t = as.POSIXct("2020-01-01", tz = "UTC")), path)

  pf <- parquet_open(path)
  on.exit(parquet_close(pf), add = TRUE)
  info <- schema(pf)

  expect_identical(info$physical_type, "INT64")
  expect_identical(info$logical_type, "TIMESTAMP")
  expect_match(info$logical_details, "unit=MICROS")
  expect_match(info$logical_details, "adjusted_to_utc=true")
  expect_identical(read_plan(pf)$r_type, "POSIXct")
})

test_that("parquet_type_mapping() describes read and write support", {
  expect_identical(
    parquet_type_mapping(),
    data.frame(
      parquet_type = c(
        "BOOLEAN",
        "INT32",
        "INT64",
        "INT96",
        "FLOAT",
        "DOUBLE",
        "BYTE_ARRAY",
        "FIXED_LEN_BYTE_ARRAY"
      ),
      read_as = c(
        "logical",
        "integer",
        "double",
        "POSIXct",
        "double",
        "double",
        "character",
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
      )
    )
  )
})
