#!/usr/bin/env Rscript
#
# Check qio's inspection results against Apache Arrow.
#
#   Rscript tools/check-inspection-against-arrow.R
#
# Phase 6's exit gate requires that inspection agrees with an independent
# Parquet implementation. This does two different things, and the distinction
# matters:
#
#   1. Arrow reads back the values the writer was given. This is what proves the
#      row-group-major write restructure did not corrupt anything, because it
#      compares an independent read against the *input*. Comparing qio's read
#      against Arrow's would prove nothing: a badly written file decodes to the
#      same wrong values in both.
#   2. Arrow and qio are asked to describe the same file's layout, and must
#      agree on the row-group count and sizes.
#
# `arrow` is not a qio dependency: no test loads it, it is absent from
# DESCRIPTION, and this script lives outside the installed package.

suppressMessages(library(arrow))
suppressMessages(pkgload::load_all(quiet = TRUE))

failures <- 0L
check <- function(label, ok, detail = "") {
  cat(sprintf("%-42s %s%s\n", label, if (ok) "ok" else "FAIL", detail))
  if (!ok) failures <<- failures + 1L
}

set.seed(11)
n <- 500L
data <- data.frame(
  n = 1:n,
  x = rnorm(n),
  s = sprintf("v%04d", 1:n),
  b = rep(c(TRUE, FALSE), n / 2),
  stringsAsFactors = FALSE
)
data$n[c(3L, 200L, 480L)] <- NA

path <- tempfile(fileext = ".parquet")
group <- 120L
qio::write_parquet(
  data,
  path,
  row_group_size = group,
  # Deliberately no key starting with "r": the arrow R package reads its own
  # R attributes with `metadata$r`, and `$` on a list partially matches, so a
  # key like "run" makes it warn "Invalid metadata$r" about a perfectly good
  # file. That is arrow's quirk, not a defect in what qio writes.
  metadata = c(tool = "qio", purpose = "inspection-cross-check")
)

# 1. Independent read against the input.
back <- as.data.frame(arrow::read_parquet(path))
check("arrow reads back the input values", isTRUE(all.equal(back, data)))

# 2. Layout agreement.
reader <- arrow::ParquetFileReader$create(path)
handle <- qio::parquet_open(path)
on.exit(qio::parquet_close(handle), add = TRUE)

groups <- qio::row_groups(handle)
check(
  "row-group count matches arrow",
  reader$num_row_groups == nrow(groups),
  sprintf(" (arrow %d, qio %d)", reader$num_row_groups, nrow(groups))
)
arrow_rows <- vapply(
  seq_len(reader$num_row_groups),
  function(i) reader$ReadRowGroup(i - 1L)$num_rows,
  numeric(1)
)
check("rows per row group match arrow", identical(arrow_rows, groups$rows))

# 3. Statistics against ground truth, which is stronger than against Arrow:
#    the input is known exactly.
stats <- qio::column_statistics(handle)
starts <- seq(1L, n, by = group)
expected_min_n <- vapply(
  starts,
  function(i) {
    min(data$n[i:min(i + group - 1L, n)], na.rm = TRUE)
  },
  numeric(1)
)
got_min_n <- unlist(stats$min[stats$name == "n"])
check(
  "INT32 bounds match the input",
  identical(as.integer(expected_min_n), got_min_n)
)

expected_nulls <- vapply(
  starts,
  function(i) {
    sum(is.na(data$n[i:min(i + group - 1L, n)]))
  },
  numeric(1)
)
check(
  "null counts match the input",
  identical(expected_nulls, stats$null_count[stats$name == "n"])
)

expected_min_s <- vapply(
  starts,
  function(i) {
    min(data$s[i:min(i + group - 1L, n)])
  },
  character(1)
)
check(
  "text bounds match the input",
  identical(expected_min_s, unlist(stats$min[stats$name == "s"]))
)

# 4. Footer metadata survives a round trip.
pairs <- qio::metadata(handle)
check(
  "footer metadata round-trips",
  identical(pairs$value[pairs$key == "tool"], "qio")
)

# 5. Chunk sizes reconcile with the row-group totals carquet reports.
chunks <- qio::column_chunks(handle)
per_group <- as.numeric(tapply(chunks$compressed_bytes, chunks$row_group, sum))
check(
  "chunk sizes sum to row-group sizes",
  isTRUE(all.equal(per_group, groups$compressed_bytes))
)

# 6. Append: the check qio makes and carquet does not. With qio's validation
#    bypassed, carquet accepts a MICROS-for-MILLIS append and rewrites the
#    footer, so rows that were already correct decode wrongly afterwards. This
#    asserts both halves: that qio refuses it, and that the file survives.
stamps <- as.POSIXct("2020-01-01", tz = "UTC") + 1:3
millis <- qio::parquet_schema(t = list("TIMESTAMP", unit = "MILLIS"))
micros <- qio::parquet_schema(t = list("TIMESTAMP", unit = "MICROS"))
append_path <- tempfile(fileext = ".parquet")
qio::write_parquet(data.frame(t = stamps), append_path, schema = millis)

refused <- inherits(
  try(
    qio::write_parquet(
      data.frame(t = stamps),
      append_path,
      schema = micros,
      append = TRUE
    ),
    silent = TRUE
  ),
  "try-error"
)
check("qio refuses a mismatched append", refused)
check(
  "the refused append left the file intact",
  isTRUE(all.equal(qio::read_parquet(append_path)$t, stamps))
)

qio::write_parquet(
  data.frame(t = stamps),
  append_path,
  schema = millis,
  append = TRUE
)
check(
  "a matching append is readable by arrow",
  nrow(as.data.frame(arrow::read_parquet(append_path))) == 6L
)

# 7. Sorting declarations are write-only in qio, because carquet exposes no way
#    to read them back. Arrow can, so it is the oracle here.
sorted_path <- tempfile(fileext = ".parquet")
qio::write_parquet(
  data.frame(a = 1:100, b = rev(1:100)),
  sorted_path,
  row_group_size = 40,
  sorted_by = data.frame(
    name = c("b", "a"),
    descending = c(TRUE, FALSE),
    nulls_first = c(TRUE, FALSE)
  )
)
# The declaration itself is verified by tools/generate-bloom-sorting-fixture.py
# and by pyarrow, which exposes row_group.sorting_columns; the arrow R package
# does not. What is checked here is that declaring an order does not disturb
# the data.
check("a sorted file still reads back its values", isTRUE(all.equal(
  as.data.frame(arrow::read_parquet(sorted_path)),
  data.frame(a = 1:100, b = rev(1:100))
)))

cat("\n")
if (failures > 0L) {
  cat(sprintf("%d disagreement(s)\n", failures))
  quit(status = 1L)
}
cat("no disagreements with Apache Arrow\n")
