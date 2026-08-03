# Appending writes into a file the user already has, which makes it the only
# operation in qio that can destroy existing data. The bundled library's own
# compatibility check compares logical type *identity* without comparing its
# parameters, so it accepts a MICROS-versus-MILLIS mismatch and rewrites the
# footer -- corrupting rows that were already correct. qio therefore validates
# the full declaration itself, and these tests are mostly about refusals.

writer_pair <- function() {
  list(
    first = data.frame(
      a = 1:5,
      b = c(1.5, 2.5, NA, 4.5, 5.5),
      s = letters[1:5],
      stringsAsFactors = FALSE
    ),
    second = data.frame(
      a = 6:10,
      b = c(6.5, 7.5, 8.5, 9.5, 10.5),
      s = letters[6:10],
      stringsAsFactors = FALSE
    )
  )
}

test_that("append adds row groups and preserves both halves", {
  path <- withr::local_tempfile(fileext = ".parquet")
  pair <- writer_pair()

  write_parquet(pair$first, path)
  write_parquet(pair$second, path, append = TRUE)

  expect_identical(read_parquet(path), rbind(pair$first, pair$second))

  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  expect_identical(nrow(row_groups(file)), 2L)
  expect_equal(row_groups(file)$rows, c(5, 5))
})

test_that("append repeats without drift", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(n = 1:10, s = letters[1:10], stringsAsFactors = FALSE)
  write_parquet(data, path)
  for (i in 1:4) {
    write_parquet(data, path, append = TRUE)
  }
  expect_identical(nrow(read_parquet(path)), 50L)
  expect_identical(read_parquet(path)$n, rep(1:10, 5))
})

test_that("nullability comes from the file, not from the new batch", {
  # The second batch has no NA, so qio would infer REQUIRED for it. The file
  # declares the column OPTIONAL, and the append has to follow the file.
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(v = c(1, NA, 3)), path)
  write_parquet(data.frame(v = c(4, 5, 6)), path, append = TRUE)

  expect_identical(read_parquet(path)$v, c(1, NA, 3, 4, 5, 6))
  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  expect_identical(schema(file)$repetition, "OPTIONAL")
})

test_that("append refuses to put NA into a REQUIRED column", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(v = c(1, 2, 3)), path)
  expect_error(
    write_parquet(data.frame(v = c(4, NA, 6)), path, append = TRUE),
    "REQUIRED"
  )
  # The refusal happened before anything was written.
  expect_identical(read_parquet(path)$v, c(1, 2, 3))
})

test_that("append refuses a differing shape", {
  path <- withr::local_tempfile(fileext = ".parquet")
  pair <- writer_pair()
  write_parquet(pair$first, path)

  expect_error(
    write_parquet(data.frame(a = 1:2), path, append = TRUE),
    "3 columns but 1"
  )
  expect_error(
    write_parquet(pair$second[, c(2, 1, 3)], path, append = TRUE),
    "different order"
  )
  renamed <- pair$second
  names(renamed)[1] <- "z"
  expect_error(
    write_parquet(renamed, path, append = TRUE),
    "column names differ"
  )
  expect_error(
    write_parquet(pair$first, tempfile(fileext = ".parquet"), append = TRUE),
    "does not exist"
  )
  # None of the refusals disturbed the file.
  expect_identical(read_parquet(path), pair$first)
})

test_that("append refuses a differing physical type", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(v = 1:3), path)
  expect_error(
    write_parquet(data.frame(v = c(1.5, 2.5, 3.5)), path, append = TRUE),
    "physical_type"
  )
  expect_identical(read_parquet(path)$v, 1:3)
})

# --- The check the bundled library does not make ----------------------------

test_that("append refuses a timestamp unit mismatch", {
  # This is the case that matters. carquet compares logical type IDs, so both
  # sides are TIMESTAMP and it accepts; the append then rewrites the footer and
  # the rows already in the file decode against the wrong unit. Without this
  # check, three correct 2020 timestamps came back as 1970.
  path <- withr::local_tempfile(fileext = ".parquet")
  stamps <- as.POSIXct("2020-01-01", tz = "UTC") + 1:3
  millis <- parquet_schema(t = list("TIMESTAMP", unit = "MILLIS"))
  micros <- parquet_schema(t = list("TIMESTAMP", unit = "MICROS"))

  write_parquet(data.frame(t = stamps), path, schema = millis)
  expect_error(
    write_parquet(data.frame(t = stamps), path, schema = micros, append = TRUE),
    "logical_details"
  )
  # The file is untouched, which is the whole point.
  expect_equal(read_parquet(path)$t, stamps)

  # The matching unit is accepted.
  write_parquet(data.frame(t = stamps), path, schema = millis, append = TRUE)
  expect_equal(read_parquet(path)$t, c(stamps, stamps))
})

test_that("append refuses a logical annotation mismatch", {
  path <- withr::local_tempfile(fileext = ".parquet")
  # DATE-annotated INT32 versus bare INT32: same physical type, different
  # annotation, and carquet compares only the ID.
  write_parquet(data.frame(d = as.Date("2020-01-01") + 1:3), path)
  expect_error(
    write_parquet(data.frame(d = 1:3), path, append = TRUE),
    "logical_type"
  )
  expect_identical(read_parquet(path)$d, as.Date("2020-01-01") + 1:3)
})

test_that("append carries footer metadata and accepts new entries", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = 1:3), path, metadata = c(first = "yes"))
  write_parquet(
    data.frame(n = 4:6),
    path,
    append = TRUE,
    metadata = c(second = "also")
  )
  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  pairs <- metadata(file)
  expect_identical(pairs$value[pairs$key == "first"], "yes")
  expect_identical(pairs$value[pairs$key == "second"], "also")
})

test_that("append honors row_group_size for the new data", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = 1:10), path)
  write_parquet(data.frame(n = 11:40), path, append = TRUE, row_group_size = 10)
  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  expect_equal(row_groups(file)$rows, c(10, 10, 10, 10))
  expect_identical(read_parquet(path)$n, 1:40)
})
