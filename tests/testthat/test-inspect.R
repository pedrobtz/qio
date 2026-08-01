# Phase 6: row groups, footer metadata, chunk and statistics inspection, and
# structural validation.

# --- Row-group boundaries ---------------------------------------------------
# Every qio file used to be a single row group, which left other readers
# nothing to skip. The writer now writes row-group-major so that columns reach
# a common row before a boundary, which is what carquet requires to close one.

test_that("row_group_size splits the file and preserves every value", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(
    n = 1:100,
    x = as.numeric(1:100) / 2,
    s = sprintf("v%03d", 1:100),
    stringsAsFactors = FALSE
  )
  data$n[5] <- NA

  write_parquet(data, path, row_group_size = 30)
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  groups <- row_groups(file)
  expect_identical(nrow(groups), 4L)
  expect_equal(groups$rows, c(30, 30, 30, 10))
  expect_equal(sum(groups$rows), 100)
  # The split must not disturb the data, at any batch size.
  expect_identical(collect(file), data)
  expect_identical(read_parquet(path), data)
})

test_that("row groups round-trip under every codec and across a chunk boundary", {
  skip_on_cran()
  # A group larger than QIO_WRITE_CHUNK exercises a boundary that falls inside
  # a group rather than between two.
  for (codec in c("snappy", "zstd", "uncompressed")) {
    path <- withr::local_tempfile(fileext = ".parquet")
    data <- data.frame(n = 1:1000, s = sprintf("v%04d", 1:1000))
    write_parquet(data, path, row_group_size = 256, compression = codec)
    file <- parquet_open(path)
    withr::defer(parquet_close(file))
    expect_identical(nrow(row_groups(file)), 4L, info = codec)
    expect_identical(collect(file), data, info = codec)
  }
})

test_that("the default is still one row group", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = 1:50), path)
  file <- parquet_open(path)
  withr::defer(parquet_close(file))
  expect_identical(nrow(row_groups(file)), 1L)
})

test_that("a group larger than the frame yields one group", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = 1:10), path, row_group_size = 1000)
  file <- parquet_open(path)
  withr::defer(parquet_close(file))
  expect_identical(nrow(row_groups(file)), 1L)
  expect_identical(collect(file)$n, 1:10)
})

test_that("a zero-row frame still writes with an explicit group size", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = integer()), path, row_group_size = 10)
  expect_identical(nrow(read_parquet(path)), 0L)
})

test_that("row_group_size rejects nonsense", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(n = 1:5)
  expect_error(write_parquet(data, path, row_group_size = 0), "positive")
  expect_error(write_parquet(data, path, row_group_size = -1), "positive")
  expect_error(write_parquet(data, path, row_group_size = NA), "positive")
  expect_error(write_parquet(data, path, row_group_size = c(1, 2)), "positive")
  expect_error(write_parquet(data, path, row_group_size = "10"), "positive")
})

# --- Writer key/value metadata ----------------------------------------------

test_that("footer metadata round-trips, duplicates and order included", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(
    data.frame(n = 1:3),
    path,
    metadata = c(source = "test", note = "first", note = "second")
  )
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  pairs <- metadata(file)
  written <- pairs[pairs$key %in% c("source", "note"), ]
  expect_identical(written$key, c("source", "note", "note"))
  expect_identical(written$value, c("test", "first", "second"))
})

test_that("an NA metadata value round-trips as NA", {
  path <- withr::local_tempfile(fileext = ".parquet")
  # Logical NA is how anyone writes "key with no value"; it must be accepted.
  write_parquet(data.frame(n = 1:3), path, metadata = c(empty = NA))
  file <- parquet_open(path)
  withr::defer(parquet_close(file))
  pairs <- metadata(file)
  expect_true(is.na(pairs$value[pairs$key == "empty"]))
})

test_that("metadata keys and values may be non-ASCII", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = 1:3), path, metadata = c("ключ" = "значение"))
  file <- parquet_open(path)
  withr::defer(parquet_close(file))
  pairs <- metadata(file)
  expect_identical(pairs$value[pairs$key == "ключ"], "значение")
})

test_that("metadata rejects anything unnamed", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(n = 1:3)
  expect_error(write_parquet(data, path, metadata = "x"), "named character")
  expect_error(
    write_parquet(data, path, metadata = c(a = 1)),
    "named character"
  )
  expect_error(
    write_parquet(data, path, metadata = c(a = "1", "2")),
    "non-empty"
  )
})

# --- Column chunks ----------------------------------------------------------

