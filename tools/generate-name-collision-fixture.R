# Generates tests/testthat/parquet/name_collision.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# The file has two leaves whose NAMES collide ("b") but whose complete schema
# paths differ ("s.b" and "b"). carquet_schema_find_column() compares leaf names
# only, so selecting "b" through it resolves to whichever leaf comes first --
# here the nested one. qio therefore resolves selections to leaf indexes by
# complete path before calling carquet.

table <- arrow::arrow_table(
  s = arrow::Array$create(data.frame(b = c(10L, 20L, 30L))),
  b = arrow::Array$create(c(1L, 2L, 3L)),
  label = arrow::Array$create(c("x", "y", "z"))
)

out <- "tests/testthat/parquet/name_collision.parquet"
arrow::write_parquet(table, out, compression = "snappy", version = "2.6")

cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
print(arrow::read_parquet(out))
