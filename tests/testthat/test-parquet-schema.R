test_that("infer_parquet_schema() describes automatic writer mappings", {
  x <- data.frame(
    flag = c(TRUE, FALSE),
    id = 1:2,
    value = c(1, NaN),
    text = c("a", NA),
    day = as.Date(c("2020-01-01", NA)),
    time = as.POSIXct(c("2020-01-01", NA), tz = "UTC")
  )

  result <- infer_parquet_schema(x)

  expect_s3_class(result, "qio_parquet_schema")
  expect_equal(
    result$physical_type,
    c("BOOLEAN", "INT32", "DOUBLE", "BYTE_ARRAY", "INT32", "INT64")
  )
  expect_equal(
    result$logical_type,
    c(NA, NA, NA, "STRING", "DATE", "TIMESTAMP")
  )
  expect_equal(
    result$repetition_type,
    c("REQUIRED", "REQUIRED", "REQUIRED", "OPTIONAL", "OPTIONAL", "OPTIONAL")
  )
})

test_that("parquet_schema() creates partial, parameterized schemas", {
  result <- parquet_schema(
    id = "INT64",
    price = list("FLOAT", repetition_type = "OPTIONAL"),
    created = list("TIMESTAMP", unit = "NANOS")
  )

  expect_s3_class(result, "qio_parquet_schema")
  expect_equal(result$name, c("id", "price", "created"))
  expect_equal(result$physical_type, c("INT64", "FLOAT", "INT64"))
  expect_equal(result$logical_type, c(NA, NA, "TIMESTAMP"))
  expect_match(result$logical_details[3], "unit=NANOS")
  expect_equal(result$repetition_type, c("AUTO", "OPTIONAL", "AUTO"))
})

test_that("write_parquet() applies partial schema overrides", {
  path <- withr::local_tempfile(fileext = ".parquet")
  x <- data.frame(id = 1:3, price = c(1.25, NA, 3.5), label = letters[1:3])

  write_parquet(x, path, schema = parquet_schema(id = "INT64", price = "FLOAT"))
  pf <- parquet_open(path)
  on.exit(parquet_close(pf), add = TRUE)

  info <- schema(pf)
  expect_equal(info$physical_type, c("INT64", "FLOAT", "BYTE_ARRAY"))
  expect_equal(info$repetition, c("REQUIRED", "OPTIONAL", "REQUIRED"))
  actual <- collect(pf)
  expect_equal(actual$id, as.double(x$id))
  expect_equal(actual$price, x$price, tolerance = 1e-6)
  expect_equal(actual$label, x$label)
})

test_that("write_parquet() applies every explicit simple scalar declaration", {
  path <- withr::local_tempfile(fileext = ".parquet")
  x <- data.frame(
    flag = c(TRUE, NA),
    count = c(1, 2),
    value = 1:2,
    label = factor(c("a", "b"))
  )
  requested <- parquet_schema(
    flag = "BOOLEAN",
    count = "INT32",
    value = "DOUBLE",
    label = "STRING"
  )

  write_parquet(x, path, schema = requested)
  pf <- parquet_open(path)
  on.exit(parquet_close(pf), add = TRUE)

  expect_equal(
    schema(pf)$physical_type,
    c("BOOLEAN", "INT32", "DOUBLE", "BYTE_ARRAY")
  )
  expect_equal(
    collect(pf),
    data.frame(
      flag = c(TRUE, NA),
      count = 1:2,
      value = c(1, 2),
      label = c("a", "b")
    )
  )
})

test_that("write_parquet() supports explicit DATE and timestamp units", {
  x <- data.frame(
    day = c(0, 1, NA),
    time = as.POSIXct(
      c("2020-01-01 00:00:00.123", NA, "1969-12-31"),
      tz = "UTC"
    )
  )
  for (unit in c("MILLIS", "MICROS", "NANOS")) {
    path <- withr::local_tempfile(fileext = ".parquet")
    requested <- parquet_schema(
      day = "DATE",
      time = list("TIMESTAMP", unit = unit)
    )
    write_parquet(x, path, schema = requested)
    pf <- parquet_open(path)
    on.exit(parquet_close(pf), add = TRUE)
    info <- schema(pf)

    expect_equal(info$logical_type, c("DATE", "TIMESTAMP"))
    expect_match(info$logical_details[2], paste0("unit=", unit))
    actual <- read_parquet(path)
    expect_equal(actual$day, structure(x$day, class = "Date"))
    expect_equal(
      as.double(actual$time),
      c(1577836800.123, NA, -86400),
      tolerance = 1e-7
    )
    parquet_close(pf)
  }
})

