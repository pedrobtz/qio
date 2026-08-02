# A synthetic schema data frame covering every physical type, a pending logical
# annotation, an unsupported physical type, and a repeated (nested) column. This
# keeps the resolver test independent of what files carquet can produce.
fake_schema <- function() {
  data.frame(
    column = 1:13,
    name = c(
      "b",
      "i32",
      "i64",
      "f",
      "d",
      "s",
      "raw",
      "dt",
      "ts",
      "i96",
      "flba",
      "lst",
      "value"
    ),
    path = c(
      "b",
      "i32",
      "i64",
      "f",
      "d",
      "s",
      "raw",
      "dt",
      "ts",
      "i96",
      "flba",
      "lst.element",
      "struct.value"
    ),
    physical_type = c(
      "BOOLEAN",
      "INT32",
      "INT64",
      "FLOAT",
      "DOUBLE",
      "BYTE_ARRAY",
      "BYTE_ARRAY",
      "INT32",
      "INT64",
      "INT96",
      "FIXED_LEN_BYTE_ARRAY",
      "INT32",
      "DOUBLE"
    ),
    logical_type = c(
      NA,
      NA,
      NA,
      NA,
      NA,
      "STRING",
      NA,
      "DATE",
      "TIMESTAMP",
      NA,
      NA,
      NA,
      NA
    ),
    logical_details = NA_character_,
    repetition = c(rep("REQUIRED", 11), "REPEATED", "OPTIONAL"),
    type_length = c(rep(NA_integer_, 10), 16L, NA_integer_, NA_integer_),
    max_definition_level = c(
      0L,
      1L,
      0L,
      0L,
      0L,
      1L,
      0L,
      0L,
      0L,
      0L,
      0L,
      1L,
      1L
    ),
    max_repetition_level = c(rep(0L, 11), 1L, 0L),
    stringsAsFactors = FALSE
  )
}

test_that("read_plan() maps physical types to R types", {
  plan <- read_plan(fake_schema())

  expect_s3_class(plan, "qio_read_plan")
  expect_equal(
    plan$r_type,
    c(
      "logical",
      "integer",
      "double",
      "double",
      "double",
      "character",
      "list",
      "Date",
      "double",
      "POSIXct",
      "list",
      "integer",
      "double"
    )
  )
  expect_equal(
    plan$converter,
    c(
      "boolean",
      "int32",
      "int64_double",
      "float",
      "double",
      "text",
      "binary",
      "date32",
      "int64",
      "int96",
      "binary",
      "int32",
      "double"
    )
  )
})

test_that("read_plan() marks nullability from definition levels", {
  plan <- read_plan(fake_schema())
  expect_equal(
    plan$nullable,
    c(
      FALSE,
      TRUE,
      FALSE,
      FALSE,
      FALSE,
      TRUE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      TRUE,
      TRUE
    )
  )
})

test_that("read_plan() flags collectible columns and explains the rest", {
  plan <- read_plan(fake_schema())

  expect_equal(
    plan$nested,
    c(rep(FALSE, 11), TRUE, TRUE)
  )

  expect_equal(
    plan$collectible,
    c(
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      TRUE,
      FALSE,
      FALSE
    )
  )

  expect_true(all(is.na(plan$note[plan$name %in% c("b", "i32", "s", "raw")])))
  expect_true(is.na(plan$note[plan$name == "dt"]))
  expect_true(is.na(plan$note[plan$name == "i96"]))
  expect_match(plan$note[plan$name == "ts"], "TIMESTAMP is not yet applied")
  # FIXED_LEN_BYTE_ARRAY now reads as a list of fixed-width raw vectors.
  expect_true(is.na(plan$note[plan$name == "flba"]))
  expect_match(plan$note[plan$name == "lst"], "nested or repeated")
  expect_match(plan$note[plan$path == "struct.value"], "nested or repeated")
})

ts_schema <- function(details) {
  data.frame(
    column = 1L,
    name = "t",
    path = "t",
    physical_type = "INT64",
    logical_type = "TIMESTAMP",
    logical_details = details,
    repetition = "OPTIONAL",
    type_length = NA_integer_,
    max_definition_level = 1L,
    max_repetition_level = 0L,
    stringsAsFactors = FALSE
  )
}

