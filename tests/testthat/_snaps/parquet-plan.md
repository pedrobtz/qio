# read_plan() rejects unsupported input

    Code
      read_plan(1L)
    Condition
      Error:
      ! `x` must be a Parquet file path, a `qio_parquet_file`, or a schema data frame from `schema()`.

