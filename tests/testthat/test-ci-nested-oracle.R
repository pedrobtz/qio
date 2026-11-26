# Nested reading (#73) against an independent implementation: Apache Arrow's
# R package reads each file, and every column qio returns must hold the same
# values, nulls and empties as Arrow's at every level (helper-ci-nested.R has
# the canonical form). Left out of the tarball like the other test-ci-* files.

test_that("every nested column qio reads matches Arrow", {
  skip_without_oracle("arrow")
  skip_if_not_installed("bit64")
  for (name in nested_oracle_files()) {
    path <- test_path(name)
    # integer64, so that an INT64 past 2^53 is compared rather than the NA
    # qio's double mode substitutes for it by contract.
    result <- suppressMessages(suppressWarnings(
      read_parquet(path, int64 = "integer64")
    ))
    if (anyDuplicated(names(result))) {
      next # Arrow cannot look up a column by a repeated name.
    }
    expected <- canon_arrow_table(path, result)
    for (column in names(result)) {
      expect_equal(
        canon_qio(result[[column]]),
        expected[[column]],
        label = paste0(name, ": ", column)
      )
    }
  }
})

test_that("a projected struct matches Arrow's column", {
  skip_without_oracle("arrow")
  path <- test_path("parquet", "delta", "deltalake-checkpoint.parquet")
  file <- open_parquet(path)
  withr::defer(close_parquet(file))
  result <- collect(
    file,
    columns = c("add.path", "add.size", "add.partitionValues")
  )
  full <- canon_arrow_table(path, read_parquet(path)["add"])$add
  pruned <- lapply(full, function(row) {
    if (is.null(row)) NULL else row[c("path", "partitionValues", "size")]
  })
  expect_equal(canon_qio(result$add), pruned)
})
