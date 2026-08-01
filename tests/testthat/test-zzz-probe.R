# TEMPORARY diagnostic, to be deleted once the Windows BYTE_ARRAY failure is
# understood. It walks the round-trip matrix without aborting on the first
# failure and reports every failing cell at once, because the real test stops
# at the first error and so reveals neither the codec, the size, nor whether
# the mapped or the buffered path is at fault.

probe_frame <- function(n, nulls) {
  hit <- if (nulls) seq(1L, n, by = 7L) else integer()
  na <- function(x) {
    if (length(hit)) x[hit] <- NA
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

test_that("PROBE: which round-trip cells fail", {
  skip_on_cran()
  set.seed(42)
  bad <- character()

  for (codec in c("uncompressed", "snappy", "zstd", "gzip", "lz4")) {
    for (nulls in c(FALSE, TRUE)) {
      for (n in c(100L, 1000L, 2000L)) {
        frame <- probe_frame(n, nulls)
        for (column in names(frame)) {
          one <- frame[column]
          for (mapped in c(TRUE, FALSE)) {
            path <- withr::local_tempfile(fileext = ".parquet")
            outcome <- tryCatch(
              {
                write_parquet(one, path, compression = codec)
                handle <- parquet_open(path, mmap = mapped)
                on.exit(parquet_close(handle), add = TRUE)
                back <- collect(handle)
                if (isTRUE(all.equal(back, one))) "ok" else "MISMATCH"
              },
              error = function(e) paste("ERR", conditionMessage(e))
            )
            if (!identical(outcome, "ok")) {
              bad <- c(bad, sprintf(
                "%s n=%d nulls=%s mmap=%s %s -> %s",
                codec, n, nulls, mapped, column, outcome
              ))
            }
          }
        }
      }
    }
  }

  # Deliberately reported as a failure so the strings reach the CI log.
  expect_identical(bad, character())
})
