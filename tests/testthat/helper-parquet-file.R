fixture_path <- function() test_path("parquet", "qio-multigroup.parquet")

fixture_data <- function() {
  data.frame(
    id = 1:12,
    count = 10000000000 + 1:12,
    ratio = as.double(as.single(1:12 / 10)),
    price = c(1.25, 2.5, NA, 5, 6.25, 7.5, 8.75, NA, 11.25, 12.5, 13.75, 15),
    label = c(
      "one",
      "two",
      "three",
      "four",
      NA,
      "six",
      "seven",
      "eight",
      "nine",
      "ten",
      "eleven",
      "twelve"
    ),
    active = rep(c(TRUE, FALSE), 6)
  )
}

local_parquet_file <- function(path = fixture_path(), ...) {
  file <- open_parquet(path, ...)
  withr::defer(close_parquet(file), envir = parent.frame())
  file
}

# Count OS threads in this process. Returns NA where there is no cheap probe,
# which is how the thread-count test skips on Windows.
qio_thread_count <- function() {
  if (dir.exists("/proc/self/task")) {
    return(length(list.files("/proc/self/task")))
  }
  if (.Platform$OS.type == "unix") {
    out <- suppressWarnings(
      system2("ps", c("-M", Sys.getpid()), stdout = TRUE, stderr = FALSE)
    )
    if (length(out) > 1L) {
      return(length(out) - 1L)
    }
  }
  NA_integer_
}

# The vendored batch pipeline only engages for a compressed, memory-mapped file
# whose projected columns are all non-nullable, and which has either several row
# groups or at least 500,000 rows. qio writes a single row group, so the row
# count is what makes this file eligible.
local_pipeline_file <- function(rows = 500000L, envir = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".parquet", .local_envir = envir)
  write_parquet(
    data.frame(a = as.double(seq_len(rows)), b = as.double(seq_len(rows))),
    path
  )
  path
}

geo_stats_of <- function(values, type = "GEOMETRY") {
  path <- withr::local_tempfile(fileext = ".parquet")
  df <- data.frame(id = seq_along(values))
  df$g <- values
  write_parquet(df, path, schema = parquet_schema(g = type))
  pf <- open_parquet(path)
  on.exit(close_parquet(pf))
  geospatial_statistics(pf)
}
