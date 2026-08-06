# Generates tests/testthat/parquet/all_types.parquet and its expected values.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# One file covering every row of the ?qio-types table that a trusted
# third-party writer can express, with the expected result committed alongside
# it as an .rds derived by hand from the values written here. qio is never
# loaded in this script: a reference read back through qio would pin current
# behaviour, bugs included, and pass forever.
#
# Apache Arrow cannot express four rows of that table, and they keep their own
# dedicated fixtures rather than being faked here:
#
#   UUID          arrow's R bindings have no UUID type   -> uuid.parquet
#   ENUM          arrow writes dictionary<string>, which is a physical
#                 encoding, not the ENUM annotation      -> not covered anywhere
#   JSON          arrow's R bindings have no JSON type   -> text_annotations.parquet
#   NULL type     no cast path to arrow::null()          -> null_type.parquet
#   INT96         deprecated; arrow will not write it    -> int96_from_spark.parquet
#   MAP           arrow's R bindings cannot build one    -> nested_maps.snappy.parquet
#
# Three decimal precisions are written, but note that Apache Arrow stores every
# one of them as FIXED_LEN_BYTE_ARRAY regardless -- it does not use the INT32
# or INT64 storage forms the format allows. So the `decimal_int_*` converters
# are *not* covered here; converter_gaps.parquet owns them, written by pyarrow
# with store_decimal_as_integer. The three columns still differ in precision
# and scale, which is worth keeping.

n <- 6L
i <- seq_len(n)
na_at <- function(x, at) {
  x[at] <- NA
  x
}

cast <- function(values, type) arrow::Array$create(values)$cast(type)

# Values are ordinary and well inside every type, so a failure means something
# ordinary broke. Boundary values belong to int64_boundaries.parquet,
# int32_min.parquet and decimal_types.parquet.
instant <- as.POSIXct("2024-03-01 08:30:00", tz = "UTC") + (i - 1L) * 3600
instant <- na_at(instant, 4L)
days <- na_at(as.Date("2024-01-01") + (i - 1L) * 15L, 3L)
# Exact in binary32, so widening to double needs no tolerance.
floats <- c(0, 0.5, -1.25, 2.75, NA, 8.125)

table <- arrow::arrow_table(
  # --- BOOLEAN ---
  f_bool = arrow::Array$create(na_at(rep(c(TRUE, FALSE), length.out = n), 2L)),

  # --- INT32 and its annotations ---
  f_i32 = cast(na_at(i * 100L, 5L), arrow::int32()),
  f_date = arrow::Array$create(days),
  f_time_ms = cast(
    cast(
      na_at(c(0L, 1L, 3600000L, 43200000L, 86399999L, 5L), 6L),
      arrow::int32()
    ),
    arrow::time32("ms")
  ),
  f_i8 = cast(na_at(c(-128L, -1L, 0L, 1L, 127L, 42L), 3L), arrow::int8()),
  f_i16 = cast(na_at(c(-32768L, -1L, 0L, 1L, 32767L, 99L), 4L), arrow::int16()),
  f_u8 = cast(na_at(c(0L, 1L, 127L, 128L, 255L, 7L), 2L), arrow::uint8()),
  f_u16 = cast(na_at(c(0L, 1L, 255L, 256L, 65535L, 9L), 5L), arrow::uint16()),
  # Widens to double so the upper half stays positive.
  f_u32 = cast(
    na_at(c(0, 1, 2147483648, 4294967295, 12345, 7), 6L),
    arrow::uint32()
  ),
  # Small precision; Arrow still stores it as a byte array.
  f_dec32 = cast(
    na_at(c(0, 1.23, -4.56, 78.90, 12.34, 5.67), 2L),
    arrow::decimal128(9, 2)
  ),

  # --- INT64 and its annotations ---
  f_i64 = cast(na_at(as.numeric(1000000L + i * 7L), 3L), arrow::int64()),
  f_ts_utc = cast(instant, arrow::timestamp("us", "UTC")),
  # A wall clock with no zone attached.
  f_ts_local = cast(instant, arrow::timestamp("us")),
  f_time_us = cast(
    cast(
      na_at(c(0, 1, 3600000000, 43200000000, 86399999999, 5), 4L),
      arrow::int64()
    ),
    arrow::time64("us")
  ),
  f_u64 = cast(
    na_at(c(0, 1, 4294967296, 9007199254740992, 12345, 7), 5L),
    arrow::uint64()
  ),
  # Medium precision; likewise a byte array.
  f_dec64 = cast(
    na_at(c(0, 1.23, -4.56, 1234567.89, 12.34, 5.67), 6L),
    arrow::decimal128(18, 2)
  ),

  # --- FLOAT and DOUBLE ---
  f_float = cast(floats, arrow::float32()),
  f_double = arrow::Array$create(na_at(i * 1.5 - 3, 2L)),
  # 16-bit float, widened to double exactly.
  f_float16 = cast(
    cast(c(0, 0.5, -1.25, 2.75, NA, 8.125), arrow::float32()),
    arrow::float16()
  ),

  # --- BYTE_ARRAY ---
  f_string = arrow::Array$create(na_at(sprintf("row-%02d", i), 4L)),
  # Multibyte, to prove UTF-8 survives rather than only ASCII.
  f_utf8 = arrow::Array$create(
    na_at(c("café", "日本語", "straße", "\U0001F600", "ok", "naïve"), 5L)
  ),
  f_binary = arrow::Array$create(
    list(
      as.raw(1:3),
      as.raw(integer(0)),
      NULL,
      as.raw(c(255L, 0L, 128L)),
      as.raw(42L),
      as.raw(7:9)
    ),
    type = arrow::binary()
  ),
  # Large precision, which requires a byte array in any writer.
  f_dec_binary = cast(
    na_at(c(0, 1.23, -4.56, 99999.99, 12.34, 5.67), 3L),
    arrow::decimal128(30, 2)
  ),

  # --- FIXED_LEN_BYTE_ARRAY ---
  f_fixed = arrow::Array$create(
    list(
      as.raw(1:4),
      as.raw(c(255L, 255L, 255L, 255L)),
      NULL,
      as.raw(rep(0L, 4L)),
      as.raw(c(1L, 2L, 3L, 4L)),
      as.raw(9:12)
    ),
    type = arrow::fixed_size_binary(4)
  )
)

