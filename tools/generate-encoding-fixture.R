# Generates tests/testthat/parquet/string_encodings.parquet with Apache Arrow.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# Three string columns whose pages use different encodings, so the reader's
# dictionary fast path is checked against the plain path and against a column
# that switches between them mid-chunk:
#
#   dict   low cardinality, stays dictionary encoded throughout
#   plain  dictionary explicitly disabled
#   mixed  repeats first, then enough distinct values to overflow the
#          dictionary page limit, after which Arrow falls back to PLAIN
#
# .agents/TYPES.md requires all three to return identical character values,
# whatever the encoding.

set.seed(20260801)
n <- 24000L
pool <- paste0("category_", sprintf("%03d", seq_len(150L)))

mixed <- c(
  sample(pool, n %/% 3L, replace = TRUE),
  paste0("u", sprintf("%06d", seq_len(n - n %/% 3L)))
)

table <- arrow::arrow_table(
  dict = sample(pool, n, replace = TRUE),
  plain = sample(pool, n, replace = TRUE),
  mixed = mixed
)

out <- "tests/testthat/parquet/string_encodings.parquet"
arrow::write_parquet(
  table,
  out,
  compression = "snappy",
  version = "2.6",
  use_dictionary = c(TRUE, FALSE, TRUE),
  # A small dictionary page limit makes the `mixed` column switch to PLAIN
  # partway through rather than needing a huge file to overflow the default.
  data_page_size = 16384L
)
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")
