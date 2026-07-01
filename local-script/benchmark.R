# --- call-stack investigation -------------------------------------------
# Run once; tiny interval captures fine-grained R call chains.
prof <- tempfile(fileext = ".out")
Rprof(prof, interval = 0.005, line.profiling = FALSE)
qio::read_parquet("local-data/yellow_tripdata_2023-01.parquet")
Rprof(NULL)

p <- summaryRprof(prof)
cat("--- by self time ---\n");  print(head(p$by.self,  20))
cat("--- by total time ---\n"); print(head(p$by.total, 20))
# ------------------------------------------------------------------------

bench::mark(
  qio = qio::read_parquet("local-data/yellow_tripdata_2023-01.parquet"),
  nano = nanoparquet::read_parquet(
    "local-data/yellow_tripdata_2023-01.parquet"
  ),
  arrow::read_parquet("local-data/yellow_tripdata_2023-01.parquet"),
  check = F,
  iterations = 1
)


install.packages("profvis")

library(profvis)

library(proffer)

res <- pprof({
  qio::read_parquet("local-data/yellow_tripdata_2023-01.parquet")
})


# --- native call-stack probe ------------------------------------------------
# Fires debug_stack() once from qio_copy_batch_column (the innermost C hot
# path), so winch captures the full native chain:
#   winch_trace_back → debug_stack [R]
#   Rf_eval → qio_copy_batch_column → qio_copy_batch
#   → qio_collect_body → R_UnwindProtect → qio_parquet_collect [C]
#   → .Call → collect.qio_parquet_file → read_parquet [R]
devtools::load_all()

debug_stack <- function() {
  print(winch::winch_trace_back())
}

.Call(qio:::C_qio_set_probe, debug_stack)
qio::read_parquet("local-data/yellow_tripdata_2023-01.parquet")
.Call(qio:::C_qio_clear_probe, NULL)
# ----------------------------------------------------------------------------
