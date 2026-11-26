# Nested columns (#73): structs, MAP and LIST of repetition level 1. The
# contract is .agents/TYPES.md, "Nested values"; fixtures and their provenance
# are in parquet/SOURCE.md.

# --- Values -----------------------------------------------------------------

test_that("every nested shape reads as TYPES.md describes it", {
  expect_identical(
    read_parquet(ext("nested_shapes.parquet")),
    expected_nested_shapes()
  )
})

test_that("one table written six ways reads as one R value", {
  # The differential pair: dictionary on and off, compression, small V1 and
  # V2 pages (with lists spanning pages and the empty data pages Arrow writes
  # between them), three row groups, and DELTA encodings.
  expected <- expected_nested_shapes()
  for (name in nested_shapes_variants) {
    expect_identical(read_parquet(ext(name)), expected, label = name)
    file <- open_parquet(ext(name))
    expect_identical(collect(file), expected, label = name)
    expect_identical(collect(file, batch_size = 1L), expected, label = name)
    close_parquet(file)
  }
})

test_that("row-group selection keeps nested rows aligned with flat ones", {
  file <- open_parquet(ext("nested_shapes-row-groups.parquet"))
  withr::defer(close_parquet(file))
  expected <- expected_nested_shapes()

  expect_identical(collect(file, row_groups = 2L), nested_rows(expected, 4:6))
  # Out of order, as row groups come back in file order.
  expect_identical(
    collect(file, row_groups = c(3L, 1L)),
    nested_rows(expected, -(4:6))
  )
})

test_that("a list straddling the 65,536-entry read chunk keeps its rows", {
  result <- read_parquet(ext("nested_long.parquet"))
  expect_identical(result$id, 1:5)
  expect_identical(
    result$l,
    list(as.integer(0:65534 %% 7), 7L, 8:9, integer(0), NULL)
  )
})

test_that("a zero-row file keeps the types of its nested columns", {
  result <- read_parquet(ext("nested_empty.parquet"))
  expect_identical(result, nested_rows(expected_nested_shapes(), 0))
  expect_identical(names(result$s), c("a", "b", "inner", "k"))
  expect_identical(is_null_struct(result$s), logical(0))
})

test_that("converters and their warnings reach nested leaves", {
  seen <- collect_warnings(read_parquet(ext("nested_edge.parquet")))
  result <- seen$value
  warnings <- seen$warnings
  expect_identical(result$s$v, c(NA, NA, 1))
  expect_identical(is_null_struct(result$s), c(FALSE, TRUE, FALSE))
  expect_identical(result$li, list(c(NA, 1L), integer(0), NULL))
  # One warning each, naming the complete path of the nested leaf.
  expect_length(warnings, 2L)
  expect_match(warnings[[1]], "'li.list.element'.*reserves -2147483648")
  expect_match(warnings[[2]], "'s.v'.*cannot be represented exactly")
})

test_that("int64 = \"integer64\" applies inside a struct", {
  skip_if_not_installed("bit64")
  result <- suppressWarnings(
    read_parquet(ext("nested_edge.parquet"), int64 = "integer64")
  )
  expect_s3_class(result$s$v, "integer64")
  expect_identical(
    as.character(result$s$v),
    c("9007199254740993", NA, "1")
  )
})

test_that("Delta checkpoints read with every action column", {
  path <- test_path("parquet", "delta", "deltalake-checkpoint.parquet")
  result <- read_parquet(path)
  expect_identical(
    names(result),
    c(
      "add",
      "remove",
      "metaData",
      "protocol",
      "txn",
      "domainMetadata",
      "sidecar"
    )
  )
  expect_identical(nrow(result), 11L)
  # The null counts pyarrow reports for each top-level struct.
  nulls <- vapply(result, function(x) sum(is_null_struct(x)), integer(1))
  expect_identical(unname(nulls), c(4L, 9L, 10L, 10L, 11L, 11L, 11L))

  add <- result$add[!is_null_struct(result$add), ]
  expect_identical(nrow(add), 7L)
  expect_identical(
    substr(add$path[1:2], 1L, 20L),
    c("part-00000-376dc423-", "part-00000-b637f24e-")
  )
  expect_identical(add$size[1:2], c(734, 729))
  expect_true(all(lengths(lapply(add$partitionValues, nrow)) == 1L))
  expect_identical(vapply(add$partitionValues, nrow, integer(1)), rep(0L, 7L))
  # deletionVector is null on every row, add or not.
  expect_true(all(is_null_struct(result$add$deletionVector)))

  protocol <- result$protocol[!is_null_struct(result$protocol), ]
  expect_identical(protocol$minReaderVersion, 1L)
  expect_identical(protocol$minWriterVersion, 2L)
  expect_identical(protocol$readerFeatures, list(NULL))

  meta <- result$metaData[!is_null_struct(result$metaData), ]
  expect_identical(meta$partitionColumns, list(character(0)))
  expect_identical(meta$format$provider, "parquet")
  expect_identical(
    meta$configuration[[1]],
    nested_map(character(0), character(0))
  )
})

