nested_file <- function() {
  file <- open_parquet(test_path("parquet", "nested_maps.snappy.parquet"))
  withr::defer(close_parquet(file), envir = parent.frame())
  file
}

indexed_file <- function() {
  # Written by Arrow, so it carries a page index and bloom filters; qio's
  # writer emits neither.
  file <- open_parquet(test_path("parquet", "bloom_sorted.parquet"))
  withr::defer(close_parquet(file), envir = parent.frame())
  file
}
