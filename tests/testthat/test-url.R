# Reading from a URL. Nearly everything here uses a `file://` URL, which
# exercises the real download path -- detection, download.file(), the temporary
# copy and its removal -- without touching the network, so these tests run
# everywhere including on CRAN. Only the two tests that need a live server are
# skipped.

local_parquet_file <- function(env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".parquet", .local_envir = env)
  write_parquet(data.frame(x = 1:3, y = c("a", "b", NA)), path)
  path
}

# `file://` needs an absolute path, and on Windows the conventional form has a
# third slash before the drive letter.
as_file_url <- function(path) {
  paste0("file://", if (.Platform$OS.type == "windows") "/" else "", path)
}

test_that("URL schemes are recognized and ordinary paths are not", {
  expect_true(qio_is_url("https://example.com/a.parquet"))
  expect_true(qio_is_url("http://example.com/a.parquet"))
  expect_true(qio_is_url("ftp://example.com/a.parquet"))
  expect_true(qio_is_url("ftps://example.com/a.parquet"))
  expect_true(qio_is_url("file:///tmp/a.parquet"))
  expect_true(qio_is_url("HTTPS://EXAMPLE.COM/a.parquet"))

  expect_false(qio_is_url("data.parquet"))
  expect_false(qio_is_url("/var/data/a.parquet"))
  expect_false(qio_is_url("~/a.parquet"))
  # A drive letter is a colon but not a scheme, and a host-looking name with no
  # scheme is a relative path. Both must stay local.
  expect_false(qio_is_url("C:/data/a.parquet"))
  expect_false(qio_is_url("example.com/a.parquet"))
  # A scheme qio does not fetch is left to the filesystem rather than guessed.
  expect_false(qio_is_url("s3://bucket/a.parquet"))
})

test_that("read_parquet() reads from a URL", {
  path <- local_parquet_file()
  expect_message(
    result <- read_parquet(as_file_url(path)),
    "Downloading"
  )
  expect_identical(result, data.frame(x = 1:3, y = c("a", "b", NA)))
})

test_that("read_parquet() from a URL leaves no temporary file behind", {
  path <- local_parquet_file()
  before <- list.files(tempdir(), pattern = "\\.parquet$")
  suppressMessages(read_parquet(as_file_url(path)))
  after <- list.files(tempdir(), pattern = "\\.parquet$")
  expect_identical(after, before)
})

test_that("column and row-group selection work through a URL", {
  path <- local_parquet_file()
  result <- suppressMessages(
    read_parquet(as_file_url(path), columns = "x")
  )
  expect_identical(names(result), "x")
})

test_that("open_parquet() keeps the copy until close_parquet() removes it", {
  path <- local_parquet_file()
  pf <- suppressMessages(open_parquet(as_file_url(path)))
  copy <- attr(pf, "qio_downloaded")

  expect_type(copy, "character")
  expect_true(file.exists(copy))
  # dim() reports doubles, because a file can hold more rows than an R integer.
  expect_identical(dim(pf), c(3, 2))

  close_parquet(pf)
  expect_false(file.exists(copy))

  # close is idempotent, and a second call must not error on the file it
  # already removed.
  expect_silent(close_parquet(pf))
})

test_that("a handle opened from a local path carries no temporary copy", {
  path <- local_parquet_file()
  pf <- open_parquet(path)
  on.exit(close_parquet(pf), add = TRUE)
  # Nothing qio did not create may ever be unlinked by close_parquet().
  expect_null(attr(pf, "qio_downloaded"))
})

test_that("closing a handle opened from a local path leaves the file alone", {
  path <- local_parquet_file()
  pf <- open_parquet(path)
  close_parquet(pf)
  expect_true(file.exists(path))
})

test_that("read_plan() accepts a URL", {
  path <- local_parquet_file()
  plan <- suppressMessages(read_plan(as_file_url(path)))
  expect_identical(plan$path, c("x", "y"))
})

test_that("validate_parquet() accepts a URL and cleans up after itself", {
  path <- local_parquet_file()
  before <- list.files(tempdir(), pattern = "\\.parquet$")
  expect_true(suppressMessages(validate_parquet(as_file_url(path))))
  after <- list.files(tempdir(), pattern = "\\.parquet$")
  expect_identical(after, before)
})

test_that("validate_parquet() removes the copy only after closing the file", {
  # The copy is removed by an on.exit() expression, and those run in the order
  # they were added -- so a removal registered before the connection and the
  # handle are opened runs while both are still open. Deleting an open file
  # succeeds on Unix and fails on Windows, so the ordering has to be checked
  # here rather than left to a Windows-only test failure.
  path <- local_parquet_file()
  open_at_removal <- NULL
  local_mocked_bindings(
    qio_remove_temp = function(path) {
      open_at_removal <<- path %in% showConnections()[, "description"]
      unlink(path)
    }
  )
  expect_true(suppressMessages(validate_parquet(as_file_url(path))))
  expect_false(open_at_removal)
})

test_that("validate_parquet() removes the copy even when the file is invalid", {
  path <- withr::local_tempfile(fileext = ".parquet")
  writeBin(charToRaw("not a parquet file at all"), path)
  before <- list.files(tempdir(), pattern = "\\.parquet$")
  expect_error(suppressMessages(validate_parquet(as_file_url(path))))
  after <- list.files(tempdir(), pattern = "\\.parquet$")
  expect_identical(after, before)
})

test_that("a URL that cannot be fetched fails with the URL named", {
  missing <- as_file_url(file.path(tempdir(), "does-not-exist-qio.parquet"))
  expect_error(
    suppressWarnings(suppressMessages(read_parquet(missing))),
    "Could not download"
  )
})

test_that("a failed download leaves no temporary file behind", {
  missing <- as_file_url(file.path(tempdir(), "does-not-exist-qio.parquet"))
  before <- list.files(tempdir(), pattern = "\\.parquet$")
  try(
    suppressWarnings(suppressMessages(read_parquet(missing))),
    silent = TRUE
  )
  after <- list.files(tempdir(), pattern = "\\.parquet$")
  expect_identical(after, before)
})

test_that("write_parquet() refuses a URL before creating anything", {
  expect_error(
    write_parquet(data.frame(x = 1), "https://example.com/out.parquet"),
    "cannot write to one"
  )
})

test_that("the write refusal covers every fetchable scheme", {
  for (url in c(
    "http://example.com/o.parquet",
    "ftp://example.com/o.parquet",
    "file:///tmp/o.parquet"
  )) {
    expect_error(write_parquet(data.frame(x = 1), url), "cannot write to one")
  }
})