test_that("a Spark V2 checkpoint keeps its feature lists", {
  path <- test_path("parquet", "delta", "spark-v2-checkpoint.parquet")
  result <- read_parquet(path)
  protocol <- result$protocol[!is_null_struct(result$protocol), ]
  expect_identical(protocol$minReaderVersion, 3L)
  expect_identical(protocol$readerFeatures, list("v2Checkpoint"))
  expect_identical(
    protocol$writerFeatures,
    list(c("v2Checkpoint", "appendOnly", "invariants"))
  )
  meta <- result$metaData[!is_null_struct(result$metaData), ]
  expect_identical(
    meta$configuration[[1]],
    nested_map("delta.checkpointPolicy", "v2")
  )
})

test_that("every Delta checkpoint fixture reads without skipping", {
  files <- list.files(test_path("parquet", "delta"), full.names = TRUE)
  expect_length(files, 5L)
  for (path in files) {
    expect_no_message(result <- read_parquet(path))
    plan <- read_plan(path)
    expect_true(all(plan$collectible), label = basename(path))
  }
  sidecar <- read_parquet(test_path(
    "parquet",
    "delta",
    "databricks-sidecar.parquet"
  ))
  expect_identical(sidecar$add$size[1:4], c(1045, 1044, 1186, 1185))
  expect_identical(sum(is_null_struct(sidecar$remove)), 5L)
})

# --- Projection ---------------------------------------------------------------

test_that("a leaf path prunes its struct and keeps the null mask", {
  file <- open_parquet(ext("nested_shapes.parquet"))
  withr::defer(close_parquet(file))
  expected <- expected_nested_shapes()

  result <- collect(file, columns = "s.a")
  expect_identical(names(result), "s")
  expect_identical(names(result$s), "a")
  expect_identical(result$s$a, expected$s$a)
  expect_identical(is_null_struct(result$s), is_null_struct(expected$s))

  # A nested struct alone, through its parent.
  inner <- collect(file, columns = "s.inner.x")$s
  expect_identical(names(inner), "inner")
  expect_identical(inner$inner, expected$s$inner)
})

test_that("a group path selects its leaves, in order of first mention", {
  file <- open_parquet(ext("nested_shapes.parquet"))
  withr::defer(close_parquet(file))
  expected <- expected_nested_shapes()

  expect_identical(collect(file, columns = "s"), expected["s"])
  expect_identical(
    collect(file, columns = c("tail", "m", "id")),
    expected[c("tail", "m", "id")]
  )
  # A union: the parent and one of its leaves select the parent once, with
  # its fields in schema order.
  expect_identical(collect(file, columns = c("s.k", "s")), expected["s"])
  expect_identical(
    names(collect(file, columns = c("s.k", "s.a"))$s),
    c("a", "k")
  )
  expect_identical(collect(file, columns = "sm.pv")$sm$pv, expected$sm$pv)
})

test_that("a path inside a LIST or MAP is refused with the path to use", {
  file <- open_parquet(ext("nested_shapes.parquet"))
  withr::defer(close_parquet(file))

  expect_error(
    collect(file, columns = "m.key_value.key"),
    "part of the LIST or MAP `m`; select `m` whole"
  )
  expect_error(
    collect(file, columns = "l.list.element"),
    "select `l` whole"
  )
  expect_error(
    collect(file, columns = "sm.pv.key_value"),
    "select `sm.pv` whole"
  )
  expect_error(
    collect(file, columns = c("nope", "s.z")),
    "Unknown Parquet columns: `nope`, `s.z`"
  )
})

# --- Unsupported shapes -------------------------------------------------------

