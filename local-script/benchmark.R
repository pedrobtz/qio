# --- call-stack investigation -------------------------------------------
# Run once; tiny interval captures fine-grained R call chains.
prof <- tempfile(fileext = ".out")
Rprof(prof, interval = 0.005, line.profiling = FALSE)
qio::read_parquet("local-data/yellow_tripdata_2023-01.parquet")
Rprof(NULL)

p <- summaryRprof(prof)
cat("--- by self time ---\n")
print(head(p$by.self, 20))
cat("--- by total time ---\n")
print(head(p$by.total, 20))
# ------------------------------------------------------------------------

bench::mark(
  qio = qio::read_parquet("local-data/yellow_tripdata_2023-01.parquet"),
  nano = nanoparquet::read_parquet(
    "local-data/yellow_tripdata_2023-01.parquet"
  ),
  arrow::read_parquet("local-data/yellow_tripdata_2023-01.parquet"),
  check = F,
  filter_gc = FALSE,
  iterations = 1
)


install.packages("profvis")
library(profvis)
library(proffer)

res <- pprof({
  qio::read_parquet("local-data/yellow_tripdata_2023-01.parquet")
})


# Benchmark the INSTALLED package in a FRESH R session only.
#   - Never after devtools::load_all(): it compiles a DEBUG build (-O0, no
#     optimization) — 3x slower — and leaves -O0 objects in src/ that a later
#     R CMD INSTALL silently reuses. Clean first:
#       find src \( -name '*.o' -o -name '*.so' \) -delete && R CMD INSTALL .
#   - Restart R before benchmarking: a live session keeps the previously
#     loaded qio DLL; reinstalling on disk does not swap it.
#   - iterations = 20 with filter_gc = FALSE includes ~40 GC pauses (each
#     iteration allocates ~0.5 GB); medians are ~50% higher than 10-iteration
#     runs. Compare like with like.
suppressMessages(library(qio))
p <- "local-data/yellow_tripdata_2023-01.parquet"
invisible(qio::read_parquet(p))
gc()
b <- bench::mark(
  qio = qio::read_parquet(p),
  nano = nanoparquet::read_parquet(p),
  check = FALSE,
  iterations = 20,
  filter_gc = FALSE
)
