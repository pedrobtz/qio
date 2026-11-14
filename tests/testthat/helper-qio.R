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
