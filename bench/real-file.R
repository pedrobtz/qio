#!/usr/bin/env Rscript
#
# Compare qio, arrow and nanoparquet on a real Parquet file, and report where
# the time goes column by column.
#
#   Rscript bench/real-file.R path/to/file.parquet
#   Rscript bench/real-file.R path/to/file.parquet --reps 7 --out real.csv
#   Rscript bench/real-file.R --fetch          # print how to get a public file
#
# Why this exists, and why it is not bench/compare-readers.R.
#
# compare-readers.R generates its own data, so it can only contain what someone
# thought to generate. That is the right tool for a controlled A/B -- it fixes
# the shape and varies the reader -- but it cannot find a pathology nobody
# anticipated. It did not.
#
# The first real file ever pointed at qio, the January 2023 NYC taxi trip data,
# read in 83.2 seconds against arrow's 0.195 and nanoparquet's 0.541: 426x
# slower, every value correct. Two of nineteen columns held 85 of those 83
# seconds. Both were TIMESTAMP columns whose civil components were being
# re-anchored through formatted text, one value at a time, in R. The same
# afternoon that also turned up a silent correctness bug in that code, and two
# more converters with the same shape.
#
# None of that was visible in the generated benchmarks, which had spent six
# stages measuring dictionary text.
#
# So this script exists to be pointed at files nobody designed. Its most useful
# output is not the total but the per-column table: a single column taking a
# thousand times its neighbours is the signature of per-value work in R, and
# that is what the "SLOW" marker flags.

readers_wanted <- c("arrow", "nanoparquet")

# ---------------------------------------------------------------- arguments --

argv <- commandArgs(trailingOnly = TRUE)

if ("--fetch" %in% argv || length(argv) == 0L) {
  cat(
    "Point this at any Parquet file. Public files worth trying:\n\n",
    "  NYC taxi trips (~47 MB, 3.1M rows, 19 columns, GZIP, all dictionary-\n",
    "  encoded, two TIMESTAMP columns):\n",
    "    curl -O https://d37ci6vzurychx.cloudfront.net/trip-data/",
    "yellow_tripdata_2023-01.parquet\n\n",
    "  Then:\n",
    "    Rscript bench/real-file.R yellow_tripdata_2023-01.parquet\n\n",
    "Nothing is downloaded automatically and no data is committed: the point\n",
    "is to run against files this repository did not choose.\n",
    sep = ""
  )
  quit(status = if (length(argv) == 0L) 1L else 0L)
}

path <- argv[[1L]]
value_after <- function(flag, default) {
  at <- match(flag, argv)
  if (is.na(at) || at == length(argv)) default else argv[[at + 1L]]
}
reps <- as.integer(value_after("--reps", "5"))
warmup <- as.integer(value_after("--warmup", "2"))
out <- value_after("--out", "")

if (!file.exists(path)) {
  stop("no such file: ", path, call. = FALSE)
}
suppressMessages(library(qio))
available <- readers_wanted[vapply(
  readers_wanted,
  function(p) requireNamespace(p, quietly = TRUE),
  logical(1)
)]

# ------------------------------------------------------------------ helpers --