test_that("AUTO preserves inference and can override nullability", {
  path <- withr::local_tempfile(fileext = ".parquet")
  requested <- parquet_schema(x = list("AUTO", repetition_type = "OPTIONAL"))

  write_parquet(data.frame(x = 1:3), path, schema = requested)
  pf <- parquet_open(path)
  on.exit(parquet_close(pf), add = TRUE)

  expect_equal(schema(pf)$physical_type, "INT32")
  expect_equal(schema(pf)$repetition, "OPTIONAL")
})

test_that("an inferred schema can be reused", {
  path <- withr::local_tempfile(fileext = ".parquet")
  x <- data.frame(x = 1:3, y = c("a", NA, "c"))

  write_parquet(x, path, schema = infer_parquet_schema(x))

  expect_equal(read_parquet(path), x)
})

test_that("explicit INT64 stays within R's exact integer range", {
  path <- withr::local_tempfile(fileext = ".parquet")
  values <- c(-2^53, 2^53)

  write_parquet(
    data.frame(x = values),
    path,
    schema = parquet_schema(x = "INT64")
  )

  expect_equal(read_parquet(path)$x, values)
  expect_snapshot(
    error = TRUE,
    write_parquet(
      data.frame(x = 2^53 + 2),
      path,
      schema = parquet_schema(x = "INT64")
    )
  )
})

test_that("parquet_schema() rejects malformed declarations", {
  expect_snapshot(
    error = TRUE,
    parquet_schema(x = list("TIMESTAMP", unit = "SECONDS"))
  )
  expect_snapshot(
    error = TRUE,
    parquet_schema(x = list("TIMESTAMP", is_adjusted_utc = FALSE))
  )
  expect_snapshot(error = TRUE, parquet_schema("INT32"))
  expect_snapshot(error = TRUE, parquet_schema(x = "INT32", x = "INT64"))
})

test_that("REQUIRED rejects nulls before creating output", {
  path <- withr::local_tempfile()
  unlink(path)

  expect_snapshot(
    error = TRUE,
    write_parquet(
      data.frame(x = c(1, NA)),
      path,
      schema = parquet_schema(
        x = list("INT64", repetition_type = "REQUIRED")
      )
    )
  )
  expect_false(file.exists(path))
})

test_that("writer schemas reject incompatible column values before output", {
  path <- withr::local_tempfile()
  unlink(path)

  expect_snapshot(
    error = TRUE,
    write_parquet(
      data.frame(x = 1.5),
      path,
      schema = parquet_schema(x = "INT64")
    )
  )
  expect_snapshot(
    error = TRUE,
    write_parquet(
      data.frame(x = "not numeric"),
      path,
      schema = parquet_schema(x = "DOUBLE")
    )
  )
  expect_false(file.exists(path))
})

test_that("writer schemas reject missing and corrupted entries before output", {
  path <- withr::local_tempfile()
  unlink(path)

  expect_snapshot(
    error = TRUE,
    write_parquet(
      data.frame(x = 1),
      path,
      schema = parquet_schema(other = "INT32")
    )
  )
  broken <- parquet_schema(x = "INT32")
  broken$physical_type <- "INT96"
  expect_snapshot(
    error = TRUE,
    write_parquet(data.frame(x = 1), path, schema = broken)
  )
  expect_false(file.exists(path))
})

test_that("timestamp validation rejects values that cannot fit in INT64", {
  path <- withr::local_tempfile()
  unlink(path)
  seconds <- 2^63 / 1e9
  x <- data.frame(time = structure(seconds, class = c("POSIXct", "POSIXt")))

  expect_snapshot(
    error = TRUE,
    write_parquet(
      x,
      path,
      schema = parquet_schema(time = list("TIMESTAMP", unit = "NANOS"))
    )
  )
  expect_false(file.exists(path))
})

test_that("print.qio_parquet_schema() returns its input invisibly", {
  value <- parquet_schema(x = "INT32")
  expect_output(expect_invisible(print(value)), "qio_parquet_schema")
})
