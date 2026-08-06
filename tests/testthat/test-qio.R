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

  pf <- open_parquet(path)
  on.exit(close_parquet(pf), add = TRUE)
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

  pf <- open_parquet(path)
  on.exit(close_parquet(pf), add = TRUE)
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
      physical_type = c(
        "BOOLEAN",
        "INT32",
        "INT64",
        "INT96",
        "FLOAT",
        "DOUBLE",
        "BYTE_ARRAY",
        "FIXED_LEN_BYTE_ARRAY"
      ),
      r_type = c(
        "logical",
        "integer",
        "double",
        "POSIXct",
        "double",
        "double",
        # Both byte types are bytes here. This table reports the physical
        # fallback, and a BYTE_ARRAY is character only once the file annotates
        # it STRING, ENUM, or JSON.
        "list",
        "list"
      ),
      written_from = c(
        "logical",
        "integer",
        "numeric (explicit schema)",
        NA,
        "numeric (explicit schema)",
        "double",
        "character or factor",
        NA
      )
    )
  )
})

# --- Phase P: native glue preflight ----------------------------------------

test_that("an error inside the write loop leaves no partial file", {
  # A "bytes"-encoded string makes Rf_translateCharUTF8() fail after the writer
  # has been created and the first column written. Without unwind protection
  # the writer leaked and an empty file was left behind.
  path <- withr::local_tempfile(fileext = ".parquet")
  value <- rawToChar(as.raw(c(0xff, 0xfe)))
  Encoding(value) <- "bytes"
  x <- data.frame(a = 1:2, s = c("ok", "ok"), stringsAsFactors = FALSE)
  x$s[2] <- value

  expect_error(write_parquet(x, path), "bytes")
  expect_false(file.exists(path))

  # The failure released everything, so the same path is still usable.
  write_parquet(data.frame(z = 1:3), path)
  expect_equal(nrow(read_parquet(path)), 3L)
})

test_that("a write failure leaves no file the reader would accept", {
  path <- withr::local_tempfile(fileext = ".parquet")
  value <- rawToChar(as.raw(c(0xff, 0xfe)))
  Encoding(value) <- "bytes"
  x <- data.frame(s = c("ok", "ok"), stringsAsFactors = FALSE)
  x$s[2] <- value

  expect_error(write_parquet(x, path), "bytes")
  expect_error(read_parquet(path))
})

test_that("a REQUIRED column rejects missing values before writing", {
  path <- withr::local_tempfile(fileext = ".parquet")
  schema <- parquet_schema(
    a = list(type = "INT32", repetition_type = "REQUIRED")
  )

  expect_error(
    write_parquet(data.frame(a = c(1L, NA)), path, schema = schema),
    "missing values"
  )
  expect_false(file.exists(path))
})

# --- Writer: float encoding ------------------------------------------------

test_that("large nullable double columns round-trip exactly", {
  # carquet selects BYTE_STREAM_SPLIT for FLOAT/DOUBLE when a codec is set, and
  # its encoder is wrong for a page whose values arrive in more than one call:
  # it transposes each call's subrange separately and appends, so the decoder
  # de-splits the concatenation as one stride. This silently corrupted every
  # present value once a nullable double column passed roughly a megabyte of
  # them. qio forces PLAIN for these types; see .agents/VENDORED.md.
  skip_on_cran()
  n <- 200000L
  set.seed(1)
  values <- stats::rnorm(n)
  values[seq(1L, n, by = 7L)] <- NA
  path <- withr::local_tempfile(fileext = ".parquet")

  write_parquet(data.frame(v = values), path)
  back <- read_parquet(path)$v

  expect_identical(is.na(back), is.na(values))
  expect_equal(back, values)
})

