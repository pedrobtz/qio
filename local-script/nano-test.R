library(nanoparquet)

path <- "local-data/yellow_tripdata_2023-01.parquet"

# Warmup: load package, dynamic libraries, caches, etc.
invisible(nanoparquet::read_parquet(path))

# Profile this repeated section.
for (i in seq_len(30)) {
  x <- nanoparquet::read_parquet(path)
  invisible(nrow(x))
}
