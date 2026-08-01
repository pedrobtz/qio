# Reproducible read/write benchmarks for qio.
#
#   Rscript bench/benchmark.R                 # run every case, print a table
#   Rscript bench/benchmark.R --save baseline # also write bench/results/<tag>.csv
#   Rscript bench/benchmark.R --compare baseline
#   Rscript bench/benchmark.R --reps 20 --filter read-
#
# Fixtures are generated under bench/fixtures/ on first use and reused after
# that; delete the directory to force a rebuild. Nothing here is part of the
# package: bench/ is excluded from the source tarball by .Rbuildignore.
#
# Reported metric is the MEDIAN wall time over `reps` timed repetitions after
# `warmup` untimed ones. The median is what the regression threshold compares;
# min and the interquartile range are printed so noise is visible.

suppressMessages(devtools::load_all(quiet = TRUE))
source("bench/workloads.R")

QIO_BENCH_DIR <- "bench/fixtures"
QIO_BENCH_RESULTS <- "bench/results"

# A case regresses only if its median moves by more than its tolerance.
#
# The tolerances are measured, not assumed: three full runs of one commit on one
# machine put every serial case under 3% run-to-run spread, but the two cases
# that use the worker pool at 11-12% because thread scheduling varies. A single
# 5% gate would therefore report false regressions on those two. See
# bench/README.md for the measurement.
QIO_BENCH_THRESHOLD <- 0.05
QIO_BENCH_TOLERANCE <- c(
  "collect-mmap" = 0.15,
  "read-mixed" = 0.15
)

qio_bench_tolerance <- function(case) {
  at <- match(case, names(QIO_BENCH_TOLERANCE))
  ifelse(is.na(at), QIO_BENCH_THRESHOLD, QIO_BENCH_TOLERANCE[at])
}

qio_bench_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  value_after <- function(flag, default) {
    at <- match(flag, argv)
    if (is.na(at) || at == length(argv)) default else argv[[at + 1L]]
  }
  list(
    reps = as.integer(value_after("--reps", "10")),
    warmup = as.integer(value_after("--warmup", "2")),
    filter = value_after("--filter", ""),
    save = if ("--save" %in% argv) value_after("--save", "baseline") else NA,
    compare = if ("--compare" %in% argv) {
      value_after("--compare", "baseline")
    } else {
      NA
    }
  )
}

qio_bench_environment <- function() {
  data.frame(
    r_version = paste0(R.version$major, ".", R.version$minor),
    platform = R.version$platform,
    sysname = Sys.info()[["sysname"]],
    machine = Sys.info()[["machine"]],
    cores = parallel::detectCores(),
    qio_commit = tryCatch(
      system2("git", c("rev-parse", "--short", "HEAD"), stdout = TRUE),
      error = function(e) NA_character_
    ),
    stringsAsFactors = FALSE
  )
}