test_that("read_plan() applies UTC timestamps and rescales by unit", {
  for (unit in c("MILLIS", "MICROS", "NANOS")) {
    plan <- read_plan(
      ts_schema(sprintf("unit=%s, adjusted_to_utc=true", unit))
    )
    expect_equal(plan$r_type, "POSIXct")
    # The converter carries the unit and the target zone.
    expect_equal(
      plan$converter,
      paste0("timestamp_utc_", tolower(unit), "_UTC")
    )
    expect_true(plan$collectible)
    expect_true(is.na(plan$note))
  }
})

# A local TIMESTAMP stores civil components with no zone, so reading it means
# re-anchoring them in `tz`. Doing that through formatted text was both wrong
# and slow, and the wrongness is the dangerous part: as.POSIXct.character picks
# a format by requiring every value to parse, so a single civil time inside a
# spring-forward gap -- which has no instant in `tz` -- rejected the datetime
# format and fell through to a date-only one, silently dropping the time of day
# from the entire column.

test_that("a civil time with no instant in tz does not damage its neighbours", {
  # 02:30 on 2023-03-12 does not exist in New York: the clock jumps 02:00 -> 03:00.
  civil <- as.numeric(as.POSIXct(
    c("2023-06-01 09:15:30", "2023-03-12 02:30:00", "2023-12-24 00:07:06"),
    tz = "UTC"
  ))
  result <- qio_as_posixct(
    civil * 1e6,
    1e6,
    "America/New_York",
    adjusted = FALSE
  )

  # The unrepresentable value is NA on its own account.
  expect_true(is.na(result[2]))
  # Every other value keeps its time of day. Before the fix all three read back
  # as midnight.
  expect_identical(
    format(result[1], "%Y-%m-%d %H:%M:%S"),
    "2023-06-01 09:15:30"
  )
  expect_identical(
    format(result[3], "%Y-%m-%d %H:%M:%S"),
    "2023-12-24 00:07:06"
  )
})

test_that("re-anchoring civil components preserves them exactly", {
  # Sub-second values and several zones, none of them near a DST transition,
  # so this pins the ordinary case rather than the boundary.
  civil <- as.numeric(as.POSIXct("2023-06-15 13:45:07", tz = "UTC")) +
    c(0, 0.000001, 0.25, 0.5, 0.999999)
  for (tz in c("UTC", "America/New_York", "Asia/Kolkata", "Australia/Sydney")) {
    result <- qio_as_posixct(civil * 1e6, 1e6, tz, adjusted = FALSE)
    expect_identical(
      format(result, "%Y-%m-%d %H:%M:%S"),
      format(
        structure(civil, class = c("POSIXct", "POSIXt"), tzone = "UTC"),
        "%Y-%m-%d %H:%M:%S"
      ),
      info = tz
    )
    expect_identical(attr(result, "tzone"), tz, info = tz)
  }
})

test_that("re-anchoring in UTC is the identity", {
  # tz defaults to UTC, and UTC civil components are already UTC instants.
  # This used to format and reparse every value to return it unchanged.
  civil <- as.numeric(as.POSIXct("2023-06-15 13:45:07", tz = "UTC")) +
    c(0, 1, 2.5)
  result <- qio_as_posixct(civil * 1e6, 1e6, "UTC", adjusted = FALSE)
  expect_identical(as.numeric(result), civil)
  expect_identical(attr(result, "tzone"), "UTC")
})

test_that("read_plan() reads a non-UTC timestamp as a wall clock in tz", {
  plan <- read_plan(ts_schema("unit=MICROS, adjusted_to_utc=false"))

  expect_equal(plan$r_type, "POSIXct")
  expect_equal(plan$converter, "timestamp_local_micros_UTC")
  expect_true(plan$collectible)
  expect_true(is.na(plan$note))

  # The zone is part of the plan, so a different tz is a different converter.
  in_paris <- read_plan(
    ts_schema("unit=MICROS, adjusted_to_utc=false"),
    tz = "Europe/Paris"
  )
  expect_equal(in_paris$converter, "timestamp_local_micros_Europe/Paris")
})

