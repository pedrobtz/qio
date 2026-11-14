ext <- function(name) test_path("parquet", name)

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

int64_fixture <- function() ext("int64_boundaries.parquet")

temporal_fixture <- function() ext("temporal_types.parquet")

reference <- function(name) readRDS(ext(name))