# Touch every value, so a reader that returns a promise is charged for keeping
# it. arrow's R package uses ALTREP: without this it is timed on returning
# rather than on reading. See bench/README.md.
materialize <- function(frame) {
  total <- 0
  for (column in frame) {
    total <- total +
      if (is.character(column)) {
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
  for (i in seq_len(warmup)) {
    run()
  }
  median(vapply(seq_len(reps), function(i) run(), numeric(1)))
}

read_with <- list(
  qio = function(p) suppressWarnings(suppressMessages(qio::read_parquet(p))),
  arrow = function(p) as.data.frame(arrow::read_parquet(p)),
  nanoparquet = function(p) as.data.frame(nanoparquet::read_parquet(p))
)

# --------------------------------------------------------------- the file --

file <- qio::parquet_open(path)
shape <- dim(file)
groups <- nrow(qio::row_groups(file))
chunks <- qio::column_chunks(file)
plan <- qio::read_plan(file)
qio::parquet_close(file)

cat(sprintf("\n%s\n", basename(path)))
cat(sprintf(
  "%s rows x %d columns, %d row group%s, %s on disk\n",
  format(shape[[1L]], big.mark = ","),
  shape[[2L]],
  groups,
  if (groups == 1L) "" else "s",
  format(structure(file.size(path), class = "object_size"), units = "auto")
))
cat(sprintf(
  "codecs: %s\n%s, %s, %d cores\n\n",
  paste(unique(chunks$compression), collapse = ", "),
  R.version.string,
  R.version$platform,
  parallel::detectCores()
))

# ------------------------------------------------------------- agreement --

# Values before timings. Readers that disagree are not doing the same work, and
# comparing them would be meaningless. Compared as doubles because the three
# packages map 64-bit integers differently by design; that is a documented
# difference in behaviour, not a defect to fail on.
signature <- function(frame) {
  vapply(
    frame,
    function(column) {
      if (is.character(column)) {
        sum(nchar(column, type = "bytes"), na.rm = TRUE)
      } else {
        sum(as.numeric(column), na.rm = TRUE)
      }
    },
    numeric(1)
  )
}

cat("--- agreement ---\n")
reference <- signature(read_with$qio(path))
invisible(gc(verbose = FALSE))
for (name in available) {
  other <- try(signature(read_with[[name]](path)), silent = TRUE)
  if (inherits(other, "try-error")) {
    cat(sprintf("  %-12s could not read this file\n", name))
    next
  }
  same <- length(other) == length(reference) &&
    isTRUE(all.equal(unname(reference), unname(other), tolerance = 1e-8))
  cat(sprintf("  %-12s agrees with qio: %s\n", name, same))
  if (!same && length(other) == length(reference)) {
    differing <- names(reference)[abs(reference - other) > 1e-6]
    cat(sprintf(
      "      differing columns: %s\n",
      paste(differing, collapse = ", ")
    ))
  }
  rm(other)
  invisible(gc(verbose = FALSE))
}

# --------------------------------------------------------------- whole file --

cat("\n--- whole file, median seconds to materialized data ---\n")
totals <- c(
  qio = time_it(function() materialize(read_with$qio(path)), reps, warmup)
)
for (name in available) {
  totals[[name]] <- time_it(
    function() materialize(read_with[[name]](path)),
    reps,
    warmup
  )
}
for (name in names(totals)) {
  cat(sprintf("  %-12s %8.3f s\n", name, totals[[name]]))
}
if (length(totals) > 1L) {
  best <- min(totals[names(totals) != "qio"])
  ratio <- totals[["qio"]] / best
  cat(sprintf(
    "\n  qio vs best other: %.2fx %s\n",
    ratio,
    if (ratio < 1) "faster" else "slower"
  ))
}

# --------------------------------------------------------------- per column --

# The part that earns this script's keep. A column costing far more than its
# peers is the signature of per-value work, and it is invisible in the total
# once averaged across a wide frame.
cat("\n--- qio, per column ---\n")
per_column <- vapply(
  plan$name,
  function(name) {
    handle <- qio::parquet_open(path)
    on.exit(qio::parquet_close(handle), add = TRUE)
    time_it(
      function() {
        invisible(suppressWarnings(suppressMessages(
          qio::collect(handle, columns = name)
        )))
      },
      reps = max(1L, reps %/% 2L),
      warmup = 1L
    )
  },
  numeric(1)
)

typical <- median(per_column)
order_by_cost <- order(per_column, decreasing = TRUE)
width <- max(nchar(plan$name), nchar("column"))
cat(sprintf(
  "%-*s  %9s  %8s  %s\n",
  width,
  "column",
  "seconds",
  "x median",
  "converter"
))
for (i in order_by_cost) {
  ratio <- per_column[[i]] / max(typical, 1e-9)
  cat(sprintf(
    "%-*s  %9.3f  %7.1fx  %s%s\n",
    width,
    plan$name[[i]],
    per_column[[i]],
    ratio,
    plan$converter[[i]],
    if (ratio >= 20) "   <- SLOW" else ""
  ))
}
cat(sprintf(
  "\nmedian column %.3f s; anything at 20x that is marked SLOW and is worth a\nprofile before anything else is tuned.\n",
  typical
))

if (nzchar(out)) {
  frame <- data.frame(
    file = basename(path),
    column = plan$name,
    converter = plan$converter,
    seconds = unname(per_column),
    rows = shape[[1L]],
    platform = R.version$platform,
    stringsAsFactors = FALSE
  )
  for (name in names(totals)) {
    frame[[paste0("total_", name)]] <- totals[[name]]
  }
  utils::write.csv(frame, out, row.names = FALSE)
  cat("wrote", out, "\n")
}