test_that("read_plan() rejects a data frame that is not a schema", {
  expect_error(read_plan(data.frame(a = 1)), "not a schema data frame")
})

test_that("read_plan() rejects unsupported input", {
  expect_snapshot(error = TRUE, read_plan(1L))
})

test_that("read_plan() works on an open file and matches its schema", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(
    data.frame(x = 1:3, y = c("a", "b", NA), z = c(1.5, 2.5, 3.5)),
    path
  )
  pf <- parquet_open(path)
  on.exit(parquet_close(pf), add = TRUE)

  plan <- read_plan(pf)

  expect_equal(read_plan(schema(pf)), plan)
  expect_true(all(plan$collectible))
  expect_equal(plan$r_type, c("integer", "character", "double"))
  expect_equal(plan$nullable, c(FALSE, TRUE, FALSE))
})

test_that("read_plan() accepts a file path", {
  path <- withr::local_tempfile(fileext = ".parquet")
  write_parquet(data.frame(x = 1:3), path)

  expect_equal(read_plan(path)$r_type, "integer")
})

test_that("print.qio_read_plan() returns its input invisibly", {
  plan <- read_plan(fake_schema())
  expect_output(expect_invisible(print(plan)), "qio_read_plan")
})

# --- Phase 2: registry is authoritative ------------------------------------

test_that("parquet_type_mapping() is generated from the registry", {
  # The registry is the single source of truth for physical fallbacks. If the
  # mapping table is ever hand-edited, or a registry row is added without the
  # mapping following, this fails rather than letting documentation drift from
  # native behavior. See .agents/TYPES.md rule 8.
  registry <- qio_type_registry()
  mapping <- parquet_type_mapping()

  expect_identical(mapping$parquet_type, registry$physical_type)
  expect_identical(mapping$read_as, registry$r_type)
  expect_identical(mapping$written_from, registry$written_from)
  expect_identical(nrow(mapping), nrow(registry))
  expect_identical(names(mapping), c("parquet_type", "read_as", "written_from"))
})

test_that("the registry covers every physical type carquet can report", {
  # A physical type missing from the registry would silently become an
  # unsupported column with no mapping row to explain it.
  expect_setequal(
    qio_type_registry()$physical_type,
    c(
      "BOOLEAN",
      "INT32",
      "INT64",
      "INT96",
      "FLOAT",
      "DOUBLE",
      "BYTE_ARRAY",
      "FIXED_LEN_BYTE_ARRAY"
    )
  )
})

test_that("every registry converter is handled by qio_apply_converter()", {
  # An unhandled converter would fall through to the identity branch and
  # silently return the physical vector instead of the intended R type.
  converters <- c(
    qio_type_registry()$converter,
    qio_logical_registry()$converter,
    "timestamp_utc_millis",
    "timestamp_utc_micros",
    "timestamp_utc_nanos"
  )
  converters <- unique(converters[!is.na(converters)])

  for (converter in converters) {
    result <- qio_apply_converter(1, converter)
    expect_length(result, 1L)
  }
})

# --- Phase 2: complete-path selection --------------------------------------

test_that("qio_resolve_columns() maps paths to leaf indexes", {
  plan <- data.frame(
    path = c("s.b", "b", "label"),
    nested = c(TRUE, FALSE, FALSE),
    stringsAsFactors = FALSE
  )

  expect_null(qio_resolve_columns(plan, NULL))
  expect_identical(qio_resolve_columns(plan, "b"), 2L)
  expect_identical(qio_resolve_columns(plan, c("label", "s.b")), c(3L, 1L))
})

test_that("qio_resolve_columns() rejects unknown and ambiguous paths", {
  plan <- data.frame(
    path = c("a.b", "a.b", "c"),
    nested = c(TRUE, FALSE, FALSE),
    stringsAsFactors = FALSE
  )

  expect_error(qio_resolve_columns(plan, "nope"), "Unknown Parquet column")
  expect_error(
    qio_resolve_columns(plan, c("nope", "nah")),
    "Unknown Parquet columns"
  )
  # A flat column named "a.b" and a nested leaf b under group a render the same
  # path; qio refuses to guess which was meant.
  expect_error(qio_resolve_columns(plan, "a.b"), "Ambiguous Parquet column")
})

