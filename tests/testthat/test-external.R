# Reading third-party Parquet files from the Apache reference corpus
# (apache/parquet-testing). See parquet/SOURCE.md for provenance.
#
# The current reader handles flat schemas of primitive types only. Every file
# below exercises a feature that is not supported yet, so these tests pin the
# *current* behavior: a clean, informative error rather than a crash. When a
# feature lands, promote the corresponding test to a positive read assertion.

ext <- function(name) test_path("parquet", name)

test_that("external fixtures are present and look like Parquet", {
  files <- c(
    "alltypes_plain.parquet",
    "alltypes_plain.snappy.parquet",
    "alltypes_dictionary.parquet",
    "int96_from_spark.parquet",
    "datapage_v2.snappy.parquet",
    "nested_maps.snappy.parquet",
    "nullable.impala.parquet"
  )
  for (f in files) {
    expect_true(file.exists(ext(f)), info = f)
    con <- file(ext(f), "rb")
    on.exit(close(con), add = TRUE)
    expect_identical(readChar(con, 4L, useBytes = TRUE), "PAR1", info = f)
    close(con)
    on.exit(NULL)
  }
})

# --- INT96 timestamps: read as UTC POSIXct ---------------------------------
# alltypes_* carry an INT96 `timestamp_col`; int96_from_spark is all-INT96.
test_that("Spark INT96 timestamps read as UTC POSIXct", {
  df <- read_parquet(ext("int96_from_spark.parquet"))

  expect_s3_class(df$a, "POSIXct")
  expect_identical(attr(df$a, "tzone"), "UTC")
  expect_equal(df$a[[1]], as.POSIXct("2024-01-01 20:34:56", tz = "UTC"))
  expect_true(is.na(df$a[[5]])) # the fixture includes a null
})

test_that("alltypes files read their INT96 timestamp_col", {
  for (f in c(
    "alltypes_plain.parquet",
    "alltypes_plain.snappy.parquet",
    "alltypes_dictionary.parquet"
  )) {
    df <- read_parquet(ext(f))
    expect_true(inherits(df$timestamp_col, "POSIXct"), info = f)
    # These fixtures hold 2009 timestamps (row count differs across variants).
    years <- as.integer(format(df$timestamp_col, "%Y", tz = "UTC"))
    expect_true(all(years == 2009, na.rm = TRUE), info = f)
  }
})

# --- DATA_PAGE_V2 with delta encodings: not yet readable --------------------
test_that("DATA_PAGE_V2 delta-encoded file is not yet readable", {
  expect_error(
    suppressMessages(read_parquet(ext("datapage_v2.snappy.parquet"))),
    "qio:"
  )
})

# --- Nested map/list columns: skipped until 0.2.0 ---------------------------
test_that("nested columns are skipped with one message per operation", {
  path <- ext("nullable.impala.parquet")

  expect_snapshot(result <- read_parquet(path))
  expect_identical(names(result), "id")
  expect_equal(nrow(result), 7L)

  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  expect_snapshot(
    empty <- collect(file, columns = "int_array.list.element")
  )
  expect_equal(dim(empty), c(7L, 0L))

  dimensions <- list()
  expect_snapshot(
    walk_batches(
      file,
      function(batch, index) dimensions[[index]] <<- dim(batch),
      batch_size = 3L
    )
  )
  expect_equal(dimensions, list(c(3L, 1L), c(3L, 1L), c(1L, 1L)))
})

test_that("errors in remaining flat columns are still reported", {
  expect_error(
    suppressMessages(read_parquet(ext("nested_maps.snappy.parquet"))),
    "qio:"
  )
})

# --- INT32 sentinel (bare INT32 written by Apache Arrow) --------------------
# R's integer reserves -2147483648 as NA_integer_, so a legal Parquet value is
# unrepresentable. qio keeps the integer mapping and reports the substitution
# once per read. See .agents/TYPES.md and parquet/SOURCE.md.

test_that("a third-party bare INT32 sentinel warns and preserves other values", {
  path <- ext("int32_min.parquet")

  expect_warning(df <- read_parquet(path), "reserves -2147483648")
  expect_type(df$value, "integer")
  expect_identical(
    df$value,
    c(NA_integer_, -1L, 0L, 2147483647L, NA_integer_)
  )
  expect_identical(df$label, c("min", "neg", "zero", "max", NA_character_))
})

test_that("the sentinel does not change the column type", {
  # A data-dependent type would break the guarantee that read_plan() is a pure
  # function of the schema and that all three read APIs agree.
  path <- ext("int32_min.parquet")
  plan <- read_plan(path)

  expect_identical(plan$r_type[plan$name == "value"], "integer")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))
  expect_warning(collected <- collect(file), "reserves -2147483648")
  expect_type(collected$value, "integer")
})

# --- Complete-path column identity -----------------------------------------
# name_collision.parquet has two leaves named "b" at different paths ("s.b" and
# "b"). carquet's own lookup compares leaf names only, so qio resolves
# selections to leaf indexes by complete path first. See .agents/carquet.md.

test_that("selection resolves by complete path, not by leaf name", {
  path <- ext("name_collision.parquet")

  # "b" must be the flat leaf, never the nested s.b that shares its name.
  expect_message(
    flat <- collect(parquet_open(path), columns = "b"),
    NA
  )
  expect_identical(flat$b, c(1L, 2L, 3L))
})

test_that("a nested leaf sharing a flat leaf's name is skipped, not selected", {
  path <- ext("name_collision.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  expect_message(result <- collect(file), "Skipping 1 nested Parquet column")
  expect_identical(names(result), c("b", "label"))
  expect_identical(result$b, c(1L, 2L, 3L))
})

test_that("read_plan marks the colliding leaves by path", {
  plan <- read_plan(ext("name_collision.parquet"))

  expect_identical(plan$path, c("s.b", "b", "label"))
  expect_identical(plan$name, c("b", "b", "label"))
  expect_identical(plan$nested, c(TRUE, FALSE, FALSE))
  expect_identical(plan$collectible, c(FALSE, TRUE, TRUE))
})

test_that("selecting a nested path by its complete path is skipped cleanly", {
  path <- ext("name_collision.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  expect_message(result <- collect(file, columns = "s.b"), "Skipping 1 nested")
  expect_identical(ncol(result), 0L)
  expect_identical(nrow(result), 3L)
})

test_that("all three read APIs agree on the colliding file", {
  path <- ext("name_collision.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  eager <- suppressMessages(read_parquet(path))
  collected <- suppressMessages(collect(file))
  batches <- list()
  suppressMessages(
    walk_batches(file, function(batch, index) batches[[index]] <<- batch)
  )
  expect_identical(collected, eager)
  expect_identical(do.call(rbind, batches), eager)
})
