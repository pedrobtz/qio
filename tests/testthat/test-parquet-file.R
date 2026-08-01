fixture_path <- function() test_path("parquet", "qio-multigroup.parquet")

fixture_data <- function() {
  data.frame(
    id = 1:12,
    count = 10000000000 + 1:12,
    ratio = as.double(as.single(1:12 / 10)),
    price = c(1.25, 2.5, NA, 5, 6.25, 7.5, 8.75, NA, 11.25, 12.5, 13.75, 15),
    label = c(
      "one",
      "two",
      "three",
      "four",
      NA,
      "six",
      "seven",
      "eight",
      "nine",
      "ten",
      "eleven",
      "twelve"
    ),
    active = rep(c(TRUE, FALSE), 6)
  )
}

local_parquet_file <- function(path = fixture_path(), ...) {
  file <- parquet_open(path, ...)
  withr::defer(parquet_close(file), envir = parent.frame())
  file
}

test_that("parquet_open() creates an inspectable handle", {
  file <- local_parquet_file()

  expect_s3_class(file, "qio_parquet_file")
  expect_equal(dim(file), c(12, 6))
  expect_equal(nrow(file), 12)
  expect_equal(ncol(file), 6)
  expect_identical(
    names(file),
    c("id", "count", "ratio", "price", "label", "active")
  )

  output <- capture.output(print(file))
  expect_match(output[[1]], "<qio_parquet_file>", fixed = TRUE)
  expect_match(output[[3]], "12 rows x 6 columns; 4 row groups", fixed = TRUE)
})

test_that("schema() describes every physical leaf", {
  file <- local_parquet_file()
  result <- schema(file)

  expect_identical(
    names(result),
    c(
      "column",
      "name",
      "path",
      "physical_type",
      "logical_type",
      "logical_details",
      "repetition",
      "type_length",
      "max_definition_level",
      "max_repetition_level"
    )
  )
  expect_equal(result$column, 1:6)
  expect_identical(result$path, names(file))
  expect_identical(
    result$physical_type,
    c("INT32", "INT64", "FLOAT", "DOUBLE", "BYTE_ARRAY", "BOOLEAN")
  )
  expect_identical(result$logical_type, c(NA, NA, NA, NA, "STRING", NA))
  expect_identical(
    result$repetition,
    c("REQUIRED", "REQUIRED", "REQUIRED", "OPTIONAL", "OPTIONAL", "REQUIRED")
  )
  expect_equal(result$max_definition_level, c(0L, 0L, 0L, 1L, 1L, 0L))
  expect_equal(result$max_repetition_level, rep(0L, 6))
})

test_that("row-group and footer metadata are preserved", {
  file <- local_parquet_file()

  groups <- row_groups(file)
  expect_equal(groups$row_group, 1:4)
  expect_equal(groups$rows, rep(3, 4))
  expect_true(all(groups$compressed_bytes > 0))
  expect_true(all(groups$uncompressed_bytes > 0))

  footer <- metadata(file)
  expect_identical(footer$key, c("qio.note", "qio.note", "qio.fixture"))
  expect_identical(footer$value, c("first", "second", "multigroup"))
})

test_that("collect() reads supported physical types and nulls", {
  file <- local_parquet_file()
  expected <- fixture_data()

  expect_equal(collect(file), expected, tolerance = 1e-7)
  expect_equal(collect(file, batch_size = 1), expected, tolerance = 1e-7)
  expect_equal(collect(file, batch_size = 1000), expected, tolerance = 1e-7)
})

test_that("collect() with mmap decodes columns in parallel and matches serial", {
  expected <- fixture_data()
  # threads = 0 (auto): numeric columns decode on carquet's worker pool, the
  # string column on the main thread; 4 row groups x 5 numeric columns keeps
  # the pool genuinely busy. Nulls in price/label cover the def-level path.
  parallel <- local_parquet_file(mmap = TRUE)
  expect_equal(collect(parallel), expected, tolerance = 1e-7)
  serial <- local_parquet_file(mmap = TRUE, threads = 1)
  expect_equal(collect(serial), expected, tolerance = 1e-7)
  expect_identical(collect(parallel), collect(serial))
})