test_that("qio_select_columns() drops nested leaves and reports the count", {
  plan <- data.frame(
    path = c("s.b", "b", "label"),
    nested = c(TRUE, FALSE, FALSE),
    stringsAsFactors = FALSE
  )

  expect_message(
    selected <- qio_select_columns(plan, NULL),
    "Skipping 1 nested Parquet column"
  )
  expect_identical(selected, c(2L, 3L))

  # Nothing nested selected means no message at all.
  expect_message(qio_select_columns(plan, c("b", "label")), NA)
  expect_identical(qio_select_columns(plan, c("b", "label")), c(2L, 3L))

  # Selecting only nested leaves yields an empty selection, not an error.
  expect_message(
    empty <- qio_select_columns(plan, "s.b"),
    "Skipping 1 nested Parquet column"
  )
  expect_identical(empty, integer(0))
})

test_that("qio_select_columns() returns NULL when every column is selectable", {
  # NULL lets the native layer take its own all-columns path instead of
  # building an index vector for a wide file.
  plan <- data.frame(
    path = c("a", "b"),
    nested = c(FALSE, FALSE),
    stringsAsFactors = FALSE
  )
  expect_null(qio_select_columns(plan, NULL))
})

# --- Phase 3.2: text, binary, UUID, FLOAT16 --------------------------------

# FLOAT16 was rewritten from one closure call per value to a vectorized form.
# This pins the edge cases the loop handled implicitly and a reshape can get
# wrong: a NULL contributes nothing to unlist(), so reshaping without excluding
# nulls first shifts every later value into the wrong slot. UUID formatting
# moved into C entirely and is covered through the read path in
# test-external.R.

test_that("binary DECIMAL decoding handles widths, signs, and nulls", {
  # Big-endian two's complement of arbitrary width. Vectorized by grouping the
  # values by byte width, because a BYTE_ARRAY decimal uses the fewest bytes
  # each value needs -- unlike UUID and FLOAT16, the width is not fixed.
  dec <- function(x, scale = 0L) qio_decimal_from_binary(x, scale)

  expect_identical(dec(list(as.raw(c(0x00, 0x7b)))), 123)
  expect_identical(dec(list(as.raw(rep(0x00, 4L)))), 0)
  expect_identical(dec(list(as.raw(rep(0xff, 4L)))), -1)
  # The sign lives in the top bit of the first byte, at either boundary.
  expect_identical(dec(list(as.raw(c(0x7f, 0xff, 0xff, 0xff)))), 2147483647)
  expect_identical(dec(list(as.raw(c(0x80, 0x00, 0x00, 0x00)))), -2147483648)
  # One byte wide, both signs.
  expect_identical(dec(list(as.raw(0x05), as.raw(0xfb))), c(5, -5))

  # Nulls, including one first: a NULL contributes nothing to unlist(), so
  # reshaping without excluding nulls first shifts every later value.
  expect_identical(
    dec(list(NULL, as.raw(c(0x01, 0x00)), NULL, as.raw(c(0xff, 0x00)), NULL)),
    c(NA, 256, NA, -256, NA)
  )
  # Mixed widths in one column, which the grouping exists for.
  expect_identical(
    dec(list(as.raw(0x7f), as.raw(c(0x80, 0x01)), as.raw(c(0x00, 0x00, 0xff)))),
    c(127, -32767, 255)
  )
  expect_identical(dec(list(NULL, NULL)), c(NA_real_, NA_real_))
  expect_identical(dec(list()), numeric(0))

  # The scale divides, and applies to negatives too.
  expect_equal(dec(list(as.raw(c(0x04, 0xd2))), 2L), 12.34)
  expect_equal(dec(list(as.raw(c(0xfb, 0x2e))), 2L), -12.34)
})

