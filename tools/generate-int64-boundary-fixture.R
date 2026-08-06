# Generates tests/testthat/parquet/int64_boundaries.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# Covers every boundary in the 64-bit contract in .agents/TYPES.md: the exact
# double range, bit64's reserved NA sentinel, INT64_MAX, and the unsigned half
# above INT64_MAX that must never surface as a negative number.

cast <- function(values, type) arrow::Array$create(values)$cast(type)

table <- arrow::arrow_table(
  signed = cast(
    c(
      "-9223372036854775808", # INT64_MIN, bit64's NA sentinel
      "-9007199254740993", # -(2^53 + 1), outside the exact double range
      "-9007199254740992", # -2^53, the exact bound
      "-1",
      "0",
      "9007199254740992", # 2^53
      "9007199254740993", # 2^53 + 1
      "9223372036854775807" # INT64_MAX
    ),
    arrow::int64()
  ),
  unsigned = cast(
    c(
      "0",
      "1",
      "9007199254740992", # 2^53
      "9007199254740993", # 2^53 + 1
      "9223372036854775807", # INT64_MAX
      "9223372036854775808", # INT64_MAX + 1, negative if read as signed
      "18446744073709551614",
      "18446744073709551615" # UINT64_MAX
    ),
    arrow::uint64()
  )
)

out <- "tests/testthat/parquet/int64_boundaries.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