# Generate every read fixture that does not exist yet. Returns a named vector
# of paths.
#
# Fixtures are written with Apache Arrow, not with qio, for two reasons. qio's
# writer flushes a row group only when carquet's byte target is exceeded
# (128MB), so a qio-written fixture of this size is a single row group and
# would exercise none of the multi-row-group paths phase 4 changes. And reading
# files produced by a mainstream writer is what users actually do, so the read
# baseline should measure that rather than qio reading its own output.
#
# arrow is a generation-time tool only. bench/ is excluded from the package and
# no test loads arrow; see bench/README.md.
qio_bench_fixtures <- function(workloads) {
  dir.create(QIO_BENCH_DIR, showWarnings = FALSE, recursive = TRUE)
  paths <- character()
  missing <- character()
  for (workload in workloads) {
    path <- file.path(QIO_BENCH_DIR, paste0(workload$name, ".parquet"))
    paths[[workload$name]] <- path
    if (!file.exists(path)) missing <- c(missing, workload$name)
  }
  if (length(missing) && !requireNamespace("arrow", quietly = TRUE)) {
    stop(
      "benchmark fixtures need the arrow package to generate (once):\n",
      "  install.packages(\"arrow\")\n",
      "missing: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  for (name in missing) {
    workload <- workloads[[name]]
    message("generating ", paths[[name]], " (", workload$rows, " rows)")
    arrow::write_parquet(
      qio_bench_data(workload),
      paths[[name]],
      compression = "snappy",
      chunk_size = QIO_BENCH_ROWS_PER_GROUP
    )
  }
  paths
}

# Median-of-`reps` wall time in seconds, after `warmup` untimed runs.
qio_bench_time <- function(expr, reps, warmup) {
  force(expr)
  for (i in seq_len(warmup)) {
    expr()
  }
  timings <- numeric(reps)
  for (i in seq_len(reps)) {
    gc(verbose = FALSE)
    start <- proc.time()[["elapsed"]]
    expr()
    timings[[i]] <- proc.time()[["elapsed"]] - start
  }
  timings
}

qio_bench_cases <- function(paths, workloads) {
  cases <- list()
  add <- function(name, fun) cases[[name]] <<- fun

  for (workload in workloads) {
    path <- paths[[workload$name]]
    local({
      p <- path
      add(paste0("read-", workload$name), function() invisible(read_parquet(p)))
    })
  }

  # These share the mixed fixture so their cost is comparable with read-mixed,
  # and each varies exactly one thing against collect-buffered. parquet_open()
  # defaults to mmap = FALSE, and parallel collect requires mmap, so the
  # persistent default is serial today.
  local({
    p <- paths[["mixed"]]
    collect_with <- function(...) {
      dots <- list(...)
      function() {
        file <- do.call(parquet_open, c(list(p), dots$open))
        on.exit(parquet_close(file))
        invisible(do.call(collect, c(list(file), dots$collect)))
      }
    }
    # Baseline for the persistent handle: buffered I/O, serial decode.
    add("collect-buffered", collect_with(open = list()))
    # Same read with mmap, which is what enables parallel collect.
    add("collect-mmap", collect_with(open = list(mmap = TRUE)))
    # mmap without parallelism, isolating the pool from the mapping.
    add(
      "collect-mmap-serial",
      collect_with(open = list(mmap = TRUE, threads = 1L))
    )
    # Projection and row-group selection, both against the buffered baseline.
    add(
      "collect-projection",
      collect_with(collect = list(columns = c("id", "value")))
    )
    add("collect-row-groups", collect_with(collect = list(row_groups = 1L)))
    add("walk-batches", function() {
      file <- parquet_open(p)
      on.exit(parquet_close(file))
      invisible(walk_batches(file, function(batch, index) NULL))
    })
  })

  # Writes measure the same data the read cases consume.
  for (name in c("numeric", "string_low_cardinality", "mixed")) {
    local({
      workload <- workloads[[name]]
      data <- qio_bench_data(workload)
      add(paste0("write-", name), function() {
        out <- tempfile(fileext = ".parquet")
        on.exit(unlink(out))
        invisible(write_parquet(data, out))
      })
    })
  }

  cases
}

qio_bench_run <- function(args = qio_bench_args()) {
  workloads <- qio_bench_workloads()
  paths <- qio_bench_fixtures(workloads)
  cases <- qio_bench_cases(paths, workloads)

  if (nzchar(args$filter)) {
    cases <- cases[grepl(args$filter, names(cases), fixed = TRUE)]
  }
  if (!length(cases)) {
    stop("no benchmark cases matched --filter", call. = FALSE)
  }

  rows <- lapply(names(cases), function(name) {
    message("running ", name)
    timings <- qio_bench_time(cases[[name]], args$reps, args$warmup)
    quartiles <- stats::quantile(timings, c(0.25, 0.75), names = FALSE)
    data.frame(
      case = name,
      median = stats::median(timings),
      min = min(timings),
      iqr = quartiles[[2]] - quartiles[[1]],
      reps = args$reps,
      stringsAsFactors = FALSE
    )
  })
  results <- do.call(rbind, rows)
  results$median <- round(results$median, 4L)
  results$min <- round(results$min, 4L)
  results$iqr <- round(results$iqr, 4L)
  results
}

qio_bench_compare <- function(results, tag) {
  path <- file.path(QIO_BENCH_RESULTS, paste0(tag, ".csv"))
  if (!file.exists(path)) {
    stop("no saved run named '", tag, "' in ", QIO_BENCH_RESULTS, call. = FALSE)
  }
  before <- utils::read.csv(path, stringsAsFactors = FALSE)
  merged <- merge(
    before[, c("case", "median")],
    results[, c("case", "median")],
    by = "case",
    suffixes = c("_before", "_after")
  )
  merged$change <- (merged$median_after - merged$median_before) /
    merged$median_before
  tolerance <- qio_bench_tolerance(merged$case)
  merged$verdict <- ifelse(
    merged$change > tolerance,
    "REGRESSION",
    ifelse(merged$change < -tolerance, "improved", "unchanged")
  )
  merged$tolerance <- sprintf("%.0f%%", 100 * tolerance)
  merged$change <- sprintf("%+.1f%%", 100 * merged$change)
  merged[, c(
    "case",
    "median_before",
    "median_after",
    "change",
    "tolerance",
    "verdict"
  )]
}

if (sys.nframe() == 0L) {
  args <- qio_bench_args()
  environment_row <- qio_bench_environment()
  print(environment_row)
  results <- qio_bench_run(args)
  print(results, row.names = FALSE)

  if (!is.na(args$save)) {
    dir.create(QIO_BENCH_RESULTS, showWarnings = FALSE, recursive = TRUE)
    out <- file.path(QIO_BENCH_RESULTS, paste0(args$save, ".csv"))
    utils::write.csv(cbind(results, environment_row), out, row.names = FALSE)
    message("saved ", out)
  }
  if (!is.na(args$compare)) {
    comparison <- qio_bench_compare(results, args$compare)
    print(comparison, row.names = FALSE)
    if (any(comparison$verdict == "REGRESSION")) {
      quit(status = 1L)
    }
  }
}
