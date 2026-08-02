#!/usr/bin/env Rscript
#
# Compare qio's read speed against other R Parquet readers.
#
#   Rscript bench/compare-readers.R
#   Rscript bench/compare-readers.R --rows 2000000 --reps 7 --out compare.csv
#
# Needs the arrow and nanoparquet packages. Neither is a qio dependency; this
# script lives in bench/, which is excluded from the source package, and no test
# loads either one.
#
# Comparing packages is a claim about someone else's software, so this is built
# to be refutable rather than flattering:
#
#   - Every reader is handed the same file, and the files are written by *both*
#     arrow and qio. A reader tuned for its own writer's layout shows up as a
#     difference between the two writers rather than as a win.
#   - Results are compared before they are timed. If two readers disagree, they
#     are not doing the same work and the timing is meaningless, so the script
#     stops rather than reporting it.
#   - Only columns all three map identically are used. Where the mappings differ
#     -- 64-bit integers are the obvious case -- a comparison would be measuring
#     a difference in behavior, not in speed.
#   - Thread counts are reported, because they are not the same. arrow and qio
#     both use several threads by default; nanoparquet is single-threaded by
#     design, so its column is a different trade-off, not simply a slower one.
#   - Every reader is timed to *materialized* data, not to the return of its
#     read function. This is the one that matters most. arrow's R package uses
#     ALTREP, so read_parquet() can return before the values exist and charge
#     the cost to whoever first touches them: on a 500k-row string column,
#     reading measured 0.011s and forcing the same data measured 0.048s. qio
#     materializes eagerly, so timing the bare call compared qio doing all the
#     work against arrow doing a fraction of it, and reported qio as 9x slower
#     on text when the forced figures are level. Each case therefore sums over
#     every column after reading, which costs all three readers the same and
#     charges deferred work to whoever deferred it.
#
# Numbers come from one machine and one build. They are not a benchmark result
# anyone should quote without rerunning; see bench/README.md.

for (package in c("arrow", "nanoparquet")) {
  if (!requireNamespace(package, quietly = TRUE)) {
    stop(
      "compare-readers.R needs the ", package, " package:\n",
      '  install.packages("', package, '")',
      call. = FALSE
    )
  }
}
suppressMessages(library(qio))

# ---------------------------------------------------------------- arguments --

parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  value_after <- function(flag, default) {
    at <- match(flag, argv)
    if (is.na(at) || at == length(argv)) default else argv[[at + 1L]]
  }
  list(
    rows = as.integer(value_after("--rows", "1000000")),
    reps = as.integer(value_after("--reps", "5")),
    warmup = as.integer(value_after("--warmup", "1")),
    out = value_after("--out", "")
  )
}

args <- parse_args()

# ----------------------------------------------------------------- workloads --

set.seed(20260802L)

# Types every one of the three maps the same way. Deliberately no INT64 beyond
# the double-exact range, no decimals, and no binary: those differ between the
# packages, and timing a difference in behavior is not a speed comparison.
workloads <- list(
  numeric = function(n) {
    data.frame(
      id = seq_len(n),
      price = stats::rnorm(n),
      ratio = stats::runif(n),
      flag = rep(c(TRUE, FALSE), length.out = n)
    )
  },
  text_dictionary = function(n) {
    data.frame(
      label = sprintf("label-%04d", seq_len(n) %% 500L),
      bucket = sprintf("b-%02d", seq_len(n) %% 20L),
      stringsAsFactors = FALSE
    )
  },
  text_unique = function(n) {
    data.frame(
      code = sprintf("%s-%09d", sample(LETTERS, n, replace = TRUE), seq_len(n)),
      stringsAsFactors = FALSE
    )
  },
  mixed_nulls = function(n) {
    blank <- function(x) {
      x[seq(1L, n, by = 10L)] <- NA
      x
    }
    data.frame(
      id = blank(seq_len(n)),
      price = blank(stats::rnorm(n)),
      label = blank(sprintf("label-%04d", seq_len(n) %% 500L)),
      day = blank(as.Date("2020-01-01") + (seq_len(n) %% 3650L)),
      stringsAsFactors = FALSE
    )
  }
)

rows_per_group <- max(1L, args$rows %/% 4L)

directory <- tempfile("qio-compare-")
dir.create(directory)
on.exit(unlink(directory, recursive = TRUE), add = TRUE)

readers <- list(
  qio = function(path) qio::read_parquet(path),
  arrow = function(path) arrow::read_parquet(path),
  nanoparquet = function(path) nanoparquet::read_parquet(path)
)