test_that("float and double survive every codec at page-spanning sizes", {
  skip_on_cran()
  n <- 160000L
  set.seed(2)
  values <- stats::rnorm(n)
  values[seq(1L, n, by = 5L)] <- NA

  for (codec in c("snappy", "zstd", "gzip", "uncompressed")) {
    path <- withr::local_tempfile(fileext = ".parquet")
    write_parquet(data.frame(v = values), path, compression = codec)
    expect_equal(read_parquet(path)$v, values, info = codec)
  }

  # FLOAT goes through the same encoder selection.
  path <- withr::local_tempfile(fileext = ".parquet")
  schema <- parquet_schema(v = "FLOAT")
  write_parquet(data.frame(v = values), path, schema = schema)
  back <- read_parquet(path)$v
  expect_identical(is.na(back), is.na(values))
  expect_equal(back, values, tolerance = 1e-6)
})

# --- Writer: adversarial round trips ---------------------------------------
# The writer was previously only tested on frames small enough to fit one data
# page, which is why a corruption bug past ~1MB of present values survived. The
# comparison is against Apache Arrow as well as the input, so a fault shared by
# qio's reader and writer cannot hide.

writer_frame <- function(n, nulls) {
  hit <- if (nulls) seq(1L, n, by = 7L) else integer()
  na <- function(x) {
    if (length(hit)) {
      x[hit] <- NA
    }
    x
  }
  data.frame(
    lgl = na(rep(c(TRUE, FALSE), length.out = n)),
    int = na(seq_len(n)),
    dbl = na(stats::rnorm(n)),
    chr = na(paste0("s", sprintf("%08d", seq_len(n)))),
    day = na(as.Date("2020-01-01") + (seq_len(n) %% 3650L)),
    ts = na(as.POSIXct("2020-01-01", tz = "UTC") + seq_len(n)),
    stringsAsFactors = FALSE
  )
}

# Round-tripping through qio catches a corrupt write on its own: the corrupted
# float columns differed from the input. Confirming that the *file* rather than
# the reader is at fault needs an independent implementation, which lives in
# tools/check-writer-against-arrow.R so arrow stays out of the test
# dependencies.
expect_round_trip <- function(data, path, codec = "snappy", tolerance = 1e-9) {
  write_parquet(data, path, compression = codec)
  expect_equal(read_parquet(path), data, tolerance = tolerance, info = codec)
}

test_that("every writable type round-trips across codecs, sizes, and nulls", {
  skip_on_cran()
  set.seed(42)
  for (codec in c("snappy", "zstd", "gzip", "lz4", "uncompressed")) {
    for (nulls in c(FALSE, TRUE)) {
      path <- withr::local_tempfile(fileext = ".parquet")
      expect_round_trip(writer_frame(2000L, nulls), path, codec)
    }
  }
})

test_that("a zstd file with several numeric columns reads in parallel", {
  # The regression this exists for is Windows-only and was invisible on every
  # other platform. carquet cached one zstd decompression context for the whole
  # process there instead of one per thread, and a mapped collect() decodes
  # numeric columns on the worker pool while decoding strings on the main
  # thread, so two threads shared it: the read either failed to decode or ended
  # the session. The test above covers this incidentally; this one states the
  # conditions so they cannot be lost by editing that frame.
  #
  # It needs more than one *numeric* column, because that is what decides
  # whether a pool is created at all, plus a string column to keep the main
  # thread decoding at the same time.
  skip_on_cran()
  set.seed(45)
  n <- 5000L
  data <- data.frame(
    a = seq_len(n),
    b = stats::rnorm(n),
    c = as.Date("2020-01-01") + (seq_len(n) %% 3650L),
    d = as.POSIXct("2020-01-01", tz = "UTC") + seq_len(n),
    s = paste0("s", sprintf("%06d", seq_len(n))),
    stringsAsFactors = FALSE
  )
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data, path, compression = "zstd")

  for (threads in c(0L, 1L, 4L)) {
    for (mapped in c(TRUE, FALSE)) {
      file <- open_parquet(path, mmap = mapped, threads = threads)
      withr::defer(close_parquet(file))
      expect_equal(
        collect(file),
        data,
        info = paste("threads", threads, "mmap", mapped)
      )
    }
  }
})