test_that("collect() places null offsets correctly across partial-page reads", {
  # Regression guard for the incremental dense-value cursor in carquet's page
  # reader: when one page is consumed over many partial reads, present values
  # must land at the right dense offset no matter where nulls fall. Nulls are
  # placed at leading, trailing, and consecutive positions to catch off-by-one
  # errors in the running count. Also guards against the snappy scalar-decode
  # corruption (fixed in compression/snappy.c): its incremental_copy used
  # 16-byte block copies for match distances of 8..15 bytes, reading the
  # not-yet-written destination — benign where snappy uses NEON/SSSE3 (arm64,
  # SSSE3 x86) but garbage on the pure-scalar fallback (default-flags x86-64).
  # The columns below are snappy-compressed by default, so this exercises it.
  n <- 300L
  x <- seq_len(n)
  drop_in <- function(v) {
    v[c(1L, 2L, 3L, 150L, 151L, 299L, n)] <- NA
    v
  }
  expected <- data.frame(
    dense = as.double(x), # no nulls (control column)
    nums = drop_in(as.double(x) + 0.5), # nullable double
    ints = drop_in(x), # nullable int32
    labels = drop_in(sprintf("v%03d", x)), # nullable string
    stringsAsFactors = FALSE
  )
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(expected, path)

  file <- local_parquet_file(path)
  expect_equal(collect(file), expected, tolerance = 1e-7)
  # Batch sizes that do not divide n force partial reads at shifting offsets.
  for (bs in c(1L, 7L, 64L, 299L)) {
    expect_equal(
      collect(file, batch_size = bs),
      expected,
      tolerance = 1e-7,
      info = paste("batch_size =", bs)
    )
  }
})

test_that("collect() projects columns and selects row groups", {
  file <- local_parquet_file()
  expected <- fixture_data()

  expect_equal(
    collect(file, columns = c("price", "id")),
    expected[c("price", "id")]
  )
  expect_equal(
    collect(file, row_groups = 2),
    expected[4:6, ],
    ignore_attr = "row.names",
    tolerance = 1e-7
  )
  expect_equal(
    collect(file, columns = c("id", "price"), row_groups = c(4, 2)),
    expected[c(4:6, 10:12), c("id", "price")],
    ignore_attr = "row.names"
  )

  no_columns <- collect(file, columns = character())
  expect_s3_class(no_columns, "data.frame")
  expect_equal(dim(no_columns), c(12, 0))

  no_groups <- collect(file, row_groups = integer())
  expect_equal(dim(no_groups), c(0, 6))
  expect_identical(names(no_groups), names(file))
})

test_that("walk_batches() yields independent projected batches", {
  file <- local_parquet_file()
  batches <- list()
  indices <- integer()

  result <- withVisible(walk_batches(
    file,
    function(batch, index, prefix) {
      batches[[index]] <<- batch
      indices[[index]] <<- index
      paste0(prefix, index)
    },
    prefix = "batch-",
    columns = c("id", "price"),
    row_groups = c(4, 2),
    batch_size = 2
  ))

  expect_false(result$visible)
  expect_identical(result$value, file)
  expect_identical(indices, 1:4)
  expect_equal(vapply(batches, nrow, integer(1)), c(2L, 1L, 2L, 1L))
  expect_equal(
    do.call(rbind, batches),
    fixture_data()[c(4:6, 10:12), c("id", "price")],
    ignore_attr = "row.names"
  )

  batches[[1]]$id[[1]] <- -1L
  expect_equal(batches[[2]]$id, 6L)
})

test_that("walk_batches() handles empty projections and selections", {
  file <- local_parquet_file()
  dimensions <- list()

  walk_batches(
    file,
    function(batch, index) dimensions[[index]] <<- dim(batch),
    columns = character(),
    batch_size = 2
  )
  expect_equal(dimensions, rep(list(c(2L, 0L), c(1L, 0L)), 4))

  called <- FALSE
  walk_batches(
    file,
    function(batch, index) called <<- TRUE,
    row_groups = integer()
  )
  expect_false(called)
})

test_that("callback errors release native batch state", {
  file <- local_parquet_file()

  expect_error(
    walk_batches(file, function(batch, index) stop("callback failed")),
    "callback failed",
    fixed = TRUE
  )
  expect_equal(collect(file, columns = "id")$id, 1:12)
})

test_that("active reads reject reentrant operations", {
  file <- local_parquet_file()
  messages <- character()
  seen_metadata <- FALSE

  walk_batches(
    file,
    function(batch, index) {
      if (index != 1L) {
        return()
      }
      messages[[1]] <<- conditionMessage(tryCatch(
        collect(file),
        error = identity
      ))
      messages[[2]] <<- conditionMessage(tryCatch(
        parquet_close(file),
        error = identity
      ))
      seen_metadata <<- identical(metadata(file)$key[[1]], "qio.note")
    },
    columns = "id"
  )

  expect_match(messages[[1]], "already has an active read", fixed = TRUE)
  expect_match(messages[[2]], "during an active read", fixed = TRUE)
  expect_true(seen_metadata)
  expect_equal(collect(file, columns = "id")$id, 1:12)
})

