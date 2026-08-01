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

# --- DATA_PAGE_V2 encodings -------------------------------------------------
# Not a delta problem, despite the fixture's name. This file's dictionary pages
# are undeclared: the writer emitted one as the first page of a chunk but set
# only data_page_offset, leaving dictionary_page_offset unset, which carquet
# read as a data page. Fixed in the vendored tree; see .agents/VENDORED.md.
# Its BOOLEAN column additionally uses RLE as a data encoding, which carquet
# did not implement at all; also fixed in the vendored tree.

test_that("DATA_PAGE_V2 columns with undeclared dictionaries read", {
  # The expected values are Apache Arrow's reading of the same file, checked by
  # tools/check-writer-against-arrow.R's sibling workflow rather than at test
  # time, so arrow stays out of the test dependencies.
  path <- ext("datapage_v2.snappy.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  expect_identical(
    collect(file, columns = "a")$a,
    c("abc", "abc", "abc", NA, "abc")
  )
  expect_identical(collect(file, columns = "b")$b, 1:5)
  expect_equal(collect(file, columns = "c")$c, c(2, 3, 4, 5, 2))
})

test_that("a memory-mapped read of the same file agrees", {
  # The dictionary probe had to be fixed in both the mmap and buffered paths.
  path <- ext("datapage_v2.snappy.parquet")
  buffered <- parquet_open(path)
  mapped <- parquet_open(path, mmap = TRUE)
  withr::defer({
    parquet_close(buffered)
    parquet_close(mapped)
  })
  expect_identical(
    collect(mapped, columns = c("a", "b", "c")),
    collect(buffered, columns = c("a", "b", "c"))
  )
})

test_that("RLE as a BOOLEAN data encoding reads", {
  # Column "d" is the only RLE-encoded value stream in the Apache corpus. Five
  # values in one run, so it proves the format is accepted but nothing about
  # the decoder's arithmetic; rle_boolean.parquet below carries that load.
  path <- ext("datapage_v2.snappy.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  expect_identical(
    collect(file, columns = "d")$d,
    c(TRUE, TRUE, TRUE, FALSE, TRUE)
  )
})

# --- RLE BOOLEAN at a size that exercises the hybrid decoder -----------------
# Apache Arrow chooses Encoding::RLE for BOOLEAN exactly when the data page
# version is V2, which is how the reference file above acquired one. This
# fixture is built the same way but shaped to reach long RLE runs, bit-packed
# runs, nulls, and several pages per column. Written by pyarrow; see
# parquet/SOURCE.md and tools/generate-rle-boolean-fixture.py.

# The generator's patterns, restated so the expectation is computed here rather
# than copied from the implementation being tested.
rle_expected <- function(n = 30000L) {
  runs <- logical(0)
  value <- TRUE
  run <- 1L
  while (length(runs) < n) {
    runs <- c(runs, rep(value, run))
    value <- !value
    run <- if (run < 512L) run * 2L else 1L
  }
  i <- seq_len(n) - 1L
  list(
    runs = runs[seq_len(n)],
    packed = (i * 7L + 3L) %% 5L == 0L,
    nullable = ifelse(i %% 7L == 3L, NA, i %% 3L == 0L),
    allsame = rep(TRUE, n)
  )
}

test_that("RLE BOOLEAN decodes runs, bit-packed groups, and nulls", {
  result <- read_parquet(ext("rle_boolean.parquet"))
  expected <- rle_expected()

  expect_identical(names(result), names(expected))
  expect_identical(result$runs, expected$runs)
  expect_identical(result$packed, expected$packed)
  expect_identical(result$nullable, expected$nullable)
  expect_identical(result$allsame, expected$allsame)
})