test_that("vectorized FLOAT16 decoding covers every class of value", {
  half <- function(bits) list(as.raw(c(bits %% 256L, bits %/% 256L)))
  # Bit patterns from the IEEE 754 binary16 definition.
  expect_identical(qio_decode_float16(half(0x0000L)), 0)
  expect_identical(1 / qio_decode_float16(half(0x8000L)), -Inf) # signed zero
  expect_identical(qio_decode_float16(half(0x3C00L)), 1)
  expect_identical(qio_decode_float16(half(0xBC00L)), -1)
  expect_identical(qio_decode_float16(half(0x7C00L)), Inf)
  expect_identical(qio_decode_float16(half(0xFC00L)), -Inf)
  expect_true(is.nan(qio_decode_float16(half(0x7E00L))))
  expect_equal(qio_decode_float16(half(0x0001L)), 2^-24) # smallest subnormal
  expect_equal(qio_decode_float16(half(0x7BFFL)), 65504) # largest finite

  # Nulls interleaved, again with one first.
  expect_identical(
    qio_decode_float16(list(NULL, as.raw(c(0x00, 0x3C)), NULL)),
    c(NA_real_, 1, NA_real_)
  )
  expect_identical(qio_decode_float16(list()), numeric(0))
  expect_error(
    qio_decode_float16(list(as.raw(c(0x00, 0x3C, 0x00)))),
    "requires exactly 2"
  )
})


test_that("qio_decode_float16() decodes IEEE binary16", {
  half <- function(lo, hi) list(as.raw(c(lo, hi)))
  expect_identical(qio_decode_float16(half(0x00, 0x3C)), 1) # 1.0
  expect_identical(qio_decode_float16(half(0x00, 0xBC)), -1) # -1.0
  expect_identical(qio_decode_float16(half(0x00, 0x00)), 0) # +0
  expect_identical(qio_decode_float16(half(0x00, 0x40)), 2) # 2.0
  expect_identical(qio_decode_float16(half(0x00, 0x7C)), Inf)
  expect_identical(qio_decode_float16(half(0x00, 0xFC)), -Inf)
  expect_true(is.nan(qio_decode_float16(half(0x01, 0x7C))))
  # Smallest positive subnormal, 2^-24.
  expect_identical(qio_decode_float16(half(0x01, 0x00)), 2^-24)
  expect_identical(qio_decode_float16(list(NULL)), NA_real_)
})

test_that("qio_decode_float16() rejects a wrong byte count", {
  expect_error(qio_decode_float16(list(as.raw(1:3))), "exactly 2")
})

test_that("the plan maps text annotations to character and bytes to lists", {
  schema <- data.frame(
    name = c("s", "e", "j", "b", "raw", "fx", "u", "h"),
    path = c("s", "e", "j", "b", "raw", "fx", "u", "h"),
    physical_type = c(
      rep("BYTE_ARRAY", 5),
      rep("FIXED_LEN_BYTE_ARRAY", 3)
    ),
    logical_type = c(
      "STRING",
      "ENUM",
      "JSON",
      "BSON",
      NA,
      NA,
      "UUID",
      "FLOAT16"
    ),
    logical_details = NA_character_,
    max_definition_level = 0L,
    max_repetition_level = 0L,
    stringsAsFactors = FALSE
  )
  plan <- read_plan(schema)

  expect_identical(
    plan$r_type,
    c(
      "character", # STRING
      "character", # ENUM
      "character", # JSON
      "list", # BSON is bytes, not text
      "list", # unannotated BYTE_ARRAY
      "list", # unannotated FIXED_LEN_BYTE_ARRAY
      "character", # UUID
      "double" # FLOAT16
    )
  )
  expect_identical(
    plan$converter,
    c("text", "text", "text", "binary", "binary", "binary", "uuid", "float16")
  )
  expect_true(all(plan$collectible))
})

# --- Optional modes without their suggested package ------------------------

test_that("optional modes fail clearly when their package is unavailable", {
  # bit64 and hms are installed in development, so the missing-package branch
  # would otherwise never run. Mock the lookup rather than the packages.
  local_mocked_bindings(
    requireNamespace = function(package, ...) FALSE,
    .package = "base"
  )

  expect_error(qio_read_options(int64 = "integer64"), "needs the bit64 package")
  expect_error(qio_read_options(time = "hms"), "needs the hms package")

  # The defaults must not depend on either package.
  expect_silent(options <- qio_read_options())
  expect_identical(options$int64, "double")
  expect_identical(options$time, "numeric")
})