test_that("selectors and options are validated", {
  file <- local_parquet_file()

  expect_error(collect(file, columns = "missing"), "unknown parquet column")
  expect_error(collect(file, columns = c("id", "id")), "duplicates")
  expect_error(collect(file, row_groups = 5), "out of range")
  expect_error(collect(file, row_groups = c(1, 1)), "duplicates")
  expect_error(collect(file, batch_size = 0), "whole number")

  expect_error(parquet_open(fixture_path(), mmap = NA), "mmap")
  expect_error(
    parquet_open(fixture_path(), verify_checksums = 1),
    "verify_checksums"
  )
  expect_error(parquet_open(fixture_path(), threads = -1), "threads")
  expect_error(parquet_open("does-not-exist.parquet"), "does not exist")
})

test_that("closed, serialized, and foreign handles are rejected", {
  file <- parquet_open(fixture_path())
  serialized <- unserialize(serialize(file, NULL))
  foreign <- structure(new("externalptr"), class = "qio_parquet_file")

  expect_invisible(parquet_close(file))
  expect_invisible(parquet_close(file))
  expect_match(capture.output(print(file))[[1]], "[closed]", fixed = TRUE)
  expect_error(dim(file), "closed or invalid")
  expect_error(dim(serialized), "closed or invalid")
  expect_error(dim(foreign), "not a qio parquet file handle")
})

test_that("mmap and explicit thread options can read a file", {
  file <- local_parquet_file(mmap = TRUE, threads = 1)
  expect_equal(collect(file, columns = "id")$id, 1:12)
})

# --- Phase P: native glue preflight ----------------------------------------

test_that("an INT32 sentinel value is reported, not silently dropped", {
  # -2147483648 is a legal Parquet INT32 but is R's NA_integer_. qio cannot
  # write it from an integer vector, so route it through a DATE column, whose
  # validated range includes INT_MIN. See .agents/TYPES.md.
  path <- withr::local_tempfile(fileext = ".parquet")
  schema <- parquet_schema(d = list(type = "DATE"))
  write_parquet(data.frame(d = c(-2147483648, -1, 0, 1)), path, schema = schema)

  expect_warning(result <- read_parquet(path), "reserves -2147483648")
  expect_true(is.na(result$d[[1]]))
  expect_equal(as.integer(unclass(result$d))[2:4], c(-1L, 0L, 1L))

  file <- local_parquet_file(path)
  expect_warning(collect(file), "reserves -2147483648")
  expect_warning(
    walk_batches(file, function(batch, index) invisible(NULL)),
    "reserves -2147483648"
  )
})

test_that("the sentinel warning is emitted once per read, not per value", {
  path <- withr::local_tempfile(fileext = ".parquet")
  schema <- parquet_schema(d = list(type = "DATE"))
  write_parquet(data.frame(d = rep(-2147483648, 20)), path, schema = schema)

  warnings <- character()
  withCallingHandlers(
    read_parquet(path),
    warning = function(w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  expect_length(warnings, 1L)
})

test_that("reads without a sentinel value do not warn", {
  file <- local_parquet_file()
  expect_no_warning(collect(file))
})

test_that("collect() and walk_batches() reject a non-positive batch size", {
  file <- local_parquet_file()
  expect_error(collect(file, batch_size = 0L), "batch_size")
  expect_error(
    walk_batches(file, function(batch, index) NULL, batch_size = 0L),
    "batch_size"
  )
})

test_that("a callback error does not deparse the whole batch", {
  file <- local_parquet_file()
  condition <- tryCatch(
    walk_batches(file, function(batch, index) stop("boom")),
    error = function(e) e
  )
  # The call carries argument symbols, not the materialized data frame.
  expect_lt(
    nchar(paste(deparse(conditionCall(condition)), collapse = "")),
    200L
  )
})

test_that("schema() reports every leaf of a wide file", {
  path <- withr::local_tempfile(fileext = ".parquet")
  wide <- as.data.frame(matrix(1L, nrow = 2L, ncol = 200L))
  write_parquet(wide, path)

  file <- local_parquet_file(path)
  result <- schema(file)
  expect_identical(nrow(result), 200L)
  expect_identical(result$column, seq_len(200L))
  expect_identical(result$name, names(wide))
})
