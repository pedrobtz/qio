# Generates tests/testthat/parquet/int32_min.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
library(arrow)

table <- arrow::arrow_table(
  # -2147483648 is a legal INT32 that R's integer type reserves as NA.
  value = arrow::Array$create(
    c(-2147483648, -1, 0, 2147483647, NA),
    type = arrow::int32()
  ),
  label = arrow::Array$create(c("min", "neg", "zero", "max", NA))
)

out <- "tests/testthat/parquet/int32_min.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")

cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
print(arrow::read_parquet(out))