# Touch every value, so a reader that returns a promise is charged for keeping
# it. Cheap relative to reading, and identical for all three readers.
materialize <- function(frame) {
  total <- 0
  for (column in frame) {
    total <- total + if (is.character(column)) {
      sum(nchar(column, type = "bytes"), na.rm = TRUE)
    } else {
      sum(as.numeric(column), na.rm = TRUE)
    }
  }
  invisible(total)
}

time_it <- function(action, reps, warmup) {
  run <- function() {
    gc(verbose = FALSE)
    started <- proc.time()[["elapsed"]]
    action()
    proc.time()[["elapsed"]] - started
  }
  for (i in seq_len(warmup)) run()
  vapply(seq_len(reps), function(i) run(), numeric(1))
}

# --------------------------------------------------------------------- run --

results <- list()

for (workload in names(workloads)) {
  frame <- workloads[[workload]](args$rows)

  # Both writers, so a layout advantage is visible instead of hidden.
  written <- list(
    qio = file.path(directory, paste0(workload, "-qio.parquet")),
    arrow = file.path(directory, paste0(workload, "-arrow.parquet"))
  )
  qio::write_parquet(
    frame,
    written$qio,
    compression = "snappy",
    row_group_size = rows_per_group
  )
  arrow::write_parquet(
    frame,
    written$arrow,
    compression = "snappy",
    chunk_size = rows_per_group
  )

  for (writer in names(written)) {
    path <- written[[writer]]

    # Agreement first. Timing readers that disagree measures different work.
    values <- lapply(readers, function(read) as.data.frame(read(path)))
    for (name in names(values)[-1]) {
      if (!isTRUE(all.equal(values[[1]], values[[name]]))) {
        stop(
          "readers disagree on ", workload, " written by ", writer, ": qio and ",
          name, " returned different results, so timing them would compare ",
          "different work.",
          call. = FALSE
        )
      }
    }

    for (name in names(readers)) {
      local({
        read <- readers[[name]]
        timings <- time_it(
          function() materialize(read(path)),
          args$reps,
          args$warmup
        )
        results[[length(results) + 1L]] <<- data.frame(
          workload = workload,
          writer = writer,
          reader = name,
          median = median(timings),
          min = min(timings),
          stringsAsFactors = FALSE
        )
      })
    }
  }
}

results <- do.call(rbind, results)

# ------------------------------------------------------------------ report --

cat("\nqio read comparison\n")
cat(sprintf(
  "%d rows, %d row groups, snappy, %d reps after %d warmup\n",
  args$rows,
  max(1L, ceiling(args$rows / rows_per_group)),
  args$reps,
  args$warmup
))
cat(sprintf(
  "%s, %s, %d cores\n",
  R.version.string,
  R.version$platform,
  parallel::detectCores()
))
cat(sprintf(
  "qio %s (threads: auto), arrow %s (threads: %d), nanoparquet %s (single-threaded)\n\n",
  utils::packageVersion("qio"),
  utils::packageVersion("arrow"),
  arrow::cpu_count(),
  utils::packageVersion("nanoparquet")
))

for (writer in unique(results$writer)) {
  cat(sprintf("--- files written by %s ---\n", writer))
  block <- results[results$writer == writer, ]
  wide <- reshape(
    block[, c("workload", "reader", "median")],
    idvar = "workload",
    timevar = "reader",
    direction = "wide"
  )
  names(wide) <- sub("^median\\.", "", names(wide))
  order <- c("workload", intersect(c("qio", "arrow", "nanoparquet"), names(wide)))
  wide <- wide[, order]

  label_width <- max(nchar(wide$workload), nchar("workload"))
  cat(sprintf("%-*s", label_width, "workload"))
  for (name in order[-1]) cat(sprintf("  %11s", name))
  cat(sprintf("  %s\n", "qio vs best other"))
  for (i in seq_len(nrow(wide))) {
    cat(sprintf("%-*s", label_width, wide$workload[i]))
    for (name in order[-1]) cat(sprintf("  %11.4f", wide[[name]][i]))
    others <- setdiff(order[-1], "qio")
    best <- min(unlist(wide[i, others]))
    ratio <- wide$qio[i] / best
    cat(sprintf(
      "  %.2fx %s\n",
      ratio,
      if (ratio < 1) "faster" else "slower"
    ))
  }
  cat("\n")
}

cat(paste(
  "Read as: one machine, one build, one set of shapes, timed to materialized",
  "data rather than to the return of each read call. nanoparquet is",
  "single-threaded by design, so its column is a different trade-off rather",
  "than simply a slower one. Rerun before quoting.\n"
))

if (nzchar(args$out)) {
  results$rows <- args$rows
  results$platform <- R.version$platform
  utils::write.csv(results, args$out, row.names = FALSE)
  cat("\nwrote", args$out, "\n")
}
