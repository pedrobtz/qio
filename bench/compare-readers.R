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
      "compare-readers.R needs the ",
      package,
      " package:\n",
      '  install.packages("',
      package,
      '")',
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
    out = value_after("--out", ""),
    # The four cardinalities bracket the two points where the dictionary index
    # bit width crosses a kernel boundary. See the sweep section below.
    cardinalities = as.integer(strsplit(
      value_after("--cardinalities", "200,257,65536,65537"),
      ",",
      fixed = TRUE
    )[[1]])
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

# Force every column into a plain R vector, which is what qio always returns.
#
# This is subtler than it looks and the obvious version is wrong. arrow's R
# package returns ALTREP columns backed by Arrow buffers, and R answers some
# operations from ALTREP methods without ever allocating the vector -- sum() is
# one of them. An earlier version of this function used sum() and therefore
# timed arrow *not doing the allocation*, while qio did it. On a 5.8M x 4
# numeric file that reported qio 1.78x slower than arrow; forced properly it is
# 1.11x, and a 3.1M x 19 file moves from 1.07x slower to 0.81x faster.
#
# as.data.frame() does not help either: arrow::read_parquet() already returns a
# tibble whose columns are ALTREP, so converting it only changes the class --
# the column pointer is identical before and after.
#
# `c + 0` allocates a real double vector and was verified to leave no ALTREP
# behind. Strings need their CHARSXPs built, which nchar() forces. Both cost
# every reader the same.
materialize <- function(frame) {
  total <- 0
  for (column in frame) {
    total <- total +
      if (is.character(column)) {
        sum(nchar(column, type = "bytes"), na.rm = TRUE)
      } else if (is.list(column)) {
        sum(lengths(column))
      } else {
        # unclass() first: a Date or POSIXct column stays classed through
        # `+ 0`, and sum() is not defined for POSIXt. The `+ 0` forces ALTREP.
        sum(unclass(column) + 0, na.rm = TRUE)
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
  for (i in seq_len(warmup)) {
    run()
  }
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
          "readers disagree on ",
          workload,
          " written by ",
          writer,
          ": qio and ",
          name,
          " returned different results, so timing them would compare ",
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

# ------------------------------------------------------- cardinality sweep --

# The workloads above use one text cardinality each, which hid a real effect:
# qio's gap on dictionary-encoded text is not constant, it steps up as the
# dictionary grows. The cause is that a dictionary index is bit-packed to
# ceiling(log2(cardinality)) bits, and carquet has unrolled unpack kernels for
# widths 1-8 and 16 only -- every other width falls back to a byte-at-a-time
# loop. nanoparquet vendors fastpforlib, which has a kernel for all of 1-32.
#
# So the sweep brackets both boundaries: 200 and 257 straddle 8/9 bits, 65536
# and 65537 straddle 16/17. A build that closes the gap should flatten the
# ratio column, not merely lower it.
#
# Fixtures come from arrow, and the encoding is asserted rather than assumed:
# qio's own writer does not emit dictionary pages at all, so a qio-written
# fixture would measure the plain path and quietly answer a different question.
#
# The sweep needs rows to resolve. At the 1,000,000 default the 16 -> 17 bit
# step measures ~12%; at --rows 400000 the same step measures ~4%, because the
# whole read is then a few milliseconds and the step is inside the timer's
# noise. Do not conclude from a small --rows run that the effect is gone.

sweep_path <- function(k) file.path(directory, sprintf("card-%d.parquet", k))

index_bits <- function(k) max(1L, as.integer(ceiling(log2(k))))

sweep <- list()
for (k in args$cardinalities) {
  frame <- data.frame(
    label = sprintf("v-%06d", seq_len(args$rows) %% k),
    stringsAsFactors = FALSE
  )
  path <- sweep_path(k)
  arrow::write_parquet(
    frame,
    path,
    compression = "snappy",
    chunk_size = rows_per_group
  )

  # Assert the fixture is what the sweep claims to measure.
  handle <- qio::open_parquet(path)
  chunks <- qio::column_chunks(handle)
  qio::close_parquet(handle)
  if (!any(chunks$dictionary_page)) {
    stop(
      "cardinality ",
      k,
      " fixture has no dictionary page, so timing it would ",
      "measure the plain path instead of the dictionary path.",
      call. = FALSE
    )
  }

  values <- lapply(readers, function(read) as.data.frame(read(path)))
  for (name in names(values)[-1]) {
    if (!isTRUE(all.equal(values[[1]], values[[name]]))) {
      stop(
        "readers disagree on the cardinality ",
        k,
        " fixture: qio and ",
        name,
        " returned different results, so timing them would compare different ",
        "work.",
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
      sweep[[length(sweep) + 1L]] <<- data.frame(
        cardinality = k,
        bits = index_bits(k),
        reader = name,
        median = median(timings),
        min = min(timings),
        stringsAsFactors = FALSE
      )
    })
  }
}

sweep <- do.call(rbind, sweep)

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
  order <- c(
    "workload",
    intersect(c("qio", "arrow", "nanoparquet"), names(wide))
  )
  wide <- wide[, order]

  label_width <- max(nchar(wide$workload), nchar("workload"))
  cat(sprintf("%-*s", label_width, "workload"))
  for (name in order[-1]) {
    cat(sprintf("  %11s", name))
  }
  cat(sprintf("  %s\n", "qio vs best other"))
  for (i in seq_len(nrow(wide))) {
    cat(sprintf("%-*s", label_width, wide$workload[i]))
    for (name in order[-1]) {
      cat(sprintf("  %11.4f", wide[[name]][i]))
    }
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

cat("--- dictionary index bit width sweep (files written by arrow) ---\n")
cat("A flat ratio column means the bit width no longer matters.\n\n")
cat(sprintf(
  "%12s  %5s  %11s  %11s  %11s  %s\n",
  "cardinality",
  "bits",
  "qio",
  "arrow",
  "nanoparquet",
  "qio vs best other"
))
for (k in args$cardinalities) {
  block <- sweep[sweep$cardinality == k, ]
  pick <- function(name) block$median[block$reader == name]
  others <- vapply(setdiff(names(readers), "qio"), pick, numeric(1))
  ratio <- pick("qio") / min(others)
  cat(sprintf(
    "%12d  %5d  %11.4f  %11.4f  %11.4f  %.2fx %s\n",
    k,
    index_bits(k),
    pick("qio"),
    pick("arrow"),
    pick("nanoparquet"),
    ratio,
    if (ratio < 1) "faster" else "slower"
  ))
}
cat("\n")

cat(paste(
  "Read as: one machine, one build, one set of shapes, timed to materialized",
  "data rather than to the return of each read call. nanoparquet is",
  "single-threaded by design, so its column is a different trade-off rather",
  "than simply a slower one. Rerun before quoting.\n"
))

if (nzchar(args$out)) {
  # One frame, so a later run can be diffed against this one without joining
  # two files. The sections carry different keys, hence the NA columns.
  results$section <- "workload"
  results$cardinality <- NA_integer_
  results$bits <- NA_integer_
  sweep$section <- "cardinality"
  sweep$workload <- "text"
  sweep$writer <- "arrow"
  written <- rbind(results, sweep[, names(results)])
  written$rows <- args$rows
  written$platform <- R.version$platform
  utils::write.csv(written, args$out, row.names = FALSE)
  cat("\nwrote", args$out, "\n")
}

# GitHub renders this file as the job summary, so the tables are visible without
# opening the log or downloading the artifact. Same treatment as
# bench/ci-benchmark.R, and a no-op outside Actions.
summary_file <- Sys.getenv("GITHUB_STEP_SUMMARY", "")
if (nzchar(summary_file)) {
  ratio_cell <- function(qio, others) {
    ratio <- qio / min(others)
    sprintf("%.2fx %s", ratio, if (ratio < 1) "faster" else "slower")
  }

  lines <- c(
    "### qio read comparison",
    "",
    sprintf(
      "%s rows, %d row groups, snappy, %d reps after %d warmup.",
      format(args$rows, big.mark = ","),
      max(1L, ceiling(args$rows / rows_per_group)),
      args$reps,
      args$warmup
    ),
    sprintf(
      "qio %s, arrow %s (%d threads), nanoparquet %s (single-threaded), %s.",
      utils::packageVersion("qio"),
      utils::packageVersion("arrow"),
      arrow::cpu_count(),
      utils::packageVersion("nanoparquet"),
      R.version$platform
    )
  )

  for (writer in unique(results$writer)) {
    block <- results[results$writer == writer, ]
    wide <- reshape(
      block[, c("workload", "reader", "median")],
      idvar = "workload",
      timevar = "reader",
      direction = "wide"
    )
    names(wide) <- sub("^median\\.", "", names(wide))
    # Not `readers`: that name holds the reader list this whole script runs
    # from, and rebinding it here left names(readers) NULL for the sweep table
    # below, so every sweep ratio printed as 0.00x.
    shown <- intersect(c("qio", "arrow", "nanoparquet"), names(wide))
    lines <- c(
      lines,
      "",
      sprintf("**Files written by %s** (median seconds)", writer),
      "",
      paste0(
        "| workload | ",
        paste(shown, collapse = " | "),
        " | qio vs best other |"
      ),
      paste0("|---|", strrep("---:|", length(shown)), "---|"),
      vapply(
        seq_len(nrow(wide)),
        function(i) {
          sprintf(
            "| `%s` | %s | %s |",
            wide$workload[i],
            paste(sprintf("%.4f", unlist(wide[i, shown])), collapse = " | "),
            ratio_cell(wide$qio[i], unlist(wide[i, setdiff(shown, "qio")]))
          )
        },
        character(1)
      )
    )
  }

  lines <- c(
    lines,
    "",
    "**Dictionary index bit width sweep** (files written by arrow)",
    "",
    "| cardinality | bits | qio | arrow | nanoparquet | qio vs best other |",
    "|---:|---:|---:|---:|---:|---|",
    vapply(
      args$cardinalities,
      function(k) {
        # `sweep` is long, one row per (cardinality, reader), the same shape
        # the printed table reads from.
        block <- sweep[sweep$cardinality == k, ]
        pick <- function(name) block$median[block$reader == name]
        sprintf(
          "| %s | %d | %.4f | %.4f | %.4f | %s |",
          format(k, big.mark = ","),
          index_bits(k),
          pick("qio"),
          pick("arrow"),
          pick("nanoparquet"),
          ratio_cell(
            pick("qio"),
            vapply(setdiff(names(readers), "qio"), pick, numeric(1))
          )
        )
      },
      character(1)
    ),
    "",
    "A flat ratio column means the dictionary index bit width no longer matters.",
    "",
    paste(
      "Shared runners are noisy and these are one machine, one build, one set",
      "of shapes. Timed to *materialized* data rather than to the return of",
      "each read call, so deferred work is charged to whoever deferred it.",
      "nanoparquet is single-threaded by design, so its column is a different",
      "trade-off rather than simply a slower one. Rerun before quoting."
    )
  )
  cat(paste(lines, collapse = "\n"), "\n", file = summary_file, append = TRUE)
}
