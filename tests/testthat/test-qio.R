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