test_that("columns larger than one data page round-trip under every codec", {
  # The regression this exists for: with a codec set, carquet selects
  # BYTE_STREAM_SPLIT for FLOAT/DOUBLE, whose encoder corrupted any page built
  # from more than one call. A nullable double column past roughly a megabyte
  # of present values came back with every non-null value wrong.
  skip_on_cran()
  set.seed(43)
  n <- 150000L
  values <- stats::rnorm(n)
  values[seq(1L, n, by = 7L)] <- NA

  for (codec in c("snappy", "zstd", "gzip", "uncompressed")) {
    path <- withr::local_tempfile(fileext = ".parquet")
    write_parquet(data.frame(v = values), path, compression = codec)
    back <- read_parquet(path)$v
    expect_identical(is.na(back), is.na(values), info = codec)
    expect_equal(back, values, info = codec)
  }
})

test_that("page-spanning logical, integer, and string columns survive", {
  skip_on_cran()
  set.seed(44)
  n <- 200000L
  frames <- list(
    logical = data.frame(
      v = ifelse(stats::runif(n) < 0.3, NA, stats::runif(n) > 0.5)
    ),
    integer = data.frame(
      v = ifelse(stats::runif(n) < 0.3, NA_integer_, seq_len(n))
    ),
    string = data.frame(
      v = ifelse(stats::runif(n) < 0.3, NA, strrep(paste0("x", seq_len(n)), 3)),
      stringsAsFactors = FALSE
    )
  )
  for (name in names(frames)) {
    path <- withr::local_tempfile(fileext = ".parquet")
    write_parquet(frames[[name]], path)
    expect_equal(read_parquet(path), frames[[name]], info = name)
  }
})

test_that("explicit schema types round-trip past a page boundary", {
  skip_on_cran()
  set.seed(45)
  n <- 200000L
  path <- withr::local_tempfile(fileext = ".parquet")

  write_parquet(
    data.frame(v = as.double(seq_len(n))),
    path,
    schema = parquet_schema(v = "INT64")
  )
  expect_equal(read_parquet(path)$v, as.double(seq_len(n)))

  singles <- stats::rnorm(n)
  write_parquet(
    data.frame(v = singles),
    path,
    schema = parquet_schema(v = "FLOAT")
  )
  expect_equal(read_parquet(path)$v, singles, tolerance = 1e-6)

  for (unit in c("MILLIS", "MICROS", "NANOS")) {
    stamps <- as.POSIXct("2020-01-01", tz = "UTC") + seq_len(n)
    write_parquet(
      data.frame(v = stamps),
      path,
      schema = parquet_schema(v = list("TIMESTAMP", unit = unit))
    )
    expect_equal(read_parquet(path)$v, stamps, info = unit)
  }
})

test_that("degenerate frames round-trip", {
  cases <- list(
    "all-NA double" = data.frame(v = rep(NA_real_, 500L)),
    "all-NA character" = data.frame(v = rep(NA_character_, 500L)),
    "all-NA logical" = data.frame(v = rep(NA, 500L)),
    "single row" = data.frame(v = 1.5),
    "constant" = data.frame(v = rep(3.14, 5000L)),
    "empty strings" = data.frame(v = rep("", 5000L), stringsAsFactors = FALSE)
  )
  for (name in names(cases)) {
    path <- withr::local_tempfile(fileext = ".parquet")
    write_parquet(cases[[name]], path)
    expect_equal(read_parquet(path), cases[[name]], info = name)
  }
})

# --- Writer: nothing is destroyed by a write that fails ---------------------

