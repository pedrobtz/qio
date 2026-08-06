# Generates tests/testthat/parquet/null_type.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# The Parquet NULL logical type marks a column that carries no values at all.
# qio cannot write one, so the fixture comes from an independent writer.

schema <- arrow::schema(nothing = arrow::null(), id = arrow::int32())
table <- arrow::as_arrow_table(
  data.frame(nothing = rep(NA, 3), id = 1:3),
  schema = schema
)

out <- "tests/testthat/parquet/null_type.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
