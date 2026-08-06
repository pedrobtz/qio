# Check that a file is structurally valid Parquet

Reports why a file cannot be read, in terms of the file rather than of
the parser. Opening a damaged or misidentified file otherwise fails
somewhere inside footer parsing, with a message that describes a byte
offset instead of the problem.

## Usage

``` r
validate_parquet(file)
```

## Arguments

- file:

  Path to a file.

## Value

`TRUE`, invisibly. Raises an error describing the first problem found
otherwise.

## Details

What is checked: the file exists and is large enough to be Parquet, both
magic markers are present, the footer parses, and the schema and
row-group metadata agree with the file's own row count.

What is **not** checked: the data pages. Structural validity says a
reader can find the columns, not that their bytes decode or that the
recorded statistics are true. To check the pages, read the file with
`open_parquet(verify_checksums = TRUE)` and
[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md); that
costs a full read, which is why it is not done here.

## See also

[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md),
[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md)

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
validate_parquet(path)

# A file that is not Parquet at all.
plain <- tempfile()
writeLines("not parquet", plain)
try(validate_parquet(plain))
#> Error : `file` does not start with the Parquet marker 'PAR1', so it is not a Parquet file.
```
