# explicit INT64 stays within R's exact integer range

    Code
      write_parquet(data.frame(x = 2^53 + 2), path, schema = parquet_schema(x = "INT64"))
    Condition
      Error:
      ! Column `x` contains values outside the supported range.

# parquet_schema() rejects malformed declarations

    Code
      parquet_schema(x = list("TIMESTAMP", unit = "SECONDS"))
    Condition
      Error:
      ! `unit` for `x` must be MILLIS, MICROS, or NANOS.

---

    Code
      parquet_schema(x = list("TIMESTAMP", is_adjusted_utc = FALSE))
    Condition
      Error:
      ! qio currently supports only UTC-adjusted TIMESTAMP output.

---

    Code
      parquet_schema("INT32")
    Condition
      Error:
      ! Every schema entry must have a column name.

---

    Code
      parquet_schema(x = "INT32", x = "INT64")
    Condition
      Error:
      ! Schema column names must be unique.

# REQUIRED rejects nulls before creating output

    Code
      write_parquet(data.frame(x = c(1, NA)), path, schema = parquet_schema(x = list(
        "INT64", repetition_type = "REQUIRED")))
    Condition
      Error:
      ! Required column `x` contains missing values.

# writer schemas reject incompatible column values before output

    Code
      write_parquet(data.frame(x = 1.5), path, schema = parquet_schema(x = "INT64"))
    Condition
      Error:
      ! Column `x` must contain finite whole numbers.

---

    Code
      write_parquet(data.frame(x = "not numeric"), path, schema = parquet_schema(x = "DOUBLE"))
    Condition
      Error:
      ! DOUBLE column `x` must be numeric.

# writer schemas reject missing and corrupted entries before output

    Code
      write_parquet(data.frame(x = 1), path, schema = parquet_schema(other = "INT32"))
    Condition
      Error:
      ! Schema refers to missing column(s): other.

---

    Code
      write_parquet(data.frame(x = 1), path, schema = broken)
    Condition
      Error:
      ! `schema` contains an unsupported type or repetition.

# timestamp validation rejects values that cannot fit in INT64

    Code
      write_parquet(x, path, schema = parquet_schema(time = list("TIMESTAMP", unit = "NANOS")))
    Condition
      Error:
      ! TIMESTAMP column `time` is outside the INT64 range.

