# Generates tests/testthat/parquet/binary_types.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# Covers the text/binary split in .agents/TYPES.md: only an annotated column is
# text, everything else stored as bytes stays bytes.

table <- arrow::arrow_table(
  text = arrow::Array$create(c("hello", NA, "éè")),
  bytes = arrow::Array$create(
    list(as.raw(c(1, 2, 3)), NULL, as.raw(c(255, 0, 128))),
    type = arrow::binary()
  ),
  fixed = arrow::Array$create(
    list(as.raw(c(1, 2, 3, 4)), NULL, as.raw(c(9, 9, 9, 9))),
    type = arrow::fixed_size_binary(4)
  ),
  half = arrow::Array$create(c(1.5, NA, -2.25))$cast(arrow::float16())
)

out <- "tests/testthat/parquet/binary_types.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