test_that("a rejected write leaves an existing file untouched", {
  # Every validation must happen before the output is created, because opening
  # for writing truncates. A user overwriting a good file with a bad frame must
  # still have the good file.
  original <- data.frame(keep = 1:5)
  rejections <- list(
    "unsupported R type" = list(
      data = data.frame(v = complex(real = 1:3)),
      schema = NULL
    ),
    "schema type mismatch" = list(
      data = data.frame(v = c("a", "b")),
      schema = parquet_schema(v = "INT32")
    ),
    "REQUIRED column with NA" = list(
      data = data.frame(v = c(1L, NA)),
      schema = parquet_schema(
        v = list(type = "INT32", repetition_type = "REQUIRED")
      )
    ),
    "INT64 outside the exact range" = list(
      data = data.frame(v = 2^60),
      schema = parquet_schema(v = "INT64")
    ),
    "NaN in a DATE column" = list(
      data = data.frame(v = c(1, NaN)),
      schema = parquet_schema(v = "DATE")
    ),
    "no columns" = list(data = data.frame(), schema = NULL)
  )

  for (name in names(rejections)) {
    path <- withr::local_tempfile(fileext = ".parquet")
    write_parquet(original, path)
    before <- file.info(path)$size
    case <- rejections[[name]]

    expect_error(
      if (is.null(case$schema)) {
        write_parquet(case$data, path)
      } else {
        write_parquet(case$data, path, schema = case$schema)
      },
      info = name
    )

    expect_identical(file.info(path)$size, before, info = name)
    expect_identical(read_parquet(path)$keep, 1:5, info = name)
  }
})

test_that("a failure after the writer exists leaves no readable file", {
  # Once encoding starts the output has been created, so the contract changes:
  # there must be no file left that any reader would accept as complete.
  path <- withr::local_tempfile(fileext = ".parquet")
  value <- rawToChar(as.raw(c(0xff, 0xfe)))
  Encoding(value) <- "bytes"
  x <- data.frame(
    a = 1:3,
    b = 1:3,
    s = c("ok", "ok", "ok"),
    stringsAsFactors = FALSE
  )
  x$s[3] <- value

  expect_error(write_parquet(x, path), "bytes")
  expect_false(file.exists(path))
  expect_error(read_parquet(path))

  # The path is reusable: nothing was left holding it open.
  write_parquet(data.frame(z = 1:4), path)
  expect_identical(read_parquet(path)$z, 1:4)
})

test_that("write errors carry carquet's status", {
  # write_batch() and close() return a bare status with no carquet_error_t, so
  # the status string is the whole of the context available.
  expect_error(
    write_parquet(
      data.frame(a = 1),
      file.path(tempdir(), "no", "such", "dir", "f.parquet")
    ),
    "cannot create"
  )
})

test_that("writes are chunked, so scratch does not scale with row count", {
  # A column used to be encoded in one pass, so scratch was sized by the frame:
  # a 4-million-row string column needed 64MB of byte-array descriptors. It is
  # now written in fixed chunks. This needs every encoding to resume correctly
  # across batches, which BYTE_STREAM_SPLIT and BOOLEAN did not until the
  # vendored fixes; see .agents/VENDORED.md.
  skip_on_cran()
  measure <- function(rows) {
    frame <- data.frame(s = rep("abcdefghij", rows), stringsAsFactors = FALSE)
    path <- withr::local_tempfile(fileext = ".parquet")
    gc(reset = TRUE, full = TRUE)
    write_parquet(frame, path)
    gc(full = TRUE)["Vcells", "max used"] * 8 / 1024^2
  }
  small <- measure(200000L)
  large <- measure(1600000L)
  # Eight times the rows must not cost eight times the peak.
  expect_lt(large, small * 4)
})

test_that("a chunked write round-trips at sizes spanning many chunks", {
  # The chunk is 65536 rows, so this crosses it repeatedly and lands on a
  # boundary that is not a multiple of it.
  skip_on_cran()
  set.seed(11)
  n <- 200003L
  frame <- data.frame(
    lgl = rep(c(TRUE, FALSE, NA), length.out = n),
    dbl = stats::rnorm(n),
    int = seq_len(n),
    chr = paste0("v", seq_len(n)),
    stringsAsFactors = FALSE
  )
  frame$dbl[seq(1L, n, by = 11L)] <- NA
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(frame, path)
  expect_equal(read_parquet(path), frame)
})

test_that("booleans survive a write split across chunks", {
  # PLAIN boolean encoding is one continuous bit stream per page, so a batch
  # boundary that is not a multiple of 8 must not restart it. Writing 1000
  # booleans as 5 then 995 corrupted 398 of them before the fix.
  skip_on_cran()
  n <- 200000L
  values <- rep(c(TRUE, TRUE, FALSE, TRUE, FALSE), length.out = n)
  values[seq(3L, n, by = 13L)] <- NA
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(v = values), path)
  expect_identical(read_parquet(path)$v, values)
})

