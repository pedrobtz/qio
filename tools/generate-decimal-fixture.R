# Generates tests/testthat/parquet/decimal_types.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.

table <- arrow::arrow_table(
  small = arrow::Array$create(c(12.30, 4.05, -0.07, NA))$cast(
    arrow::decimal32(7, 2)
  ),
  wide = arrow::Array$create(c(123456789.12, -1, 0, NA))$cast(
    arrow::decimal64(15, 2)
  )
)

out <- "tests/testthat/parquet/decimal_types.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
