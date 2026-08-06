# Open a Parquet file

Opens a Parquet file for inexpensive metadata inspection and selective,
batched reading. The returned handle is valid only in the current R
session.

## Usage

``` r
open_parquet(file, mmap = FALSE, verify_checksums = TRUE, threads = NULL)
```

## Arguments

- file:

  Path to a Parquet file.

- mmap:

  Use memory-mapped input. On Windows a path the active code page cannot
  represent is read with buffered input instead, because only the mapped
  path needs a name that page can express. The result is the same.

- verify_checksums:

  Verify Parquet page checksums when present.

- threads:

  Number of reader threads, or `NULL` (the default) to pick the
  machine's core count. `0` means the same as `NULL`.
  [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md)
  decodes columns in parallel either way: a mapped file shares one
  reader, and a buffered one gives each worker its own. Pass
  `threads = 1` to force serial reads.

## Value

A `qio_parquet_file` object. Close it with
[`close_parquet()`](https://pedrobtz.github.io/qio/reference/close_parquet.md).

## See also

[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md) and
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
to read from the handle,
[`close_parquet()`](https://pedrobtz.github.io/qio/reference/close_parquet.md)
to release it,
[`schema()`](https://pedrobtz.github.io/qio/reference/schema.md) and
[`metadata()`](https://pedrobtz.github.io/qio/reference/metadata.md) to
inspect it without reading, and
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md)
for a whole file in one call.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
dim(pf)
#> [1] 32 11
close_parquet(pf)
```
