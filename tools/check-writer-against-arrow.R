# Cross-check qio's writer against Apache Arrow.
#
#   Rscript tools/check-writer-against-arrow.R
#
# The test suite round-trips through qio, which catches a corrupt write because
# the values differ from the input. It cannot say whether the writer or the
# reader is at fault. This script reads every file back with an independent
# implementation and compares *that* against the original input, which settles
# it:
#
#   arrow disagrees with the input  -> the file is wrong, so the writer is
#   arrow matches, qio does not     -> the file is fine, so the reader is
#
# Comparing qio's read against arrow's read would prove nothing about the
# writer: a badly written file decodes to the same wrong values in both.
#
# arrow is a manual tool here, never a test dependency; the suite must pass
# without it.

suppressMessages(devtools::load_all(quiet = TRUE))
stopifnot(requireNamespace("arrow", quietly = TRUE))
set.seed(42)

frame <- function(n, nulls) {
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

failures <- 0L
check <- function(label, data, schema = NULL, codec = "snappy", tol = 1e-9) {
  path <- tempfile(fileext = ".parquet")
  if (is.null(schema)) {
    write_parquet(data, path, compression = codec)
  } else {
    write_parquet(data, path, schema = schema, compression = codec)
  }
  ours <- read_parquet(path)
  theirs <- as.data.frame(arrow::read_parquet(path))
  bad <- character()
  for (column in names(data)) {
    expected <- as.vector(data[[column]])
    other <- theirs[[column]]
    if (inherits(data[[column]], "Date")) {
      other <- as.Date(other)
    }
    arrow_ok <- isTRUE(all.equal(as.vector(other), expected, tolerance = tol))
    qio_ok <- isTRUE(all.equal(
      as.vector(ours[[column]]),
      expected,
      tolerance = tol
    ))
    if (!arrow_ok) {
      bad <- c(bad, paste0(column, " WRITER"))
    } else if (!qio_ok) {
      bad <- c(bad, paste0(column, " READER"))
    }
  }
  if (length(bad)) {
    failures <<- failures + 1L
    cat(sprintf("FAIL %-38s %s\n", label, paste(bad, collapse = "; ")))
  }
}

for (codec in c("snappy", "zstd", "gzip", "lz4", "uncompressed")) {
  for (n in c(2000L, 150000L)) {
    for (nulls in c(FALSE, TRUE)) {
      check(
        sprintf("%s n=%d nulls=%s", codec, n, nulls),
        frame(n, nulls),
        codec = codec
      )
    }
  }
}
n <- 200000L
check(
  "INT64 explicit",
  data.frame(v = as.double(seq_len(n))),
  parquet_schema(v = "INT64")
)
check(
  "FLOAT explicit",
  data.frame(v = stats::rnorm(n)),
  parquet_schema(v = "FLOAT"),
  tol = 1e-6
)
for (unit in c("MILLIS", "MICROS", "NANOS")) {
  check(
    paste("TIMESTAMP", unit),
    data.frame(v = as.POSIXct("2020-01-01", tz = "UTC") + seq_len(n)),
    parquet_schema(v = list("TIMESTAMP", unit = unit))
  )
}
check("all-NA logical", data.frame(v = rep(NA, 500L)))
check("all-NA double", data.frame(v = rep(NA_real_, 500L)))
check("constant double 500k", data.frame(v = rep(3.14, 500000L)))
check(
  "wide strings 400k",
  data.frame(
    v = strrep(paste0("x", seq_len(400000L)), 3),
    stringsAsFactors = FALSE
  )
)

cat(sprintf("\n%d disagreements with Apache Arrow\n", failures))
if (failures > 0L) {
  quit(status = 1L)
}