test_that("column_chunks() reports one row per column per row group", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(
    n = 1:60,
    x = as.numeric(1:60),
    s = sprintf("v%02d", 1:60),
    stringsAsFactors = FALSE
  )
  write_parquet(data, path, row_group_size = 20, compression = "zstd")
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  chunks <- column_chunks(file)
  expect_identical(nrow(chunks), 9L)
  expect_identical(sort(unique(chunks$row_group)), 1:3)
  expect_identical(unique(chunks$name), c("n", "x", "s"))
  expect_identical(unique(chunks$type), c("INT32", "DOUBLE", "BYTE_ARRAY"))
  expect_true(all(chunks$compression == "ZSTD"))
  expect_equal(sum(chunks$num_values[chunks$name == "n"]), 60)
  expect_true(all(nzchar(chunks$encodings)))
  expect_type(chunks$dictionary_page, "logical")
  expect_type(chunks$bloom_filter, "logical")
  expect_type(chunks$page_index, "logical")
})

test_that("column_chunks() sizes agree with the row-group totals", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(
    data.frame(n = 1:100, x = as.numeric(1:100)),
    path,
    row_group_size = 25
  )
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  chunks <- column_chunks(file)
  groups <- row_groups(file)
  per_group <- tapply(chunks$compressed_bytes, chunks$row_group, sum)
  expect_equal(as.numeric(per_group), groups$compressed_bytes)
})

# --- Column statistics ------------------------------------------------------

test_that("statistics report per-group bounds in the column's own type", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(
    n = 1:100,
    x = as.numeric(1:100) / 4,
    s = sprintf("v%03d", 1:100),
    b = rep(c(TRUE, FALSE), 50),
    stringsAsFactors = FALSE
  )
  write_parquet(data, path, row_group_size = 50)
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  stats <- column_statistics(file)
  expect_identical(nrow(stats), 8L)
  expect_equal(stats$num_values, rep(50, 8))

  first <- stats[stats$row_group == 1, ]
  expect_identical(first$min[[which(first$name == "n")]], 1L)
  expect_identical(first$max[[which(first$name == "n")]], 50L)
  expect_equal(first$min[[which(first$name == "x")]], 0.25)
  expect_equal(first$max[[which(first$name == "x")]], 12.5)
  expect_identical(first$min[[which(first$name == "s")]], "v001")
  expect_identical(first$max[[which(first$name == "s")]], "v050")
  expect_identical(first$min[[which(first$name == "b")]], FALSE)
  expect_identical(first$max[[which(first$name == "b")]], TRUE)

  second <- stats[stats$row_group == 2, ]
  expect_identical(second$min[[which(second$name == "n")]], 51L)
  expect_identical(second$max[[which(second$name == "s")]], "v100")
})

test_that("null counts are reported per row group", {
  path <- withr::local_tempfile(fileext = ".parquet")
  values <- 1:40
  values[c(1, 2, 21)] <- NA
  write_parquet(data.frame(n = values), path, row_group_size = 20)
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  stats <- column_statistics(file)
  expect_equal(stats$null_count, c(2, 1))
})

test_that("statistics decode third-party files, including boundary values", {
  # Written by Apache Arrow, so these bounds are bytes qio did not produce.
  # INT32 -2147483648 must not come back as NA: R reserves it, so the bound is
  # widened rather than lost.
  file <- parquet_open(test_path("parquet", "int32_min.parquet"))
  withr::defer(parquet_close(file))
  stats <- column_statistics(file)

  value <- stats[stats$name == "value", ]
  expect_equal(value$min[[1]], -2147483648)
  expect_equal(value$max[[1]], 2147483647)
  expect_false(is.na(value$min[[1]]))

  label <- stats[stats$name == "label", ]
  expect_identical(label$min[[1]], "max")
  expect_identical(label$max[[1]], "zero")
})

test_that("non-text byte columns give raw bounds, not character", {
  # binary_types.parquet holds an unannotated BYTE_ARRAY and a
  # FIXED_LEN_BYTE_ARRAY. Neither is text, so neither may claim to be.
  file <- parquet_open(test_path("parquet", "binary_types.parquet"))
  withr::defer(parquet_close(file))
  stats <- column_statistics(file)

  expect_type(stats$min[[which(stats$name == "bytes")]], "raw")
  expect_type(stats$min[[which(stats$name == "fixed")]], "raw")
  expect_type(stats$min[[which(stats$name == "text")]], "character")
})

test_that("a file without statistics reports NULL bounds, not an error", {
  # alltypes_plain.parquet predates statistics being written routinely.
  file <- parquet_open(test_path("parquet", "alltypes_plain.parquet"))
  withr::defer(parquet_close(file))
  stats <- column_statistics(file)
  expect_gt(nrow(stats), 0L)
  expect_true(all(vapply(stats$min, is.null, logical(1))))
})

