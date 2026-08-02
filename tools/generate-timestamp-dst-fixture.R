# Generates tests/testthat/parquet/timestamp_dst.parquet and its expected values
# for two time zones. Run manually; arrow is not a qio dependency.
# Provenance: parquet/SOURCE.md.
#
# A non-UTC TIMESTAMP stores civil components with no zone, so reading it means
# re-anchoring them in `tz`. Two civil times make that interesting, and neither
# appears in temporal_types.parquet:
#
#   - one inside a spring-forward gap, which has no instant in the zone at all;
#   - one inside a fall-back overlap, which has two.
#
# This exists because of a bug that shipped. qio re-anchored through formatted
# text, and as.POSIXct.character picks a format by requiring *every* value to
# parse. The gap value returned NA from strptime, which rejected the datetime
# format and fell through to a date-only one -- so a single unrepresentable
# value silently reduced every other value in the column to midnight. The
# generated benchmarks could not see it and no fixture contained it.
#
# The reference is therefore written for two zones: UTC, where nothing is
# ambiguous, and America/New_York, where both boundary values bite. Every
# expected value is computed in base R from the civil strings below; qio is
# never loaded here.

civil <- c(
  "2023-06-01 09:15:30", # ordinary, summer
  "2023-03-12 02:30:00", # does not exist in New York: 02:00 jumps to 03:00
  "2023-11-05 01:30:00", # occurs twice in New York: 02:00 falls back to 01:00
  NA,
  "2023-12-24 00:07:06" # ordinary, winter
)

# Written as a zone-less wall clock. Reading them as UTC is how the civil
# components get into the file unchanged.
wall <- as.POSIXct(civil, tz = "UTC")

table <- arrow::arrow_table(
  wall_ms = arrow::Array$create(wall)$cast(arrow::timestamp("ms")),
  wall_us = arrow::Array$create(wall)$cast(arrow::timestamp("us")),
  # A UTC-adjusted column alongside, as the control: it is an instant, so
  # changing `tz` must move nothing but the printed zone.
  instant_us = arrow::Array$create(wall)$cast(arrow::timestamp("us", "UTC"))
)

out <- "tests/testthat/parquet/timestamp_dst.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")

# --- Independent expected values -------------------------------------------

# Reading in UTC. UTC has no gaps or overlaps, so re-anchoring civil components
# that came from UTC is the identity, and the instant column is unchanged.
expected_utc <- data.frame(
  wall_ms = wall,
  wall_us = wall,
  instant_us = wall,
  stringsAsFactors = FALSE
)

# Reading in America/New_York.
#
# `format` is passed explicitly, and that is not a stylistic choice. Without it
# as.POSIXct.character *detects* a format by requiring every value to parse,
# and the gap value on line 2 does not -- so detection falls through to a
# date-only format and strips the time of day from all five. That is the bug
# this fixture exists to catch, and writing the reference the obvious way
# reproduces it, which would have encoded the bug as the expected answer.
#
# With an explicit format there is no detection: strptime resolves each value
# on its own, the nonexistent civil time becomes NA, and the ambiguous one
# takes whichever offset mktime chooses.
in_new_york <- as.POSIXct(
  civil,
  format = "%Y-%m-%d %H:%M:%S",
  tz = "America/New_York"
)
instant_in_new_york <- wall
attr(instant_in_new_york, "tzone") <- "America/New_York"

expected_new_york <- data.frame(
  wall_ms = in_new_york,
  wall_us = in_new_york,
  instant_us = instant_in_new_york,
  stringsAsFactors = FALSE
)

saveRDS(
  expected_utc,
  "tests/testthat/parquet/timestamp_dst-expected-utc.rds",
  version = 2L
)
saveRDS(
  expected_new_york,
  "tests/testthat/parquet/timestamp_dst-expected-new-york.rds",
  version = 2L
)

cat("\nUTC:\n")
print(expected_utc$wall_us)
cat("\nAmerica/New_York:\n")
print(expected_new_york$wall_us)
cat("\nnonexistent civil time is NA:", is.na(in_new_york[2]), "\n")