out <- "tests/testthat/parquet/all_types.parquet"
# Several row groups, so parallel collect and projection are exercised.
arrow::write_parquet(
  table,
  out,
  compression = "snappy",
  chunk_size = 2L,
  version = "2.6"
)
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("columns:", ncol(table), " bytes:", file.info(out)$size, "\n")

# --- Independent expected values -------------------------------------------
#
# Each entry applies .agents/TYPES.md by hand to the values written above.

expected <- data.frame(
  f_bool = na_at(rep(c(TRUE, FALSE), length.out = n), 2L),
  f_i32 = na_at(i * 100L, 5L),
  f_date = days,
  # TIME is a count since midnight in seconds, never a POSIXct.
  f_time_ms = na_at(c(0, 0.001, 3600, 43200, 86399.999, 0.005), 6L),
  f_i8 = na_at(c(-128L, -1L, 0L, 1L, 127L, 42L), 3L),
  f_i16 = na_at(c(-32768L, -1L, 0L, 1L, 32767L, 99L), 4L),
  f_u8 = na_at(c(0L, 1L, 127L, 128L, 255L, 7L), 2L),
  f_u16 = na_at(c(0L, 1L, 255L, 256L, 65535L, 9L), 5L),
  f_u32 = na_at(c(0, 1, 2147483648, 4294967295, 12345, 7), 6L),
  # DECIMAL reads as double with the declared scale applied.
  f_dec32 = na_at(c(0, 1.23, -4.56, 78.90, 12.34, 5.67), 2L),
  f_i64 = na_at(as.numeric(1000000L + i * 7L), 3L),
  # An instant; tz changes only display.
  f_ts_utc = instant,
  # A wall clock re-anchored in tz, which defaults to UTC, so unchanged.
  f_ts_local = instant,
  f_time_us = na_at(c(0, 1e-06, 3600, 43200, 86399.999999, 5e-06), 4L),
  f_u64 = na_at(c(0, 1, 4294967296, 9007199254740992, 12345, 7), 5L),
  f_dec64 = na_at(c(0, 1.23, -4.56, 1234567.89, 12.34, 5.67), 6L),
  f_float = as.double(floats),
  f_double = na_at(i * 1.5 - 3, 2L),
  f_float16 = c(0, 0.5, -1.25, 2.75, NA, 8.125),
  f_string = na_at(sprintf("row-%02d", i), 4L),
  f_utf8 = na_at(
    c("café", "日本語", "straße", "\U0001F600", "ok", "naïve"),
    5L
  ),
  f_dec_binary = na_at(c(0, 1.23, -4.56, 99999.99, 12.34, 5.67), 3L),
  stringsAsFactors = FALSE
)

# Byte columns are lists of raw, with NULL for a null value, so they are
# attached after the data.frame() call rather than being flattened by it.
expected$f_binary <- list(
  as.raw(1:3),
  raw(0),
  NULL,
  as.raw(c(255L, 0L, 128L)),
  as.raw(42L),
  as.raw(7:9)
)
expected$f_fixed <- list(
  as.raw(1:4),
  as.raw(c(255L, 255L, 255L, 255L)),
  NULL,
  as.raw(rep(0L, 4L)),
  as.raw(c(1L, 2L, 3L, 4L)),
  as.raw(9:12)
)
# Restore the schema order that data.frame() could not hold.
expected <- expected[, c(
  "f_bool",
  "f_i32",
  "f_date",
  "f_time_ms",
  "f_i8",
  "f_i16",
  "f_u8",
  "f_u16",
  "f_u32",
  "f_dec32",
  "f_i64",
  "f_ts_utc",
  "f_ts_local",
  "f_time_us",
  "f_u64",
  "f_dec64",
  "f_float",
  "f_double",
  "f_float16",
  "f_string",
  "f_utf8",
  "f_binary",
  "f_dec_binary",
  "f_fixed"
)]

reference <- "tests/testthat/parquet/all_types-expected.rds"
saveRDS(expected, reference, version = 2L)
cat("wrote:", reference, "\n")
cat("expected columns:", ncol(expected), "\n")