# --- Structural validation --------------------------------------------------

test_that("parquet_validate() accepts a file qio wrote", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = 1:10), path, row_group_size = 3)
  expect_true(parquet_validate(path))
})

test_that("parquet_validate() accepts every third-party fixture", {
  for (name in c(
    "alltypes_plain.parquet",
    "datapage_v2.snappy.parquet",
    "nested_maps.snappy.parquet",
    "rle_boolean.parquet"
  )) {
    expect_true(parquet_validate(test_path("parquet", name)), info = name)
  }
})

test_that("parquet_validate() names the problem rather than the parser", {
  directory <- withr::local_tempdir()

  missing <- file.path(directory, "absent.parquet")
  expect_error(parquet_validate(missing), "does not exist")

  expect_error(parquet_validate(directory), "is a directory")

  tiny <- file.path(directory, "tiny.parquet")
  writeBin(as.raw(1:5), tiny)
  expect_error(parquet_validate(tiny), "too small")

  text <- file.path(directory, "text.parquet")
  writeLines("this file is definitely not parquet", text)
  expect_error(parquet_validate(text), "does not start with the Parquet marker")

  # Truncated: the leading marker survives, the trailing one does not.
  source <- file.path(directory, "good.parquet")
  write_parquet(data.frame(n = 1:100), source)
  bytes <- readBin(source, "raw", file.size(source))
  cut <- file.path(directory, "cut.parquet")
  writeBin(bytes[seq_len(length(bytes) - 40)], cut)
  expect_error(parquet_validate(cut), "truncated")
})

test_that("parquet_validate() reports an encrypted footer as such", {
  directory <- withr::local_tempdir()
  path <- file.path(directory, "encrypted.parquet")
  source <- file.path(directory, "good.parquet")
  write_parquet(data.frame(n = 1:10), source)
  bytes <- readBin(source, "raw", file.size(source))
  # PARE is the encrypted-footer marker; only the trailing one is read.
  bytes[seq(length(bytes) - 3, length(bytes))] <- charToRaw("PARE")
  writeBin(bytes, path)
  expect_error(parquet_validate(path), "encrypted footer")
})

test_that("parquet_validate() reports a corrupt footer as a footer problem", {
  directory <- withr::local_tempdir()
  source <- file.path(directory, "good.parquet")
  write_parquet(data.frame(n = 1:100, s = letters[1:10]), source)
  bytes <- readBin(source, "raw", file.size(source))
  # Keep both markers, destroy the footer between them.
  middle <- seq(length(bytes) - 60, length(bytes) - 9)
  bytes[middle] <- as.raw(0xff)
  path <- file.path(directory, "bad-footer.parquet")
  writeBin(bytes, path)
  expect_error(parquet_validate(path), "footer does not parse")
})

# --- Page indexes -----------------------------------------------------------
# A page index is optional and qio's writer emits none, so these read files
# written by Apache Arrow and pyarrow.

test_that("page_index() reports pages with locations and bounds", {
  file <- parquet_open(test_path("parquet", "bloom_sorted.parquet"))
  withr::defer(parquet_close(file))

  pages <- page_index(file)
  expect_gt(nrow(pages), 0L)
  expect_identical(
    names(pages),
    c(
      "row_group",
      "column",
      "name",
      "page",
      "first_row",
      "offset",
      "compressed_bytes",
      "null_count",
      "null_page",
      "min",
      "max"
    )
  )
  # Both indexes are present in this file, so nothing should be missing.
  expect_false(anyNA(pages$offset))
  expect_false(anyNA(pages$first_row))
  expect_false(anyNA(pages$null_count))
  # Pages are numbered from one within each chunk and start at row zero.
  expect_true(all(pages$page >= 1L))
  expect_true(all(pages$first_row[pages$page == 1L] == 0))
  # Offsets increase within a column chunk.
  key <- pages[pages$name == "key" & pages$row_group == 1L, ]
  expect_false(is.unsorted(key$offset))
})

test_that("page bounds decode in the column's own type", {
  file <- parquet_open(test_path("parquet", "bloom_sorted.parquet"))
  withr::defer(parquet_close(file))
  pages <- page_index(file)

  key <- pages[pages$name == "key", ]
  expect_true(all(vapply(key$min, is.numeric, logical(1))))
  # The fixture's key column is 0..3999 ascending, so the first page of the
  # first row group must start at zero.
  expect_equal(key$min[[1]], 0)

  label <- pages[pages$name == "label", ]
  expect_type(label$min[[1]], "character")
  expect_identical(label$min[[1]], "item-00000")
})

