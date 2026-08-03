#!/usr/bin/env Rscript
#
# A small read/write benchmark meant for CI.
#
#   Rscript bench/ci-benchmark.R
#   Rscript bench/ci-benchmark.R --rows 1000000 --reps 7 --out results.csv
#
# This is deliberately not bench/benchmark.R. That one is the reference
# benchmark: large workloads, per-case tolerances measured on a quiet machine,
# and `--compare` to gate a change against a saved baseline. It answers "did
# this commit make qio slower on my laptop".
#
# This one answers a different question, because a GitHub runner cannot answer
# the first. Runners are shared, so wall time varies far more between runs than
# most real regressions do -- bench/README.md records a 12-21% spread between
# repeated runs on an *idle* local machine, and CI is worse. A 5% threshold
# there would fail on noise several times a week and teach everyone to ignore
# it.
#
# So this script does not compare against a stored baseline and does not fail
# on a small slowdown. It:
#
#   - prints a table, and writes one into the GitHub job summary, so a human
#     can see the trend across runs;
#   - writes a CSV for archiving as a build artifact;
#   - fails only on `--max-seconds`, a ceiling generous enough that only a hang
#     or an order-of-magnitude regression trips it.
#
# It needs nothing but qio and base R. qio generates its own fixtures, which it
# could not do when the reference benchmark was written: row-group boundaries
# were added later, and before that only another writer could produce a
# multi-row-group file.

suppressMessages(library(qio))

# ---------------------------------------------------------------- arguments --

parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  value_after <- function(flag, default) {
    at <- match(flag, argv)
    if (is.na(at) || at == length(argv)) default else argv[[at + 1L]]
  }
  list(
    rows = as.integer(value_after("--rows", "300000")),
    reps = as.integer(value_after("--reps", "5")),
    warmup = as.integer(value_after("--warmup", "1")),
    out = value_after("--out", ""),
    max_seconds = as.numeric(value_after("--max-seconds", "0"))
  )
}

args <- parse_args()
stopifnot(
  is.finite(args$rows),
  args$rows > 0L,
  is.finite(args$reps),
  args$reps > 0L
)

# ----------------------------------------------------------------- workloads --

# One seed, so a rerun measures the same bytes. The shapes are the ones whose
# decode paths differ: dense numeric, dictionary-friendly text, and a nullable
# mixture that exercises definition levels.
set.seed(20260802L)

make_numeric <- function(n) {
  data.frame(
    id = seq_len(n),
    price = stats::rnorm(n),
    ratio = stats::runif(n),
    flag = rep(c(TRUE, FALSE), length.out = n)
  )
}

make_text <- function(n) {
  data.frame(
    label = sprintf("label-%05d", seq_len(n) %% 500L),
    code = sprintf("%s-%07d", sample(LETTERS, n, replace = TRUE), seq_len(n)),
    stringsAsFactors = FALSE
  )
}

make_mixed <- function(n) {
  blank <- function(x) {
    x[seq(1L, n, by = 10L)] <- NA
    x
  }
  data.frame(
    id = blank(seq_len(n)),
    price = blank(stats::rnorm(n)),
    label = blank(sprintf("label-%05d", seq_len(n) %% 500L)),
    day = blank(as.Date("2020-01-01") + (seq_len(n) %% 3650L)),
    stringsAsFactors = FALSE
  )
}

workloads <- list(
  numeric = make_numeric(args$rows),
  text = make_text(args$rows),
  mixed = make_mixed(args$rows)
)

# Several row groups per fixture, so parallel collect and row-group projection
# are actually exercised rather than degenerating to one group.
rows_per_group <- max(1L, args$rows %/% 4L)

directory <- tempfile("qio-ci-bench-")
dir.create(directory)
on.exit(unlink(directory, recursive = TRUE), add = TRUE)

paths <- list()
for (name in names(workloads)) {
  paths[[name]] <- file.path(directory, paste0(name, ".parquet"))
  write_parquet(
    workloads[[name]],
    paths[[name]],
    row_group_size = rows_per_group
  )
}

# ------------------------------------------------------------------- timing --

# Median of `reps` timed runs after `warmup` untimed ones. The median is
# reported rather than the mean because one descheduled run on a shared runner
# would dominate a mean.
time_it <- function(case, reps, warmup) {
  run <- function() {
    gc(verbose = FALSE)
    started <- proc.time()[["elapsed"]]
    case()
    proc.time()[["elapsed"]] - started
  }
  for (i in seq_len(warmup)) {
    run()
  }
  vapply(seq_len(reps), function(i) run(), numeric(1))
}

# Open a handle, do something with it, always close it.
with_handle <- function(path, ..., action) {
  handle <- open_parquet(path, ...)
  on.exit(close_parquet(handle), add = TRUE)
  action(handle)
}

