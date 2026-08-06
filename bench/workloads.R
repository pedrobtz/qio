# Reference workload definitions for qio benchmarks.
#
# These fixtures are generated, never checked in: they are large, and a
# generated file is reproducible from this script plus its seed. Every workload
# names the phase it exists to protect, so a later change knows what it is
# allowed to move.
#
# Sizes are chosen so the whole suite runs in a couple of minutes on a laptop
# while still spanning several row groups.

QIO_BENCH_SEED <- 20260801L

# Row-group target used when generating fixtures. Small enough that every
# multi-row-group code path (parallel collect, row-group projection, batch
# walking) is exercised by every fixture.
QIO_BENCH_ROWS_PER_GROUP <- 250000L

qio_bench_workloads <- function() {
  list(
    numeric = list(
      name = "numeric",
      rows = 2000000L,
      protects = paste(
        "phase 4 numeric decode into R memory, parallel collect,",
        "and the def-level scatter"
      ),
      build = function(n) {
        data.frame(
          id = seq_len(n),
          count = as.double(seq_len(n)) + 1e10,
          ratio = stats::runif(n),
          price = stats::rnorm(n),
          flag = rep(c(TRUE, FALSE), length.out = n),
          stringsAsFactors = FALSE
        )
      }
    ),
    numeric_nulls = list(
      name = "numeric_nulls",
      rows = 2000000L,
      protects = "phase 4 nullable scatter; ~10% nulls in every column",
      build = function(n) {
        na_at <- function(x) {
          x[seq(1L, n, by = 10L)] <- NA
          x
        }
        data.frame(
          id = na_at(seq_len(n)),
          count = na_at(as.double(seq_len(n)) + 1e10),
          ratio = na_at(stats::runif(n)),
          price = na_at(stats::rnorm(n)),
          stringsAsFactors = FALSE
        )
      }
    ),
    string_low_cardinality = list(
      name = "string_low_cardinality",
      rows = 1000000L,
      protects = paste(
        "phase 4 dictionary text materialization and the bounded",
        "string scratch"
      ),
      build = function(n) {
        pool <- paste0("category_", sprintf("%03d", seq_len(200L)))
        data.frame(
          key = sample(pool, n, replace = TRUE),
          label = sample(pool, n, replace = TRUE),
          value = stats::rnorm(n),
          stringsAsFactors = FALSE
        )
      }
    ),
    string_high_cardinality = list(
      name = "string_high_cardinality",
      rows = 1000000L,
      protects = "phase 4 plain-encoded string path and peak string scratch",
      build = function(n) {
        data.frame(
          uid = paste0(
            "id-",
            sprintf("%09d", sample.int(n, n)),
            "-",
            sample(letters, n, replace = TRUE)
          ),
          value = stats::rnorm(n),
          stringsAsFactors = FALSE
        )
      }
    ),
    mixed = list(
      name = "mixed",
      rows = 1000000L,
      protects = "end-to-end read and write; projection and row-group selection",
      build = function(n) {
        pool <- paste0("category_", sprintf("%03d", seq_len(50L)))
        data.frame(
          id = seq_len(n),
          when = as.Date("2020-01-01") + (seq_len(n) %% 3650L),
          stamp = as.POSIXct("2020-01-01", tz = "UTC") + seq_len(n),
          label = sample(pool, n, replace = TRUE),
          value = stats::rnorm(n),
          flag = rep(c(TRUE, FALSE, NA), length.out = n),
          stringsAsFactors = FALSE
        )
      }
    )
  )
}

# Build a workload's data frame reproducibly. The seed is fixed per workload so
# regenerating one fixture does not shift the others.
qio_bench_data <- function(workload) {
  set.seed(QIO_BENCH_SEED)
  workload$build(workload$rows)
}