# --- Dictionary-encoded text ------------------------------------------------
# qio writes BYTE_ARRAY columns with RLE_DICTIONARY. carquet falls back to
# PLAIN by itself once a chunk's dictionary outgrows its page limit, so both
# outcomes have to round-trip, and the encoding is a per-chunk property rather
# than a property of the file.

test_that("text columns are written dictionary-encoded", {
  path <- withr::local_tempfile(fileext = ".parquet")
  frame <- data.frame(
    label = sprintf("label-%03d", seq_len(2000L) %% 40L),
    value = as.numeric(seq_len(2000L)),
    stringsAsFactors = FALSE
  )
  write_parquet(frame, path)

  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  chunks <- column_chunks(file)

  text <- chunks[chunks$column == 1L, ]
  expect_true(all(text$dictionary_page))
  expect_true(all(grepl("RLE_DICTIONARY", text$encodings, fixed = TRUE)))

  # Numeric columns are left alone: a dictionary index is four bytes and a
  # double is eight, so there is far less to gain and it would change the
  # output of every existing numeric write.
  numeric <- chunks[chunks$column == 2L, ]
  expect_false(any(numeric$dictionary_page))

  expect_identical(read_parquet(path), frame)
})

test_that("high-cardinality text still round-trips after the dictionary falls back", {
  path <- withr::local_tempfile(fileext = ".parquet")
  # Every value distinct and wide enough to outgrow the dictionary page limit,
  # which forces carquet back to PLAIN partway through the chunk.
  frame <- data.frame(
    text = paste0(sprintf("%06d-", seq_len(5000L)), strrep("z", 400)),
    stringsAsFactors = FALSE
  )
  write_parquet(frame, path)
  expect_identical(read_parquet(path), frame)
})

test_that("appending keeps each row group's own encoding", {
  path <- withr::local_tempfile(fileext = ".parquet")
  first <- data.frame(
    k = sprintf("g-%02d", seq_len(100L) %% 9L),
    stringsAsFactors = FALSE
  )
  second <- data.frame(
    k = sprintf("h-%02d", seq_len(60L) %% 5L),
    stringsAsFactors = FALSE
  )
  write_parquet(first, path)
  write_parquet(second, path, append = TRUE)

  expect_identical(read_parquet(path), rbind(first, second))
})

test_that("read_parquet() selects columns and row groups", {
  path <- test_path("parquet", "qio-multigroup.parquet")
  whole <- read_parquet(path)

  expect_equal(read_parquet(path, columns = "label"), whole["label"])
  expect_equal(
    read_parquet(path, columns = c("id", "price")),
    whole[c("id", "price")]
  )

  # The fixture has more than one row group, so a subset is a real subset.
  handle <- open_parquet(path)
  on.exit(close_parquet(handle), add = TRUE)
  groups <- nrow(row_groups(handle))
  expect_gt(groups, 1L)
  expect_equal(
    read_parquet(path, row_groups = 1L),
    collect(handle, row_groups = 1L)
  )
  expect_lt(nrow(read_parquet(path, row_groups = 1L)), nrow(whole))
})

test_that("read_parquet() forwards selection errors from collect()", {
  path <- test_path("parquet", "qio-multigroup.parquet")
  expect_error(read_parquet(path, columns = "nope"), "Unknown Parquet column")
  expect_error(read_parquet(path, row_groups = 999L), "out of range")
})

test_that("read_parquet() takes its read arguments by name only", {
  # `columns` binds by name in collect(), walk_batches() and read_plan(). It
  # must bind the same way here, or the same argument means one thing in the
  # eager API and another in the handle API.
  path <- test_path("parquet", "qio-multigroup.parquet")
  expect_error(read_parquet(path, "label"), "`\\.\\.\\.` must be empty")
  expect_error(read_parquet(path, "double"), "`\\.\\.\\.` must be empty")
  expect_named(read_parquet(path, columns = "label"), "label")
})
