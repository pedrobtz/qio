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
  file <- open_parquet(path, ...)
  withr::defer(close_parquet(file), envir = parent.frame())
  file
}

test_that("open_parquet() creates an inspectable handle", {
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
      "repetition_type",
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
    result$repetition_type,
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
        close_parquet(file),
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

  expect_error(collect(file, columns = "missing"), "Unknown Parquet column")
  expect_error(collect(file, columns = c("id", "id")), "duplicates")
  expect_error(collect(file, row_groups = 5), "out of range")
  expect_error(collect(file, row_groups = c(1, 1)), "duplicates")
  expect_error(collect(file, batch_size = 0), "whole number")

  expect_error(open_parquet(fixture_path(), mmap = NA), "mmap")
  expect_error(
    open_parquet(fixture_path(), verify_checksums = 1),
    "verify_checksums"
  )
  expect_error(open_parquet(fixture_path(), threads = -1), "threads")
  expect_error(open_parquet("does-not-exist.parquet"), "does not exist")
})

test_that("closed, serialized, and foreign handles are rejected", {
  file <- open_parquet(fixture_path())
  serialized <- unserialize(serialize(file, NULL))
  foreign <- structure(new("externalptr"), class = "qio_parquet_file")

  expect_invisible(close_parquet(file))
  expect_invisible(close_parquet(file))
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

test_that("the sentinel warning is emitted once per column, not per value", {
  path <- withr::local_tempfile(fileext = ".parquet")
  schema <- parquet_schema(
    d = list(type = "DATE"),
    e = list(type = "DATE"),
    ok = list(type = "DATE")
  )
  write_parquet(
    data.frame(
      d = rep(-2147483648, 20),
      e = rep(-2147483648, 20),
      ok = rep(0, 20)
    ),
    path,
    schema = schema
  )

  read <- collect_warnings(read_parquet(path))
  # Forty coerced values across two columns, and one clean column: two
  # warnings, each naming its own column.
  expect_length(read$warnings, 2L)
  expect_match(read$warnings[[1L]], "column 'd'", fixed = TRUE)
  expect_match(read$warnings[[2L]], "column 'e'", fixed = TRUE)
  expect_false(any(grepl("column 'ok'", read$warnings, fixed = TRUE)))
})

test_that("the sentinel warning survives row-group and batch boundaries", {
  # A column split across four row groups, read one row at a time, still warns
  # once: the per-column flag is set, never counted.
  path <- withr::local_tempfile(fileext = ".parquet")
  schema <- parquet_schema(d = list(type = "DATE"))
  write_parquet(
    data.frame(d = rep(-2147483648, 20)),
    path,
    schema = schema,
    row_group_size = 5
  )

  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  read <- collect_warnings(
    walk_batches(file, function(batch, index) NULL, batch_size = 1L)
  )
  expect_length(read$warnings, 1L)
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

# --- Phase 1: vendored foundation ------------------------------------------

# Count OS threads in this process. Returns NA where there is no cheap probe,
# which is how the thread-count test skips on Windows.
qio_thread_count <- function() {
  if (dir.exists("/proc/self/task")) {
    return(length(list.files("/proc/self/task")))
  }
  if (.Platform$OS.type == "unix") {
    out <- suppressWarnings(
      system2("ps", c("-M", Sys.getpid()), stdout = TRUE, stderr = FALSE)
    )
    if (length(out) > 1L) {
      return(length(out) - 1L)
    }
  }
  NA_integer_
}

# The vendored batch pipeline only engages for a compressed, memory-mapped file
# whose projected columns are all non-nullable, and which has either several row
# groups or at least 500,000 rows. qio writes a single row group, so the row
# count is what makes this file eligible.
local_pipeline_file <- function(rows = 500000L, envir = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".parquet", .local_envir = envir)
  write_parquet(
    data.frame(a = as.double(seq_len(rows)), b = as.double(seq_len(rows))),
    path
  )
  path
}

test_that("walk_batches(threads = 1) starts no worker thread", {
  skip_on_cran()
  if (is.na(qio_thread_count())) {
    skip("no thread-count probe on this platform")
  }
  path <- local_pipeline_file()

  peak_threads <- function(threads) {
    base <- qio_thread_count()
    peak <- base
    file <- open_parquet(path, mmap = TRUE, threads = threads)
    on.exit(close_parquet(file))
    walk_batches(file, function(batch, index) {
      peak <<- max(peak, qio_thread_count())
    })
    peak - base
  }

  # Upstream raised any request below two threads up to two, so a serial read
  # still started a worker. See .agents/VENDORED.md.
  expect_identical(peak_threads(1L), 0L)
  # Control: if the probe stopped working, this would also report zero and the
  # assertion above would pass for the wrong reason.
  expect_gt(peak_threads(2L), 0L)
})

test_that("serial and threaded mmap reads agree", {
  path <- fixture_path()
  serial <- local_parquet_file(path, mmap = TRUE, threads = 1L)
  threaded <- local_parquet_file(path, mmap = TRUE, threads = 4L)
  buffered <- local_parquet_file(path, mmap = FALSE)

  expected <- collect(serial)
  expect_identical(collect(threaded), expected)
  expect_identical(collect(buffered), expected)
  expect_identical(read_parquet(path), expected)
})

test_that("serial and threaded mmap batch walks agree", {
  path <- fixture_path()
  walk_all <- function(threads) {
    file <- local_parquet_file(path, mmap = TRUE, threads = threads)
    batches <- list()
    walk_batches(file, function(batch, index) batches[[index]] <<- batch)
    do.call(rbind, batches)
  }
  expect_identical(walk_all(4L), walk_all(1L))
})

# --- Phase 2: one plan across every materializing read ---------------------

test_that("all three read APIs agree under projection and row-group selection", {
  path <- fixture_path()
  file <- local_parquet_file(path)

  cases <- list(
    list(columns = NULL, row_groups = NULL),
    list(columns = c("id", "label"), row_groups = NULL),
    list(columns = NULL, row_groups = c(1L, 3L)),
    list(columns = c("price", "active"), row_groups = 2L),
    # Reversed selector: results follow physical file order regardless.
    list(columns = c("label", "id"), row_groups = NULL)
  )

  for (case in cases) {
    collected <- collect(
      file,
      columns = case$columns,
      row_groups = case$row_groups
    )
    batches <- list()
    walk_batches(
      file,
      function(batch, index) batches[[index]] <<- batch,
      columns = case$columns,
      row_groups = case$row_groups
    )
    walked <- if (length(batches)) {
      do.call(rbind, batches)
    } else {
      collected[0, , drop = FALSE]
    }

    label <- paste(
      "columns:",
      paste(case$columns, collapse = ","),
      "row_groups:",
      paste(case$row_groups, collapse = ",")
    )
    expect_equal(walked, collected, info = label)
    expect_identical(
      vapply(walked, class, character(1)),
      vapply(collected, class, character(1)),
      info = label
    )
  }
})

test_that("read_parquet() equals collect() over the whole file", {
  path <- fixture_path()
  file <- local_parquet_file(path)
  expect_identical(read_parquet(path), collect(file))
})

test_that("a zero-column selection preserves the row count in every API", {
  path <- ext_nested <- test_path("parquet", "name_collision.parquet")
  file <- local_parquet_file(path)

  result <- suppressMessages(collect(file, columns = "s.b"))
  expect_identical(dim(result), c(3L, 0L))

  rows <- 0L
  suppressMessages(
    walk_batches(
      file,
      function(batch, index) rows <<- rows + nrow(batch),
      columns = "s.b"
    )
  )
  expect_identical(rows, 3L)
})

test_that("nulls decode identically through collect() and walk_batches()", {
  path <- fixture_path()
  file <- local_parquet_file(path)

  collected <- collect(file)
  batches <- list()
  walk_batches(file, function(batch, index) batches[[index]] <<- batch)
  walked <- do.call(rbind, batches)

  for (column in names(collected)) {
    expect_identical(
      is.na(walked[[column]]),
      is.na(collected[[column]]),
      info = column
    )
  }
})

# --- Phase 4: bounded string scratch ---------------------------------------

test_that("collect(batch_size =) bounds the scratch it allocates", {
  skip_on_cran()
  # R_alloc draws from R's vector heap, so gc()'s "max used" Vcells accounts
  # for the native scratch buffers as well as the result. Before scratch was
  # chunked, batch_size had no effect on peak memory at all.
  path <- withr::local_tempfile(fileext = ".parquet")
  rows <- 200000L
  write_parquet(
    data.frame(
      s = paste0("row-", sprintf("%08d", seq_len(rows))),
      stringsAsFactors = FALSE
    ),
    path
  )

  peak_mb <- function(batch_size) {
    file <- open_parquet(path)
    on.exit(close_parquet(file))
    gc(reset = TRUE, full = TRUE)
    invisible(collect(file, batch_size = batch_size))
    gc(full = TRUE)["Vcells", "max used"] * 8 / 1024^2
  }

  small <- peak_mb(4096L)
  large <- peak_mb(rows)
  # The whole-row-group read needs the descriptors for every row at once; the
  # small batch needs them for 4096 rows. The difference must be visible.
  expect_lt(small, large)
})

test_that("batch_size does not change collected values", {
  path <- fixture_path()
  file <- local_parquet_file(path)
  expected <- collect(file)
  for (batch_size in c(1L, 2L, 7L, 65536L)) {
    expect_equal(
      collect(file, batch_size = batch_size),
      expected,
      info = paste("batch_size =", batch_size)
    )
  }
})

test_that("a buffered parallel collect returns exactly the serial result", {
  # Buffered reads give each worker a private reader, since the buffered path
  # shares FILE* and prebuffer state. An earlier version of that change also
  # ran every task inline on the main thread, so each task executed twice
  # against one reader and produced short reads about once in ten collects.
  # Comparing values across thread counts, on fresh handles, is what catches it.
  path <- fixture_path()
  serial <- local_parquet_file(path, threads = 1L)
  expected <- collect(serial)

  for (threads in c(0L, 2L, 4L, 8L)) {
    for (attempt in 1:3) {
      file <- open_parquet(path, threads = threads)
      actual <- collect(file)
      close_parquet(file)
      expect_identical(
        actual,
        expected,
        info = paste("threads =", threads, "attempt", attempt)
      )
    }
  }
})

test_that("buffered and mapped reads agree at every thread count", {
  path <- fixture_path()
  expected <- collect(local_parquet_file(path, threads = 1L))
  for (threads in c(0L, 2L, 4L)) {
    buffered <- local_parquet_file(path, threads = threads)
    mapped <- local_parquet_file(path, mmap = TRUE, threads = threads)
    expect_identical(collect(buffered), expected)
    expect_identical(collect(mapped), expected)
  }
})

# --- Paths outside the active code page -------------------------------------
# carquet opens paths with fopen(), which on Windows reads its bytes in the
# active code page, so a path outside that page cannot be opened at all. qio
# opens the stream itself and hands carquet the FILE*; mapping is the exception,
# because carquet maps from a path, and it falls back to buffered I/O rather
# than refusing the file. See src/qio_path.h.
#
# The mechanism only bites on Windows, but the code runs everywhere, so the
# test does too: on POSIX it guards the same round trip against a regression in
# the shared path handling.

test_that("a non-ASCII path round-trips", {
  # Accented Latin, CJK, and Cyrillic: the first survives most European code
  # pages, the others do not survive any single one.
  name <- "café-数据-файл.parquet"
  directory <- withr::local_tempdir()
  path <- file.path(directory, name)

  # A filesystem that cannot store the name at all is not what is under test.
  skip_if(
    inherits(try(file.create(path), silent = TRUE), "try-error") ||
      !file.exists(path),
    "the filesystem cannot represent a non-ASCII filename"
  )

  data <- data.frame(
    n = 1:100,
    x = as.numeric(1:100),
    s = paste0("v", 1:100),
    stringsAsFactors = FALSE
  )
  expect_identical(write_parquet(data, path), path)
  expect_true(file.exists(path))
  expect_identical(read_parquet(path), data)

  # Both read paths, since only the buffered one goes through the stream.
  for (mapped in c(TRUE, FALSE)) {
    file <- local_parquet_file(path, mmap = mapped)
    expect_identical(collect(file), data)
    expect_equal(nrow(file), 100)
  }
})

test_that("a failed write to a non-ASCII path leaves nothing behind", {
  # The writer removes a partial file itself now that it owns the stream:
  # carquet's abort only deletes a file it opened. Without the wide-character
  # remove, the file would survive on Windows.
  name <- "数据-файл.parquet"
  directory <- withr::local_tempdir()
  path <- file.path(directory, name)
  skip_if(
    inherits(try(file.create(path), silent = TRUE), "try-error") ||
      !file.exists(path),
    "the filesystem cannot represent a non-ASCII filename"
  )
  unlink(path)

  value <- rawToChar(as.raw(c(0xff, 0xfe)))
  Encoding(value) <- "bytes"
  x <- data.frame(ok = 1:3, bad = c("a", "b", "c"), stringsAsFactors = FALSE)
  x$bad[3] <- value

  expect_error(write_parquet(x, path), "bytes")
  expect_false(file.exists(path))
})

test_that("a parallel read of a non-ASCII path keeps its lanes", {
  # Each lane opens its own stream. If that had been left on carquet's path
  # entry point, every lane would fail to open on Windows and the read would
  # silently serialize rather than fail, which no other test would notice.
  name <- "файл-lanes.parquet"
  directory <- withr::local_tempdir()
  path <- file.path(directory, name)
  skip_if(
    inherits(try(file.create(path), silent = TRUE), "try-error") ||
      !file.exists(path),
    "the filesystem cannot represent a non-ASCII filename"
  )

  set.seed(46)
  n <- 60000L
  data <- data.frame(
    a = seq_len(n),
    b = stats::rnorm(n),
    c = as.numeric(seq_len(n)),
    s = paste0("v", seq_len(n)),
    stringsAsFactors = FALSE
  )
  write_parquet(data, path)

  serial <- collect(local_parquet_file(path, threads = 1L))
  expect_equal(serial, data)
  expect_equal(collect(local_parquet_file(path, threads = 4L)), data)
})

test_that("open_parquet() treats threads = NULL and threads = 0 alike", {
  # NULL is the documented default and zero is its explicit spelling. They
  # must reach the same place, or the default stops meaning what it says.
  expected <- collect(local_parquet_file(threads = 0L))
  expect_equal(collect(local_parquet_file(threads = NULL)), expected)
  expect_equal(collect(local_parquet_file()), expected)
})

test_that("thread selection respects CRAN's core limit", {
  withr::local_envvar(`_R_CHECK_LIMIT_CORES_` = "false")
  expect_identical(qio_threads(NULL), 2L)
  expect_identical(qio_threads(0L), 2L)
  expect_identical(qio_threads(8L), 8L)

  withr::local_envvar(`_R_CHECK_LIMIT_CORES_` = "TRUE")
  expect_identical(qio_threads(NULL), 2L)
  expect_identical(qio_threads(0L), 2L)
  expect_identical(qio_threads(8L), 2L)
})

test_that("open_parquet() still rejects a bad thread count", {
  # NULL is the only non-numeric value that means anything here.
  expect_error(open_parquet(fixture_path(), threads = -1L), "`threads`")
  expect_error(open_parquet(fixture_path(), threads = 1.5), "`threads`")
  expect_error(open_parquet(fixture_path(), threads = NA_integer_), "`threads`")
  expect_error(open_parquet(fixture_path(), threads = "2"), "`threads`")
})

test_that("close_parquet() takes its handle as `x`", {
  # `file` used to name both a path and an open handle across the API.
  file <- open_parquet(fixture_path())
  expect_identical(close_parquet(x = file), file)
  expect_silent(close_parquet(x = file))
})

test_that("verbose reports the plan for the selected columns only", {
  # The point of `verbose` is to answer "what am I about to get", so the plan
  # it prints must reflect the selection rather than the whole file.
  path <- fixture_path()
  lines <- capture.output(
    read_parquet(path, columns = c("id", "label"), verbose = TRUE),
    type = "message"
  )
  text <- paste(lines, collapse = "\n")

  expect_match(text, "2 of 6 columns")
  expect_match(text, "\\bid\\b")
  expect_match(text, "\\blabel\\b")
  expect_false(grepl("\\bratio\\b", text))
  expect_false(grepl("\\bactive\\b", text))
})

test_that("verbose reports the row groups and options the read will use", {
  # The assertion names the bit64 converter, so the read itself needs bit64.
  skip_if_not_installed("bit64")
  path <- fixture_path()
  text <- paste(
    capture.output(
      read_parquet(
        path,
        row_groups = 1:2,
        int64 = "integer64",
        verbose = TRUE
      ),
      type = "message"
    ),
    collapse = "\n"
  )

  expect_match(text, "2 of 4 row groups")
  # Six of twelve rows, because only half the groups were selected.
  expect_match(text, "6 rows")
  # The plan resolves int64, so it must name the converter actually used.
  expect_match(text, "int64_bit64")
})

test_that("verbose is off by default and suppressible when on", {
  path <- fixture_path()
  expect_silent(read_parquet(path))
  expect_silent(suppressMessages(read_parquet(path, verbose = TRUE)))
  expect_message(read_parquet(path, verbose = TRUE), "Reading")
})

test_that("verbose works from collect() and walk_batches() too", {
  file <- local_parquet_file()
  expect_message(collect(file, verbose = TRUE), "12 rows")
  expect_message(
    walk_batches(file, function(batch, index) NULL, verbose = TRUE),
    "batch size"
  )
})

test_that("verbose rejects a non-flag", {
  expect_error(read_parquet(fixture_path(), verbose = "yes"), "`verbose`")
  expect_error(read_parquet(fixture_path(), verbose = NA), "`verbose`")
})

test_that("per-column coercion flags survive the parallel decode path", {
  # Six columns across eight row groups is 48 worker tasks, each carrying its
  # own flag to be merged on the main thread. A wrong index here would write
  # outside the per-column array, so this is a memory-safety test as much as a
  # behavioral one.
  skip_on_cran()
  path <- withr::local_tempfile(fileext = ".parquet")
  n <- 400L
  columns <- c("a", "b", "c", "d", "e", "f")
  frame <- data.frame(
    a = rep(-2147483648, n),
    b = rep(0, n),
    c = rep(-2147483648, n),
    d = rep(1, n),
    e = rep(-2147483648, n),
    f = rep(2, n)
  )
  schema <- do.call(
    parquet_schema,
    stats::setNames(rep(list(list(type = "DATE")), 6L), columns)
  )
  write_parquet(frame, path, schema = schema, row_group_size = 50L)

  file <- open_parquet(path, mmap = TRUE, threads = 8L)
  withr::defer(close_parquet(file))
  read <- collect_warnings(collect(file))

  # Exactly the three columns that hold the sentinel, in selection order.
  expect_length(read$warnings, 3L)
  expect_match(read$warnings[[1L]], "column 'a'", fixed = TRUE)
  expect_match(read$warnings[[2L]], "column 'c'", fixed = TRUE)
  expect_match(read$warnings[[3L]], "column 'e'", fixed = TRUE)
  expect_identical(nrow(read$value), n)
})

test_that("collect() is registered on dplyr's generic when dplyr is present", {
  # dplyr exports its own collect() generic, so attaching dplyr masks qio's and
  # a method registered only on qio's is invisible to it. Without the
  # registration in .onLoad, both collect(pf) and dplyr::collect(pf) failed
  # with "no applicable method".
  skip_if_not_installed("dplyr")
  file <- local_parquet_file()

  method <- utils::getS3method(
    "collect",
    "qio_parquet_file",
    optional = TRUE,
    envir = asNamespace("dplyr")
  )
  expect_true(is.function(method))
  expect_equal(dplyr::collect(file), collect(file))
  # Read arguments must survive the dispatch.
  expect_named(dplyr::collect(file, columns = "id"), "id")
})
