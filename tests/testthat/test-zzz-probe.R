# TEMPORARY diagnostic, to be deleted once the Windows failure is confirmed.
#
# Round one: every single-column file round-tripped on Windows, all five
# codecs, three sizes, nulls or not, mapped or buffered.
# Round two: every multi-column file round-tripped too -- but that round only
# used snappy and uncompressed.
#
# The cell neither round covered is multi-column with a *stateful* codec, and
# there is a mechanism that predicts exactly that. carquet keeps its zstd
# decompression context in thread-local storage on POSIX, but on Windows
# without OpenMP -- which is how Rtools builds this package -- it falls back to
# a process-global ZSTD_DCtx shared by every thread. A mapped collect() decodes
# numeric columns on the worker pool while decoding strings on the main thread,
# so two threads use that one context at once. One numeric column means no
# pool and no race, which is why rounds one and two passed.
#
# This round is the test of that hypothesis. Predictions:
#   zstd + several numeric columns + default threads -> fails
#   zstd + several numeric columns + threads = 1     -> passes (no pool)
#   zstd + one numeric column                        -> passes (no pool)
#   gzip (stack-local z_stream) and lz4 (stateless)  -> pass throughout

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

probe_sets <- list(
  all = c("lgl", "int", "dbl", "chr", "day", "ts"),
  numeric_only = c("lgl", "int", "dbl", "day", "ts"),
  two_numeric = c("chr", "day", "ts"),
  one_numeric = c("chr", "day"),
  chr_only = "chr"
)

test_that("PROBE: codec against thread count", {
  skip_on_cran()
  set.seed(42)
  bad <- character()

  for (codec in c("zstd", "gzip", "lz4", "snappy")) {
    for (threads in c(0L, 1L)) {
      for (nulls in c(FALSE, TRUE)) {
        frame <- probe_frame(2000L, nulls)
        for (set_name in names(probe_sets)) {
          one <- frame[probe_sets[[set_name]]]
          for (mapped in c(TRUE, FALSE)) {
            path <- withr::local_tempfile(fileext = ".parquet")
            outcome <- tryCatch(
              {
                write_parquet(one, path, compression = codec)
                handle <- parquet_open(path, mmap = mapped, threads = threads)
                on.exit(parquet_close(handle), add = TRUE)
                back <- collect(handle)
                if (isTRUE(all.equal(back, one))) "ok" else "MISMATCH"
              },
              error = function(e) paste("ERR", conditionMessage(e))
            )
            if (!identical(outcome, "ok")) {
              bad <- c(bad, sprintf(
                "%s threads=%d nulls=%s mmap=%s [%s] -> %s",
                codec, threads, nulls, mapped, set_name, outcome
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