# Each case is a function so that it carries its own fixture. Two traps live
# here, and both produce a benchmark that runs cleanly while measuring the wrong
# thing:
#
#   - A quoted expression would be looked up wherever it is evaluated, not where
#     it was written. `data` is a base R function, so a stale reference to a
#     variable of that name fails as "x must be a data frame".
#   - An R `for` loop does not introduce a scope, so closures built in one share
#     a single environment and all see the *last* iteration's values. Without
#     the `local()` below, every write case wrote the same frame and every read
#     case read the same file, under three different names.
cases <- list()
for (name in names(workloads)) {
  local({
    frame <- workloads[[name]]
    source_path <- paths[[name]]
    target <- file.path(directory, paste0("out-", name, ".parquet"))
    cases[[paste0("write-", name)]] <<- function() {
      write_parquet(frame, target, row_group_size = rows_per_group)
    }
    cases[[paste0("read-", name)]] <<- function() {
      invisible(read_parquet(source_path))
    }
  })
}

cases[["collect-projection"]] <- function() {
  with_handle(paths$mixed, action = function(h) {
    invisible(collect(h, columns = c("id", "label")))
  })
}
cases[["collect-mmap"]] <- function() {
  with_handle(paths$numeric, mmap = TRUE, action = function(h) {
    invisible(collect(h))
  })
}
cases[["collect-serial"]] <- function() {
  with_handle(paths$numeric, threads = 1L, action = function(h) {
    invisible(collect(h))
  })
}
cases[["walk-batches"]] <- function() {
  with_handle(paths$mixed, action = function(h) {
    walk_batches(h, function(batch, index) NULL, batch_size = 50000L)
  })
}

# -------------------------------------------------------------------- report --

results <- data.frame(
  case = character(),
  median = numeric(),
  min = numeric(),
  max = numeric(),
  stringsAsFactors = FALSE
)

for (name in names(cases)) {
  timings <- time_it(cases[[name]], args$reps, args$warmup)
  results <- rbind(
    results,
    data.frame(
      case = name,
      median = median(timings),
      min = min(timings),
      max = max(timings),
      stringsAsFactors = FALSE
    )
  )
}

# The spread is printed because it is the only honest way to read a single CI
# run: a median that moved less than the gap between min and max has not
# necessarily moved at all.
results$spread <- sprintf(
  "%.0f%%",
  100 * (results$max - results$min) / pmax(results$min, 1e-9)
)

format_seconds <- function(x) sprintf("%.4f", x)

cat("\nqio CI benchmark\n")
cat(sprintf(
  "rows %d, %d row groups, %d reps after %d warmup\n",
  args$rows,
  max(1L, ceiling(args$rows / rows_per_group)),
  args$reps,
  args$warmup
))
cat(sprintf(
  "%s, %s, %d cores\n\n",
  R.version.string,
  R.version$platform,
  parallel::detectCores()
))

width <- max(nchar(results$case))
cat(sprintf("%-*s  %8s  %8s  %7s\n", width, "case", "median", "min", "spread"))
for (i in seq_len(nrow(results))) {
  cat(sprintf(
    "%-*s  %8s  %8s  %7s\n",
    width,
    results$case[i],
    format_seconds(results$median[i]),
    format_seconds(results$min[i]),
    results$spread[i]
  ))
}
cat("\n")

if (nzchar(args$out)) {
  written <- results
  written$rows <- args$rows
  written$r_version <- paste(R.version$major, R.version$minor, sep = ".")
  written$platform <- R.version$platform
  written$commit <- Sys.getenv("GITHUB_SHA", "")
  utils::write.csv(written, args$out, row.names = FALSE)
  cat("wrote", args$out, "\n")
}

# GitHub renders this file as the job summary, so the table is visible without
# opening the log or downloading the artifact.
summary_file <- Sys.getenv("GITHUB_STEP_SUMMARY", "")
if (nzchar(summary_file)) {
  lines <- c(
    "### qio benchmark",
    "",
    sprintf(
      "%d rows, %d reps, %s on %s.",
      args$rows,
      args$reps,
      R.version.string,
      R.version$platform
    ),
    "",
    "| case | median (s) | min (s) | spread |",
    "|---|---:|---:|---:|",
    sprintf(
      "| %s | %s | %s | %s |",
      results$case,
      format_seconds(results$median),
      format_seconds(results$min),
      results$spread
    ),
    "",
    paste(
      "Shared runners are noisy, so these are for trend and for catching",
      "order-of-magnitude changes. They are not a regression gate; use",
      "`bench/benchmark.R --compare` on a quiet machine for that."
    )
  )
  cat(paste(lines, collapse = "\n"), "\n", file = summary_file, append = TRUE)
}

# The only failure condition. A ceiling catches a hang or a catastrophic
# regression while staying far enough above normal variation to never flake.
if (args$max_seconds > 0) {
  over <- results[results$median > args$max_seconds, ]
  if (nrow(over) > 0) {
    cat("FAIL: over the", args$max_seconds, "second ceiling:\n")
    cat(
      sprintf(
        "  %s: %s s\n",
        over$case,
        format_seconds(over$median)
      ),
      sep = ""
    )
    quit(status = 1L)
  }
  cat("all cases under the", args$max_seconds, "second ceiling\n")
}
