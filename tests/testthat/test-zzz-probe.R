# TEMPORARY diagnostic, to be deleted once the Windows BYTE_ARRAY failure is
# understood.
#
# Round one ruled out a great deal: every single-column file round-tripped on
# Windows across all five codecs, three sizes, nulls or not, mapped or
# buffered. The failing test differs in one way only -- it writes six columns
# into one file. So this round varies the column set instead, to find the
# smallest combination that fails and whether the preceding column's type
# matters.

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
  no_dbl = c("lgl", "int", "chr", "day", "ts"),
  dbl_chr = c("dbl", "chr"),
  chr_dbl = c("chr", "dbl"),
  int_chr = c("int", "chr"),
  lgl_chr = c("lgl", "chr"),
  chr_day = c("chr", "day"),
  chr_only = "chr",
  chr_chr = c("chr", "day", "ts")
)

test_that("PROBE: which column combinations fail", {
  skip_on_cran()
  set.seed(42)
  bad <- character()

  for (codec in c("snappy", "uncompressed")) {
    for (nulls in c(FALSE, TRUE)) {
      for (n in c(500L, 2000L)) {
        frame <- probe_frame(n, nulls)
        for (set_name in names(probe_sets)) {
          one <- frame[probe_sets[[set_name]]]
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
                "%s n=%d nulls=%s mmap=%s [%s] -> %s",
                codec, n, nulls, mapped, set_name, outcome
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
