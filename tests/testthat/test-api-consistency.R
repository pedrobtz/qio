# Cross-cutting contract: one name per concept across every public result frame.
#
# This has no single owning R file, which is exactly why it drifted. Before
# these tests, the same Parquet physical type was `physical_type` in schema(),
# `type` in column_chunks(), and `parquet_type` in parquet_type_mapping(); the
# R type was `r_type` in read_plan() and `read_as` in parquet_type_mapping();
# and `name` meant the bare leaf name in schema() but the complete dotted path
# in the three inspection frames. Each function was internally consistent, so
# nothing failed.
#
# Two kinds of test are here deliberately. The literal-name assertions are a
# change detector: adding or renaming a public result column has to be a
# conscious edit here. The vocabulary assertions are the actual rule, and would
# catch a new function introduced with a fresh spelling.

nested_file <- function() {
  file <- open_parquet(test_path("parquet", "nested_maps.snappy.parquet"))
  withr::defer(close_parquet(file), envir = parent.frame())
  file
}

indexed_file <- function() {
  # Written by Arrow, so it carries a page index and bloom filters; qio's
  # writer emits neither.
  file <- open_parquet(test_path("parquet", "bloom_sorted.parquet"))
  withr::defer(close_parquet(file), envir = parent.frame())
  file
}

test_that("public result frames have exactly the documented columns", {
  file <- indexed_file()

  expect_identical(
    names(schema(file)),
    c(
      "column",
      "name",
      "path",
      "physical_type",
      "logical_type",
      "logical_details",
      "repetition_type",
      "type_length",
      "max_definition_level",
      "max_repetition_level"
    )
  )
  expect_identical(
    names(column_chunks(file)),
    c(
      "row_group",
      "column",
      "path",
      "physical_type",
      "compression",
      "num_values",
      "compressed_bytes",
      "uncompressed_bytes",
      "encodings",
      "dictionary_page",
      "bloom_filter",
      "page_index"
    )
  )
  expect_identical(
    names(column_statistics(file)),
    c(
      "row_group",
      "column",
      "path",
      "num_values",
      "null_count",
      "distinct_count",
      "min",
      "max"
    )
  )
  expect_identical(
    names(read_plan(file)),
    c(
      "column",
      "name",
      "path",
      "physical_type",
      "logical_type",
      "r_type",
      "converter",
      "nullable",
      "nested",
      "collectible",
      "note"
    )
  )
  expect_identical(
    names(parquet_type_mapping()),
    c("physical_type", "r_type", "written_from")
  )
})

test_that("a column is identified by `path` in every frame that names one", {
  # The rule, rather than a list: any public frame carrying a column
  # identifier calls it `path`, and its values come from schema()$path.
  file <- indexed_file()
  paths <- schema(file)$path

  frames <- list(
    schema = schema(file),
    read_plan = read_plan(file),
    column_chunks = column_chunks(file),
    column_statistics = column_statistics(file),
    page_index = page_index(file)
  )

  for (name in names(frames)) {
    frame <- frames[[name]]
    expect_true("path" %in% names(frame), info = name)
    expect_false("column_name" %in% names(frame), info = name)
    expect_true(all(frame$path %in% paths), info = name)
  }

  # page_index() must actually have rows, or the loop above proves nothing
  # about it.
  expect_gt(nrow(frames$page_index), 0L)
})

test_that("`name` is the leaf name and `path` is unique, on a nested file", {
  # The trap the rename removed: both columns existed, both were plausible,
  # and only one identifies a column. A map's key/value leaves collide.
  file <- nested_file()
  info <- schema(file)

  expect_false(identical(info$name, info$path))
  expect_gt(anyDuplicated(info$name), 0L)
  expect_identical(anyDuplicated(info$path), 0L)

  # The inspection frames report the path. A flat leaf's path equals its name,
  # so the check has to be against the leaves where the two actually differ.
  nested <- info$path[info$name != info$path]
  expect_gt(length(nested), 0L)
  chunks <- column_chunks(file)
  expect_true(all(chunks$path %in% info$path))
  expect_true(all(nested %in% chunks$path))
  # None of the colliding bare names leaks through as an identifier.
  colliding <- info$name[duplicated(info$name)]
  expect_false(any(chunks$path %in% colliding))

  # names() agrees with path, which is what selection accepts.
  expect_identical(names(file), info$path)
})

test_that("physical_type uses one vocabulary wherever it appears", {
  file <- indexed_file()
  known <- parquet_type_mapping()$physical_type

  expect_true(all(schema(file)$physical_type %in% known))
  expect_true(all(read_plan(file)$physical_type %in% known))
  expect_true(all(column_chunks(file)$physical_type %in% known))
})

test_that("r_type uses one vocabulary wherever it appears", {
  # read_plan() resolves annotations and so produces more types than the
  # physical fallbacks, but every fallback must be a value read_plan() could
  # itself report -- otherwise the two tables describe different things.
  fallbacks <- stats::na.omit(parquet_type_mapping()$r_type)
  produced <- unique(c(
    read_plan(test_path("parquet", "all_types.parquet"))$r_type,
    read_plan(test_path("parquet", "binary_types.parquet"))$r_type
  ))
  expect_true(all(fallbacks %in% produced))
})

test_that("repetition_type is spelled the same reading and writing", {
  # parquet_schema() takes `repetition_type`; schema() reported `repetition`.
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(
    data.frame(a = 1:3),
    path,
    schema = parquet_schema(
      a = list(type = "INT32", repetition_type = "REQUIRED")
    )
  )

  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  expect_identical(schema(file)$repetition_type, "REQUIRED")
})

test_that("bloom_filter_may_contain() selects by path like every other reader", {
  # Documented as "a column name, as schema() reports it", which was ambiguous
  # between the two columns schema() reports. It matches names(), i.e. path.
  file <- indexed_file()
  path <- schema(file)$path[[1L]]

  expect_type(bloom_filter_may_contain(file, path, 0), "logical")
  expect_error(bloom_filter_may_contain(file, "no_such_column", 0))
})