# --- Annotation combinations no available writer emits -----------------------
# `?qio-types` states a mapping for every physical/logical pair qio implements.
# Most are covered by a real file, but a handful cannot be: Apache Arrow writes
# a bare INT32 rather than an INTEGER(32, signed) annotation because the
# annotation is redundant, emits STRING rather than ENUM for a dictionary, and
# never produces INTERVAL or a variable-length DECIMAL. Those branches are
# reachable from a third-party file qio has simply never been handed, so they
# are pinned here at the resolution layer instead of left untested.
#
# These assert the same contract the table publishes. If the table changes,
# these fail.

resolve_one <- function(physical, logical, details = NA_character_) {
  qio_resolve_logical(data.frame(
    physical_type = physical,
    logical_type = logical,
    logical_details = details,
    stringsAsFactors = FALSE
  ))
}

test_that("a redundant signed INTEGER annotation keeps the physical mapping", {
  # Signed 32-bit in INT32, and signed 64-bit in INT64, add nothing over the
  # physical type; both must resolve exactly as the bare type does.
  wide32 <- resolve_one("INT32", "INTEGER", "bit_width=32, signed=true")
  expect_identical(wide32$r_type, "integer")
  expect_identical(wide32$converter, "int32")

  wide64 <- resolve_one("INT64", "INTEGER", "bit_width=64, signed=true")
  expect_identical(wide64$r_type, "double")
  expect_identical(wide64$converter, "int64_double")

  # ...and follows the int64 mode, like every other 64-bit column.
  as_bit64 <- qio_resolve_logical(
    data.frame(
      physical_type = "INT64",
      logical_type = "INTEGER",
      logical_details = "bit_width=64, signed=true",
      stringsAsFactors = FALSE
    ),
    options = list(int64 = "integer64", time = "numeric", tz = "UTC")
  )
  expect_identical(as_bit64$r_type, "integer64")
})

test_that("ENUM reads as text, like STRING and JSON", {
  enum <- resolve_one("BYTE_ARRAY", "ENUM")
  expect_identical(enum$r_type, "character")
  expect_identical(enum$converter, "text")
  # The same converter STRING and JSON use, which real fixtures do cover.
  expect_identical(enum$converter, resolve_one("BYTE_ARRAY", "JSON")$converter)
})

test_that("a variable-length DECIMAL uses the binary decimal path", {
  # pyarrow writes FIXED_LEN_BYTE_ARRAY even for decimal256, so only the
  # fixed-length form has a fixture; both share this converter.
  loose <- resolve_one("BYTE_ARRAY", "DECIMAL", "precision=20, scale=3")
  fixed <- resolve_one(
    "FIXED_LEN_BYTE_ARRAY",
    "DECIMAL",
    "precision=20, scale=3"
  )
  expect_identical(loose$r_type, "double")
  expect_identical(loose$converter, "decimal_binary_3")
  expect_identical(loose$converter, fixed$converter)
})

test_that("annotations with no R mapping stay bytes", {
  # INTERVAL and BSON are real annotations qio deliberately does not interpret.
  # Falling through to raw is the documented behavior, not an oversight.
  for (pair in list(
    c("FIXED_LEN_BYTE_ARRAY", "INTERVAL"),
    c("BYTE_ARRAY", "BSON")
  )) {
    resolved <- resolve_one(pair[1], pair[2])
    expect_identical(resolved$r_type, "list", info = pair[2])
    expect_identical(resolved$converter, "binary", info = pair[2])
  }
})

test_that("the NULL annotation wins over any physical type", {
  # The annotation means the column carries no values at all, so the physical
  # storage is irrelevant. Only INT32 storage has a fixture.
  for (physical in c("BOOLEAN", "INT32", "INT64", "DOUBLE", "BYTE_ARRAY")) {
    resolved <- resolve_one(physical, "NULL")
    expect_identical(resolved$r_type, "logical", info = physical)
    expect_identical(resolved$converter, "null_logical", info = physical)
  }
})
