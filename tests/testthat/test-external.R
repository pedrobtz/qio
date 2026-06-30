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
    "alltypes_plain.parquet", "alltypes_plain.snappy.parquet",
    "alltypes_dictionary.parquet", "int96_from_spark.parquet",
    "datapage_v2.snappy.parquet", "nested_maps.snappy.parquet",
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

# --- INT96 timestamps: not yet supported -----------------------------------
# alltypes_* carry an INT96 `timestamp_col`; int96_from_spark is all-INT96.
test_that("INT96 timestamp columns are rejected with a clear error", {
  for (f in c("alltypes_plain.parquet", "alltypes_plain.snappy.parquet",
              "alltypes_dictionary.parquet", "int96_from_spark.parquet")) {
    expect_error(read_parquet(ext(f)), "unsupported physical type", info = f)
  }
})

# --- DATA_PAGE_V2 with delta encodings: not yet readable --------------------
test_that("DATA_PAGE_V2 delta-encoded file is not yet readable", {
  expect_error(read_parquet(ext("datapage_v2.snappy.parquet")), "qio:")
})

# --- Nested map/list columns: not yet readable ------------------------------
test_that("nested map/list columns are not yet readable", {
  for (f in c("nested_maps.snappy.parquet", "nullable.impala.parquet")) {
    expect_error(read_parquet(ext(f)), "qio:", info = f)
  }
})