test_that("a file with no page index yields no rows, not an error", {
  # qio does not write page indexes; see ?qio-limitations.
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(n = 1:100), path, row_group_size = 25)
  file <- parquet_open(path)
  withr::defer(parquet_close(file))

  pages <- page_index(file)
  expect_identical(nrow(pages), 0L)
  expect_identical(ncol(pages), 11L)
})

# --- Bloom filters ----------------------------------------------------------

test_that("a bloom filter never misses a value that is present", {
  # The one guarantee a bloom filter makes: no false negatives. False
  # positives are permitted, so only this direction can be asserted per value.
  file <- parquet_open(test_path("parquet", "bloom_sorted.parquet"))
  withr::defer(parquet_close(file))

  # Row group 1 of the fixture holds keys 0..999 and matching labels.
  present <- c(0, 1, 500, 999)
  expect_true(all(bloom_filter_may_contain(file, "key", present)))
  expect_true(all(bloom_filter_may_contain(
    file,
    "label",
    sprintf("item-%05d", c(0, 1, 500, 999))
  )))

  # Row group 2 holds 1000..1999.
  expect_true(all(
    bloom_filter_may_contain(file, "key", c(1000, 1500, 1999), row_group = 2)
  ))
})

test_that("a bloom filter rules out values that are absent", {
  # Individually a FALSE is not guaranteed, so this asserts on the bulk: a
  # filter that answered TRUE to everything would be useless and must fail here.
  file <- parquet_open(test_path("parquet", "bloom_sorted.parquet"))
  withr::defer(parquet_close(file))

  absent <- seq(100000, 100999)
  ruled_out <- !bloom_filter_may_contain(file, "key", absent)
  expect_gt(mean(ruled_out), 0.9)

  absent_labels <- sprintf("absent-%05d", 1:500)
  expect_gt(mean(!bloom_filter_may_contain(file, "label", absent_labels)), 0.9)

  # Values in a different row group are absent from this one.
  expect_false(bloom_filter_may_contain(file, "key", 3500, row_group = 1))
})

test_that("bloom filter lookups validate their arguments", {
  file <- parquet_open(test_path("parquet", "bloom_sorted.parquet"))
  withr::defer(parquet_close(file))

  expect_identical(bloom_filter_may_contain(file, "key", NA_real_), NA)
  expect_error(bloom_filter_may_contain(file, "nope", 1), "Unknown column")
  expect_error(bloom_filter_may_contain(file, "key", "text"), "must be numeric")
  expect_error(
    bloom_filter_may_contain(file, "label", 1),
    "must be character"
  )
  expect_error(
    bloom_filter_may_contain(file, "key", 1, row_group = 99),
    "out of range"
  )
  # score has no bloom filter in this fixture.
  expect_error(bloom_filter_may_contain(file, "score", 1), "no bloom filter")
})

# --- Declared sort order ----------------------------------------------------
# Write-only: the bundled library records the declaration but exposes no way to
# read it back, so agreement is checked against pyarrow in
# tools/check-inspection-against-arrow.R rather than here.

test_that("sorted_by accepts names and a full declaration", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(a = 1:20, b = rev(1:20), s = letters[1:20])

  write_parquet(data, path, sorted_by = "a")
  expect_identical(read_parquet(path), data)

  write_parquet(
    data,
    path,
    row_group_size = 5,
    sorted_by = data.frame(
      name = c("b", "a"),
      descending = c(TRUE, FALSE),
      nulls_first = c(TRUE, FALSE)
    )
  )
  expect_identical(read_parquet(path), data)
})

test_that("sorted_by rejects columns it cannot resolve", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(a = 1:5, b = 6:10)

  expect_error(
    write_parquet(data, path, sorted_by = "nope"),
    "not being written"
  )
  expect_error(
    write_parquet(data, path, sorted_by = c("a", "a")),
    "more than once"
  )
  expect_error(
    write_parquet(data, path, sorted_by = data.frame(nope = "a")),
    "`name` column"
  )
  expect_error(
    write_parquet(
      data,
      path,
      sorted_by = data.frame(name = "a", descending = NA)
    ),
    "must not be NA"
  )
})

test_that("an empty sort declaration is the same as none", {
  path <- withr::local_tempfile(fileext = ".parquet")
  data <- data.frame(a = 1:5)
  write_parquet(data, path, sorted_by = character())
  expect_identical(read_parquet(path), data)
})
