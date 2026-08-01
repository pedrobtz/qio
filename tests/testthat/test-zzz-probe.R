# TEMPORARY diagnostic, to be deleted once the Windows failure is confirmed.
#
# Round three did not report at all: the R process died partway through, with
# testthat.Rout.fail ending at test_check("qio"). A hard crash rather than a
# decode error is itself evidence of memory corruption, but it means a summary
# printed at the end never survives.
#
# So this round prints each cell BEFORE attempting it and flushes, making the
# last line in the log the cell that crashed. Codecs are ordered so that the
# suspected one comes last: if the hypothesis is right, everything up to the
# first zstd multi-numeric-column cell should print and pass.
#
# Hypothesis under test: carquet keeps its zstd decompression context in
# thread-local storage on POSIX but in a process-global ZSTD_DCtx on Windows
# without OpenMP, which is how Rtools builds this package. A mapped collect()
# decodes numeric columns on the worker pool while decoding strings on the
# main thread, so two threads use that one context at once.

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
  chr_only = "chr",
  one_numeric = c("chr", "day"),
  two_numeric = c("chr", "day", "ts"),
  all = c("lgl", "int", "dbl", "chr", "day", "ts")
)

test_that("PROBE: codec against thread count, reported as it goes", {
  skip_on_cran()
  set.seed(42)
  frame <- probe_frame(2000L, TRUE)
  say <- function(...) {
    cat(..., "\n", sep = "")
    flush(stdout())
  }

  # threads = 1 first for every codec: no pool, so every cell should pass and
  # the run should reach the threads = 0 block.
  for (threads in c(1L, 0L)) {
    for (codec in c("uncompressed", "snappy", "lz4", "gzip", "zstd")) {
      for (set_name in names(probe_sets)) {
        for (mapped in c(TRUE, FALSE)) {
          cell <- sprintf(
            "PROBECELL threads=%d %s [%s] mmap=%s",
            threads, codec, set_name, mapped
          )
          say(cell, " ...")
          one <- frame[probe_sets[[set_name]]]
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
          say(cell, " -> ", outcome)
        }
      }
    }
  }

  expect_true(TRUE)
})