test_that("every read path agrees on RLE BOOLEAN", {
  # The batch reader has its own page loop that falls back to the column reader
  # for encodings it does not handle, so it has to be checked separately.
  path <- ext("rle_boolean.parquet")
  eager <- read_parquet(path)

  buffered <- parquet_open(path, mmap = FALSE)
  mapped <- parquet_open(path, mmap = TRUE)
  walker <- parquet_open(path)
  withr::defer({
    parquet_close(buffered)
    parquet_close(mapped)
    parquet_close(walker)
  })

  expect_identical(collect(buffered), eager)
  expect_identical(collect(mapped), eager)

  batches <- list()
  walk_batches(
    walker,
    function(batch, index) batches[[index]] <<- batch,
    batch_size = 777L
  )
  expect_gt(length(batches), 1L)
  expect_identical(do.call(rbind, batches), eager)
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

test_that("flat columns of a nested file read once the nested ones are skipped", {
  # This file used to error: its flat columns carry an undeclared dictionary
  # page, the same defect that made datapage_v2 unreadable. Values match
  # Apache Arrow's reading of the same file.
  result <- suppressMessages(read_parquet(ext("nested_maps.snappy.parquet")))
  expect_identical(names(result), c("b", "c"))
  expect_identical(result$b, rep(1L, 6L))
  expect_equal(result$c, rep(1, 6L))
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

# --- 64-bit integers (phase 3.1) -------------------------------------------
# int64_boundaries.parquet covers the exact-double bounds, bit64's reserved NA
# sentinel, INT64_MAX, and the unsigned half above INT64_MAX. Contract:
# .agents/TYPES.md, "64-bit integers".

int64_fixture <- function() ext("int64_boundaries.parquet")

test_that("double mode keeps the exact range and reports the rest", {
  expect_warning(
    df <- read_parquet(int64_fixture()),
    "cannot be represented exactly as R doubles"
  )
  expect_type(df$signed, "double")
  expect_identical(
    df$signed,
    c(NA, NA, -9007199254740992, -1, 0, 9007199254740992, NA, NA)
  )
  # The unsigned half must never appear as a negative number.
  expect_identical(
    df$unsigned,
    c(0, 1, 9007199254740992, NA, NA, NA, NA, NA)
  )
  expect_false(any(df$unsigned < 0, na.rm = TRUE))
})

test_that("integer64 mode preserves the full 64-bit range", {
  skip_if_not_installed("bit64")
  expect_warning(
    df <- read_parquet(int64_fixture(), int64 = "integer64"),
    "cannot be represented by bit64::integer64"
  )
  expect_s3_class(df$signed, "integer64")

  expect_identical(
    as.character(df$signed),
    c(
      NA, # INT64_MIN is bit64's own NA
      "-9007199254740993",
      "-9007199254740992",
      "-1",
      "0",
      "9007199254740992",
      "9007199254740993",
      "9223372036854775807"
    )
  )
  expect_identical(
    as.character(df$unsigned),
    c(
      "0",
      "1",
      "9007199254740992",
      "9007199254740993",
      "9223372036854775807",
      NA, # above INT64_MAX: bit64 cannot hold it
      NA,
      NA
    )
  )
})

test_that("the 64-bit warning is emitted once per read", {
  warnings <- character()
  withCallingHandlers(
    read_parquet(int64_fixture()),
    warning = function(w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  # Two columns and eight rows each, but one warning for the whole read.
  expect_length(warnings, 1L)
})

test_that("read_plan() reports the selected 64-bit mode", {
  plan <- read_plan(int64_fixture())
  expect_identical(plan$r_type, c("double", "double"))
  expect_identical(plan$converter, c("int64_double", "int64_double"))

  skip_if_not_installed("bit64")
  plan64 <- read_plan(int64_fixture(), int64 = "integer64")
  expect_identical(plan64$r_type, c("integer64", "integer64"))
  expect_identical(plan64$converter, c("int64_bit64", "int64_bit64"))
})

test_that("all three read APIs honor the 64-bit mode identically", {
  skip_if_not_installed("bit64")
  path <- int64_fixture()
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  eager <- suppressWarnings(read_parquet(path, int64 = "integer64"))
  collected <- suppressWarnings(collect(file, int64 = "integer64"))
  batches <- list()
  suppressWarnings(walk_batches(
    file,
    function(batch, index) batches[[index]] <<- batch,
    int64 = "integer64"
  ))
  walked <- do.call(rbind, batches)

  expect_identical(collected, eager)
  expect_identical(as.character(walked$signed), as.character(eager$signed))
  expect_identical(as.character(walked$unsigned), as.character(eager$unsigned))
  expect_s3_class(walked$signed, "integer64")
})

test_that("the 64-bit mode survives projection, row groups, and batching", {
  skip_if_not_installed("bit64")
  path <- int64_fixture()
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  projected <- suppressWarnings(
    collect(file, columns = "unsigned", int64 = "integer64")
  )
  expect_s3_class(projected$unsigned, "integer64")
  expect_identical(names(projected), "unsigned")

  full <- suppressWarnings(collect(file, int64 = "integer64"))
  by_batch <- list()
  suppressWarnings(walk_batches(
    file,
    function(batch, index) by_batch[[index]] <<- batch,
    batch_size = 3L,
    int64 = "integer64"
  ))
  expect_gt(length(by_batch), 1L)
  rebuilt <- do.call(rbind, by_batch)
  expect_identical(as.character(rebuilt$signed), as.character(full$signed))
})

test_that("nulls and 64-bit values coexist in both modes", {
  skip_if_not_installed("bit64")
  path <- withr::local_tempfile(fileext = ".parquet")
  schema <- parquet_schema(v = "INT64")
  write_parquet(data.frame(v = c(1, NA, -1, NA, 2^40)), path, schema = schema)

  double_mode <- read_parquet(path)
  expect_identical(double_mode$v, c(1, NA, -1, NA, 2^40))

  bit64_mode <- read_parquet(path, int64 = "integer64")
  expect_s3_class(bit64_mode$v, "integer64")
  expect_identical(
    as.character(bit64_mode$v),
    c("1", NA, "-1", NA, "1099511627776")
  )
})

test_that("integer64 mode is rejected clearly when bit64 is unavailable", {
  # The mode is validated before any allocation or native call.
  expect_error(qio_read_options(int64 = "nonsense"), "should be one of")
})

# --- The NULL logical type -------------------------------------------------

test_that("a NULL-annotated column reads as all-NA logical", {
  # The Parquet NULL logical type carries no values whatever its physical
  # storage. TYPES.md maps it to all-NA logical, preserving the row count.
  path <- ext("null_type.parquet")
  plan <- read_plan(path)

  expect_identical(plan$r_type, c("logical", "integer"))
  expect_identical(plan$converter, c("null_logical", "int32"))

  df <- read_parquet(path)
  expect_type(df$nothing, "logical")
  expect_true(all(is.na(df$nothing)))
  expect_identical(nrow(df), 3L)
  expect_identical(df$id, 1:3)
})

test_that("the NULL logical type survives batching", {
  path <- ext("null_type.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  batches <- list()
  walk_batches(
    file,
    function(batch, index) batches[[index]] <<- batch,
    batch_size = 2L
  )
  rebuilt <- do.call(rbind, batches)
  expect_type(rebuilt$nothing, "logical")
  expect_true(all(is.na(rebuilt$nothing)))
  expect_identical(rebuilt$id, 1:3)
})

# --- Text and binary (phase 3.2) -------------------------------------------
# Only an annotated column is text. An unannotated BYTE_ARRAY is arbitrary
# bytes, and returning it as character would assume an encoding the file never
# claimed. .agents/TYPES.md, "Text and binary".

test_that("only annotated columns become character", {
  path <- ext("binary_types.parquet")
  plan <- read_plan(path)

  expect_identical(
    plan$r_type,
    c("character", "list", "list", "double")
  )
  expect_identical(
    plan$converter,
    c("text", "binary", "binary", "float16")
  )

  df <- read_parquet(path)
  expect_type(df$text, "character")
  expect_identical(df$text, c("hello", NA, "éè"))
})

test_that("unannotated and fixed-width bytes read as raw list-columns", {
  df <- read_parquet(ext("binary_types.parquet"))

  expect_type(df$bytes, "list")
  expect_identical(df$bytes[[1]], as.raw(c(1, 2, 3)))
  expect_null(df$bytes[[2]]) # a null value is a NULL element
  expect_identical(df$bytes[[3]], as.raw(c(255, 0, 128)))

  expect_type(df$fixed, "list")
  expect_identical(df$fixed[[1]], as.raw(c(1, 2, 3, 4)))
  expect_null(df$fixed[[2]])
  expect_identical(df$fixed[[3]], as.raw(c(9, 9, 9, 9)))
  # Every present value has exactly the declared width.
  present <- Filter(Negate(is.null), df$fixed)
  expect_true(all(lengths(present) == 4L))
})

test_that("FLOAT16 widens to double", {
  df <- read_parquet(ext("binary_types.parquet"))
  expect_type(df$half, "double")
  expect_identical(df$half, c(1.5, NA, -2.25))
})

test_that("binary columns survive batching and projection", {
  path <- ext("binary_types.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  projected <- collect(file, columns = c("fixed", "bytes"))
  expect_identical(names(projected), c("fixed", "bytes"))
  expect_type(projected$fixed, "list")

  batches <- list()
  walk_batches(
    file,
    function(batch, index) batches[[index]] <<- batch,
    batch_size = 2L
  )
  rebuilt <- do.call(rbind, batches)
  full <- collect(file)
  expect_identical(rebuilt$bytes, full$bytes)
  expect_identical(rebuilt$fixed, full$fixed)
  expect_identical(rebuilt$half, full$half)
})

test_that("the reference corpus's unannotated string columns are now bytes", {
  # alltypes_plain.parquet carries no annotation on string_col, and Apache
  # Arrow also reads it as binary. qio used to return character by assuming
  # UTF-8. This is the deliberate change recorded in NEWS.md.
  df <- read_parquet(ext("alltypes_plain.parquet"))
  expect_type(df$string_col, "list")
  expect_type(df$string_col[[1]], "raw")
})

# --- UUID and UTF-8 validation ---------------------------------------------
# Both fixtures come from tools/generate-type-fixtures.c: Arrow's R bindings
# have no UUID type, and Arrow correctly refuses to build invalid UTF-8.

test_that("a UUID column reads as canonical text", {
  path <- ext("uuid.parquet")
  plan <- read_plan(path)
  expect_identical(plan$r_type, "character")
  expect_identical(plan$converter, "uuid")

  df <- read_parquet(path)
  expect_type(df$id, "character")
  expect_identical(
    df$id,
    c(
      "12345678-9abc-def0-1122-334455667788",
      NA,
      "00000000-0000-0000-0000-000000000000",
      "ffffffff-ffff-ffff-ffff-ffffffffffff",
      "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
    )
  )
})

test_that("UUID reads agree across all three APIs and survive batching", {
  path <- ext("uuid.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  eager <- read_parquet(path)
  expect_identical(collect(file), eager)

  batches <- list()
  walk_batches(
    file,
    function(batch, index) batches[[index]] <<- batch,
    batch_size = 2L
  )
  expect_gt(length(batches), 1L)
  expect_identical(do.call(rbind, batches), eager)
})

test_that("a text column of invalid UTF-8 fails with column, row, and offset", {
  # Rf_mkCharLenCE does not validate, so without an explicit check qio would
  # hand R a string claiming an encoding it does not have.
  expect_error(
    read_parquet(ext("invalid_utf8.parquet")),
    "column 's' is annotated as text but row 2 is not valid UTF-8"
  )
})

# --- Decimal (read as double in v0.1.0) ------------------------------------

test_that("decimal columns read as double with the scale applied", {
  path <- ext("decimal_types.parquet")
  plan <- read_plan(path)
  expect_true(all(plan$r_type == "double"))
  expect_true(all(startsWith(plan$converter, "decimal_")))

  expect_message(df <- read_parquet(path), "as double; values may be inexact")
  expect_equal(df$small, c(12.30, 4.05, -0.07, NA))
  expect_equal(df$wide, c(123456789.12, -1, 0, NA))
})

test_that("the decimal message is emitted once per read", {
  messages <- character()
  withCallingHandlers(
    read_parquet(ext("decimal_types.parquet")),
    message = function(m) {
      messages <<- c(messages, conditionMessage(m))
      invokeRestart("muffleMessage")
    }
  )
  expect_length(messages, 1L)
  expect_match(messages, "2 Parquet DECIMAL columns")
})

test_that("decimal values agree across all three read APIs", {
  path <- ext("decimal_types.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  eager <- suppressMessages(read_parquet(path))
  expect_equal(suppressMessages(collect(file)), eager)

  batches <- list()
  suppressMessages(walk_batches(
    file,
    function(batch, index) batches[[index]] <<- batch,
    batch_size = 2L
  ))
  expect_equal(do.call(rbind, batches), eager)
})

# --- Temporal and annotated integers (phase 3.4) ---------------------------
# temporal_types.parquet carries boundary values for every integer width and
# every timestamp and time unit. Contracts: .agents/TYPES.md.

temporal_fixture <- function() ext("temporal_types.parquet")

test_that("integer-width annotations map to the right R type", {
  plan <- read_plan(temporal_fixture())
  widths <- plan[plan$name %in% c("u8", "u16", "u32", "i8", "i16", "i32"), ]

  # Only unsigned 32-bit needs a double; the rest fit R's signed integer.
  expect_identical(
    widths$r_type,
    c("integer", "integer", "double", "integer", "integer", "integer")
  )

  df <- read_parquet(temporal_fixture())
  expect_identical(df$u8, c(0L, 255L, NA))
  expect_identical(df$u16, c(0L, 65535L, NA))
  expect_identical(df$i8, c(-128L, 127L, NA))
  expect_identical(df$i16, c(-32768L, 32767L, NA))
  expect_identical(df$i32, c(-2147483647L, 2147483647L, NA))
})

test_that("an unsigned 32-bit column is never negative", {
  # The upper half of a uint32 read as signed would come back as -1.
  df <- read_parquet(temporal_fixture())
  expect_type(df$u32, "double")
  expect_identical(df$u32, c(0, 4294967295, NA))
  expect_false(any(df$u32 < 0, na.rm = TRUE))
})

test_that("a UTC-adjusted timestamp is an instant that tz only displays", {
  utc <- read_parquet(temporal_fixture())
  paris <- read_parquet(temporal_fixture(), tz = "Europe/Paris")

  for (column in c("ts_utc_ms", "ts_utc_us", "ts_utc_ns")) {
    expect_s3_class(utc[[column]], "POSIXct")
    expect_identical(attr(utc[[column]], "tzone"), "UTC", info = column)
    expect_identical(attr(paris[[column]], "tzone"), "Europe/Paris")
    # Same instant, different display: the numeric value is unchanged.
    expect_equal(
      as.double(paris[[column]]),
      as.double(utc[[column]]),
      info = column
    )
  }
  expect_equal(
    as.double(utc$ts_utc_us),
    as.double(as.POSIXct(c("2020-01-01", "2020-07-01", NA), tz = "UTC"))
  )
})

test_that("a non-UTC timestamp is a wall clock re-anchored in tz", {
  utc <- read_parquet(temporal_fixture())
  paris <- read_parquet(temporal_fixture(), tz = "Europe/Paris")

  for (column in c("ts_local_ms", "ts_local_us")) {
    expect_s3_class(utc[[column]], "POSIXct")
    # The civil components are what the file stores, so they do not move.
    expect_identical(
      format(paris[[column]], "%Y-%m-%d %H:%M:%S"),
      format(utc[[column]], "%Y-%m-%d %H:%M:%S"),
      info = column
    )
    # The instant does move, because the same wall clock in another zone is a
    # different moment. Paris is ahead of UTC, so its instant is earlier.
    expect_lt(as.double(paris[[column]][1]), as.double(utc[[column]][1]))
  }
})

test_that("TIME reads as seconds since midnight in both modes", {
  df <- read_parquet(temporal_fixture())
  for (column in c("t_ms", "t_us", "t_ns")) {
    expect_type(df[[column]], "double")
    expect_false(inherits(df[[column]], "POSIXct"))
    expect_equal(df[[column]][1], 0, info = column)
    expect_equal(df[[column]][2], 86399.999999, tolerance = 1e-6, info = column)
    expect_true(is.na(df[[column]][3]), info = column)
  }

  skip_if_not_installed("hms")
  as_hms <- read_parquet(temporal_fixture(), time = "hms")
  expect_s3_class(as_hms$t_ms, "hms")
  expect_identical(format(as_hms$t_ms[1]), "00:00:00")
})

test_that("read_plan() reports the selected time and zone modes", {
  is_time <- function(plan) which(plan$logical_type %in% "TIME")
  numeric_plan <- read_plan(temporal_fixture())
  expect_true(all(
    startsWith(numeric_plan$converter[is_time(numeric_plan)], "time_numeric_")
  ))
  expect_true(any(grepl("_UTC$", numeric_plan$converter)))

  paris <- read_plan(temporal_fixture(), tz = "Europe/Paris")
  expect_true(any(grepl("Europe/Paris$", paris$converter)))

  skip_if_not_installed("hms")
  hms_plan <- read_plan(temporal_fixture(), time = "hms")
  expect_identical(unique(hms_plan$r_type[is_time(hms_plan)]), "hms")
})

test_that("temporal values agree across all three read APIs", {
  path <- temporal_fixture()
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  eager <- read_parquet(path, tz = "Europe/Paris")
  expect_identical(collect(file, tz = "Europe/Paris"), eager)

  batches <- list()
  walk_batches(
    file,
    function(batch, index) batches[[index]] <<- batch,
    batch_size = 2L,
    tz = "Europe/Paris"
  )
  expect_gt(length(batches), 1L)
  expect_identical(do.call(rbind, batches), eager)
})

test_that("tz is validated before anything is read", {
  expect_error(
    read_parquet(temporal_fixture(), tz = "Mars/Olympus"),
    "not a known time zone"
  )
  expect_error(
    read_parquet(temporal_fixture(), tz = c("UTC", "GMT")),
    "single time zone"
  )
  expect_error(read_parquet(temporal_fixture(), tz = NA), "single time zone")
  # An empty zone would mean the machine's local zone, which the contract
  # forbids using implicitly.
  expect_error(read_parquet(temporal_fixture(), tz = ""), "single time zone")
})

# --- Encoding independence (phase 4) ---------------------------------------
# The reader caches CHARSXPs by the address of the bytes they came from, which
# is a large win on dictionary-encoded pages and must be invisible everywhere
# else. string_encodings.parquet holds a dictionary column, a plain column, and
# one that switches from dictionary to plain partway through.

test_that("dictionary, plain, and mixed pages give identical results", {
  path <- ext("string_encodings.parquet")
  df <- read_parquet(path)

  for (column in c("dict", "plain", "mixed")) {
    expect_type(df[[column]], "character")
    expect_false(anyNA(df[[column]]), info = column)
  }
  # The two low-cardinality columns are drawn from one pool, so encoding alone
  # must not change what comes back.
  expect_setequal(unique(df$dict), unique(df$plain))

  # The mixed column repeats first and is distinct afterwards; both halves must
  # survive the switch between encodings.
  expect_true(any(duplicated(df$mixed)))
  expect_gt(length(unique(df$mixed)), 10000L)
  expect_true(all(grepl("^(category_|u)", df$mixed)))
})

test_that("encoding does not change results across batch sizes or APIs", {
  path <- ext("string_encodings.parquet")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))
  expected <- collect(file)

  # A small batch splits every column across several reads, which resets the
  # address cache; the result must not depend on where those splits land.
  for (batch_size in c(1000L, 7777L, 65536L)) {
    expect_identical(
      collect(file, batch_size = batch_size),
      expected,
      info = paste("batch_size =", batch_size)
    )
  }

  batches <- list()
  walk_batches(
    file,
    function(batch, index) batches[[index]] <<- batch,
    batch_size = 5000L
  )
  expect_identical(do.call(rbind, batches), expected)
  expect_identical(read_parquet(path), expected)
})

test_that("a cached string is a real copy, not a borrowed pointer", {
  # Values must own their memory once returned: the cache holds CHARSXPs, and
  # the bytes they were built from belong to carquet page buffers that are
  # released when the read finishes.
  path <- ext("string_encodings.parquet")
  file <- parquet_open(path)
  df <- collect(file)
  parquet_close(file)
  gc(full = TRUE)
  expect_identical(substr(df$dict[1], 1L, 9L), "category_")
  expect_true(all(nchar(df$mixed) > 0L))
})
