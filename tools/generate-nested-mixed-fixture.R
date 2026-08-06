# Generates tests/testthat/parquet/nested_mixed.parquet and its expected values.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# A file holding both what qio reads and what it skips, in one schema. The
# Apache corpus has nested files, but they are nested-only or nearly so, which
# leaves the interesting case untested: a frame where flat and nested columns
# are interleaved, so skipping the nested ones must not disturb the position,
# order, or values of the flat ones around them.
#
# The reference records the *absence* of the nested columns rather than any
# value for them. That is qio's contract in v0.1.0 -- nested leaves are skipped
# with one message per operation -- so the expectation is a frame of the flat
# columns only, in schema order, with the nested names gone.
#
# As with generate-temporal-fixture.R: every expected value is derived from what
# is written here, in base R, and qio is never loaded. A reference produced by
# reading the file with qio would pin current behaviour, bugs included.

n <- 5L

# Flat columns, deliberately placed before, between, and after the nested ones.
ids <- c(1L, 2L, 3L, 4L, NA_integer_)
labels <- c("alpha", NA, "gamma", "delta", "epsilon")
amounts <- c(0, -1.5, 2.25, NA, 1e6)
flags <- c(TRUE, FALSE, NA, TRUE, FALSE)
days <- as.Date("2020-01-01") + c(0L, 31L, NA, 200L, 365L)
instants <- as.POSIXct(
  c(
    "2020-01-01 00:00:00",
    NA,
    "2020-06-15 12:30:45",
    "1970-01-01 00:00:00",
    "2038-01-19 03:14:07"
  ),
  tz = "UTC"
)

# Nested columns qio skips: a LIST of integers, carrying a null and an empty
# container because those are the shapes that make repetition levels
# non-trivial, and a struct with two leaves under one parent.
numbers <- list(1:3, integer(0), NULL, 7L, c(8L, 9L))
# A struct rather than a MAP: arrow's R bindings cannot construct a MAP array,
# and MAP is already covered by nested_maps.snappy.parquet from the Apache
# corpus. A struct exercises the other shape qio skips -- several leaves under
# one parent -- which is what makes column identity by leaf path matter.
people <- data.frame(
  name = c("ana", NA, "bo", "cy", "di"),
  score = c(1.5, 2.5, NA, 4.5, 5.5),
  stringsAsFactors = FALSE
)

table <- arrow::arrow_table(
  id = arrow::Array$create(ids),
  numbers = arrow::Array$create(numbers, type = arrow::list_of(arrow::int32())),
  label = arrow::Array$create(labels),
  person = arrow::Array$create(
    people,
    type = arrow::struct(name = arrow::utf8(), score = arrow::float64())
  ),
  amount = arrow::Array$create(amounts),
  flag = arrow::Array$create(flags),
  day = arrow::Array$create(days),
  instant = arrow::Array$create(instants)
)

out <- "tests/testthat/parquet/nested_mixed.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")

# --- Independent expected values -------------------------------------------
#
# The flat columns only, in schema order. `numbers` and the `person` struct are absent
# because qio skips nested leaves; their absence is the assertion.

expected <- data.frame(
  id = ids,
  label = labels,
  amount = amounts,
  flag = flags,
  day = days,
  instant = instants,
  stringsAsFactors = FALSE
)

reference <- "tests/testthat/parquet/nested_mixed-expected.rds"
saveRDS(expected, reference, version = 2L)
cat("wrote:", reference, "\n")
cat("kept:", paste(names(expected), collapse = ", "), "\n")
cat("skipped:", "numbers, person.name, person.score", "\n")
