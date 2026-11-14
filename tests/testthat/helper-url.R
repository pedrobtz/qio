local_url_parquet_file <- function(env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".parquet", .local_envir = env)
  write_parquet(data.frame(x = 1:3, y = c("a", "b", NA)), path)
  path
}

# `file://` needs an absolute path, and on Windows the conventional form has a
# third slash before the drive letter.
as_file_url <- function(path) {
  paste0("file://", if (.Platform$OS.type == "windows") "/" else "", path)
}