test_that("unsupported shapes are skipped with one classed message", {
  path <- ext("nested_unsupported.parquet")
  condition <- NULL
  result <- withCallingHandlers(
    read_parquet(path),
    qio_message_nested_skipped = function(m) {
      condition <<- m
      invokeRestart("muffleMessage")
    }
  )
  expect_identical(names(result), c("id", "s", "tail"))
  expect_identical(result$tail, c("x", NA, "z"))
  expect_identical(result$s$v, c(1.5, NA, NA))
  expect_s3_class(condition, "qio_message_nested_skipped")
  expect_match(
    conditionMessage(condition),
    "Skipping 2 nested Parquet columns that qio cannot read: `ls` \\(list of structs\\), `ll` \\(nested list\\)"
  )
  expect_identical(
    condition$columns,
    data.frame(
      path = c("ls.list.element.a", "ll.list.element.list.element"),
      group = c("ls", "ll"),
      reason = c("list of structs", "nested list"),
      stringsAsFactors = FALSE
    )
  )
  plan <- read_plan(path)
  expect_identical(plan$collectible, c(TRUE, FALSE, TRUE, FALSE, TRUE))
  expect_match(
    plan$note[[2]],
    "`ls` is a list of structs, which qio does not read"
  )
})

test_that("selecting an unsupported shape is an error naming it", {
  file <- open_parquet(ext("nested_unsupported.parquet"))
  withr::defer(close_parquet(file))
  expect_error(collect(file, columns = "ls"), "`ls` is a list of structs")
  expect_error(
    collect(file, columns = "ls.list.element.a"),
    "`ls` is a list of structs"
  )
  expect_error(collect(file, columns = "ll"), "`ll` is a nested list")
})

test_that("walk_batches() stays flat and says so", {
  file <- open_parquet(ext("nested_shapes.parquet"))
  withr::defer(close_parquet(file))
  seen <- list()
  expect_message(
    walk_batches(file, function(batch, index) seen[[index]] <<- batch),
    "Skipping 15 nested Parquet columns: walk_batches\\(\\) reads flat columns only; use collect\\(\\)",
    class = "qio_message_nested_skipped"
  )
  expect_identical(
    do.call(rbind, seen),
    expected_nested_shapes()[c("id", "tail")]
  )
})

# --- Null structs ---------------------------------------------------------------

test_that("is_null_struct() follows row subsetting and refuses a stale mask", {
  result <- read_parquet(ext("nested_shapes.parquet"))
  s <- result$s
  expect_identical(
    is_null_struct(s),
    c(FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE)
  )
  expect_identical(is_null_struct(s[2:3, ]), c(TRUE, FALSE))
  expect_identical(
    is_null_struct(s[c(TRUE, FALSE), ]),
    c(FALSE, FALSE, FALSE, TRUE)
  )
  expect_identical(is_null_struct(result[7:8, ]$s), c(TRUE, FALSE))
  expect_identical(is_null_struct(head(result, 2L)$s$inner), c(FALSE, TRUE))
  expect_identical(is_null_struct(subset(result, id > 6L)$s), c(TRUE, FALSE))
  # Column selection keeps every row's mask.
  expect_identical(is_null_struct(s["a"]), is_null_struct(s))
  expect_identical(is_null_struct(s[, c("a", "b")]), is_null_struct(s))
  expect_identical(s[, "a"], s$a)
  # A required struct, and any other data frame, is never null.
  expect_identical(is_null_struct(result$rs), rep(FALSE, 8L))
  expect_identical(is_null_struct(mtcars[1:2, ]), c(FALSE, FALSE))
  expect_error(is_null_struct(1:3), "must be a data frame")
  combined <- rbind(result[1:2, ], result[3:4, ])
  expect_error(is_null_struct(combined$s), "no longer matches its rows")
})

# --- Failure part way ---------------------------------------------------------

test_that("a decode error part way through a nested column leaves no result", {
  path <- withr::local_tempfile(fileext = ".parquet")
  file.copy(ext("nested_shapes-plain.parquet"), path)
  probe <- open_parquet(path)
  chunks <- column_chunks(probe)
  close_parquet(probe)
  # The chunks follow the 4-byte magic back to back (no dictionary pages in
  # this variant), so this is where `m.key_value.value` starts: overwrite its
  # page header, which is read after `m`'s key has been.
  at <- which(chunks$path == "m.key_value.value")
  offset <- 4 + sum(chunks$compressed_bytes[seq_len(at - 1L)])
  bytes <- readBin(path, "raw", file.size(path))
  expect_identical(bytes[[offset + 1]], as.raw(0x15)) # a page header's first field
  bytes[offset + seq_len(8L)] <- as.raw(0xff)
  writeBin(bytes, path)

  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  expect_error(result <- collect(file), "m.key_value.value")
  expect_false(exists("result", inherits = FALSE))
  # The handle is not left busy: the columns before the damage still read.
  expect_identical(
    collect(file, columns = c("id", "s")),
    expected_nested_shapes()[c("id", "s")]
  )
})
