# Generates tests/testthat/parquet/common_types.parquet and its expected values.
# Run manually; arrow is not a qio dependency. Provenance: parquet/SOURCE.md.
#
# The shape of an ordinary table: 64-bit ids, text, a low-cardinality category,
# doubles, a float, an integer count, a flag, a date and a timestamp, every one
# of them nullable, across several row groups.
#
# The corpus covered each of these types somewhere, but nothing held the
# everyday combination in one file. That mattered: the first real dataset ever
# pointed at qio was exactly INT64 plus TIMESTAMP plus DOUBLE plus STRING, and
# it read 426x slower than the best alternative because of a defect no fixture
# reached. The exotic cases were well covered; the ordinary one was not.
#
# Deliberately *not* a boundary fixture. int64_boundaries.parquet owns values
# past 2^53, int32_min.parquet owns the sentinel, decimal_types.parquet owns
# DECIMAL. Everything here sits comfortably inside its type so that a failure
# means something ordinary broke.

n <- 12L
i <- seq_len(n)

# INT64 well inside the range R's double represents exactly.
ids <- as.numeric(1000000L + i * 7L)
ids[3L] <- NA

names_ <- sprintf("row-%02d", i)
names_[5L] <- NA

# A low-cardinality category alongside the all-distinct `name`. Note that Arrow
# dictionary-encodes both -- and in fact every column here except the boolean,
# which is what a real Arrow-written file looks like. The plain and
# dictionary-falls-back-to-plain paths are owned by dict_fallback.parquet and
# string_encodings.parquet, not by this fixture.
categories <- c("alpha", "beta", "gamma")[(i %% 3L) + 1L]
categories[8L] <- NA

amounts <- i * 1.5 - 3
amounts[2L] <- NA

# Values chosen to be exact in binary32, so widening to double is lossless and
# the expectation can be written without a tolerance.
scores <- c(0, 0.5, 1.25, 2.75, -0.5, 4, 8.125, -16.25, 32, 0.0625, 64, -128)
scores[11L] <- NA

quantities <- as.integer(i * 3L)
quantities[7L] <- NA

flags <- rep(c(TRUE, FALSE), length.out = n)
flags[4L] <- NA

days <- as.Date("2024-01-01") + (i - 1L) * 15L
days[6L] <- NA

instants <- as.POSIXct("2024-03-01 08:30:00", tz = "UTC") + (i - 1L) * 3600
instants[9L] <- NA

table <- arrow::arrow_table(
  id = arrow::Array$create(ids)$cast(arrow::int64()),
  name = arrow::Array$create(names_),
  category = arrow::Array$create(categories),
  amount = arrow::Array$create(amounts),
  score = arrow::Array$create(scores)$cast(arrow::float32()),
  quantity = arrow::Array$create(quantities),
  flag = arrow::Array$create(flags),
  day = arrow::Array$create(days),
  updated = arrow::Array$create(instants)$cast(arrow::timestamp("us", "UTC"))
)

out <- "tests/testthat/parquet/common_types.parquet"
# Several row groups, so parallel collect and row-group projection are actually
# exercised rather than degenerating to one group.
arrow::write_parquet(
  table,
  out,
  compression = "snappy",
  chunk_size = 4L,
  version = "2.6"
)
cat("arrow:", as.character(utils::packageVersion("arrow")), "\n")
cat("bytes:", file.info(out)$size, "\n")

# --- Independent expected values -------------------------------------------
#
# Derived from the values written above by applying .agents/TYPES.md by hand.
# qio is never loaded here; a reference read back through qio would pin current
# behaviour, bugs included. See parquet/SOURCE.md.

expected <- data.frame(
  # INT64 reads as double under the default int64 = "double".
  id = ids,
  name = names_,
  category = categories,
  amount = amounts,
  # FLOAT widens to double, exactly, because every value above is exact in
  # binary32.
  score = as.double(scores),
  quantity = quantities,
  flag = flags,
  day = days,
  updated = instants,
  stringsAsFactors = FALSE
)

reference <- "tests/testthat/parquet/common_types-expected.rds"
saveRDS(expected, reference, version = 2L)
cat("wrote:", reference, "\n")
cat("columns:", paste(names(expected), collapse = ", "), "\n")
cat("rows:", nrow(expected), " nulls per column: 1\n")
