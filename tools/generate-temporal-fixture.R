# Generates tests/testthat/parquet/temporal_types.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# Boundary values for every integer width and every timestamp and time unit, so
# the annotation contracts in .agents/TYPES.md are checked against bytes qio
# cannot produce: its writer has no unsigned, narrow-integer, TIME, or non-UTC
# timestamp support.

cast <- function(values, type) arrow::Array$create(values)$cast(type)
instant <- as.POSIXct(c("2020-01-01", "2020-07-01", NA), tz = "UTC")

table <- arrow::arrow_table(
  u8 = cast(c(0, 255, NA), arrow::uint8()),
  u16 = cast(c(0, 65535, NA), arrow::uint16()),
  u32 = cast(c(0, 4294967295, NA), arrow::uint32()),
  i8 = cast(c(-128, 127, NA), arrow::int8()),
  i16 = cast(c(-32768, 32767, NA), arrow::int16()),
  i32 = cast(c(-2147483647, 2147483647, NA), arrow::int32()),
  # An instant: tz changes only how it prints.
  ts_utc_ms = cast(instant, arrow::timestamp("ms", "UTC")),
  ts_utc_us = cast(instant, arrow::timestamp("us", "UTC")),
  ts_utc_ns = cast(instant, arrow::timestamp("ns", "UTC")),
  # A wall clock with no zone: its civil components are re-anchored in tz.
  ts_local_ms = cast(instant, arrow::timestamp("ms")),
  ts_local_us = cast(instant, arrow::timestamp("us")),
  # Midnight, one second before midnight, and a null.
  t_ms = cast(cast(c(0L, 86399999L, NA), arrow::int32()), arrow::time32("ms")),
  t_us = cast(cast(c(0, 86399999999, NA), arrow::int64()), arrow::time64("us")),
  t_ns = cast(
    cast(c(0, 86399999999999, NA), arrow::int64()),
    arrow::time64("ns")
  )
)

out <- "tests/testthat/parquet/temporal_types.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
