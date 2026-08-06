# Write a Parquet file

Writes a data frame to an Apache Parquet file.

## Usage

``` r
write_parquet(
  x,
  file,
  compression = c("snappy", "zstd", "gzip", "lz4", "uncompressed"),
  schema = NULL,
  row_group_size = NULL,
  metadata = NULL,
  sorted_by = NULL,
  append = FALSE
)
```

## Arguments

- x:

  A data frame (or a list of equal-length atomic vectors).

- file:

  Output path.

- compression:

  Compression codec: one of `"snappy"` (default), `"zstd"`, `"gzip"`,
  `"lz4"`, or `"uncompressed"`.

- schema:

  An optional schema created by
  [`parquet_schema()`](https://pedrobtz.github.io/qio/reference/parquet_schema.md).
  Named entries override qio's inferred mapping; omitted columns retain
  automatic mapping.

- row_group_size:

  Rows per row group, or `NULL` (default) to write a single row group.
  Smaller groups let other readers skip more but add per-group metadata
  and can compress worse.

- metadata:

  A named character vector of footer key/value metadata, or `NULL`.
  Duplicate keys are written in the order given. An `NA` value is
  written as a key with no value, and reads back as `NA`.

- sorted_by:

  Columns the data is already sorted by, or `NULL`. Either a character
  vector of column names, meaning ascending with nulls last, or a data
  frame with a `name` column and optional logical `descending` and
  `nulls_first` columns. This **records a claim and nothing more**: qio
  does not sort the data and does not check that the claim is true. A
  wrong declaration misleads every reader that trusts it.

- append:

  Append new row groups to an existing file instead of replacing it. The
  file must already exist and describe exactly the columns being
  written; see Details.

## Value

The output path, invisibly.

## Details

Supported column types are logical, integer, double, character, and
factor (written as character). A column is written as nullable when it
contains any `NA`. `Date` columns are written as `INT32` with a `DATE`
annotation, and `POSIXct` columns as `INT64` microseconds with a
UTC-adjusted `TIMESTAMP` annotation; both round-trip back to their R
class. Sub-microsecond fractions of a second are rounded. Other classed
columns are still written using their underlying storage type and lose
their class. An explicit
[`parquet_schema()`](https://pedrobtz.github.io/qio/reference/parquet_schema.md)
may instead select `INT64`, `FLOAT`, or a different timestamp unit,
among the supported declarations.

`append` adds row groups to a file that already exists, rather than
replacing it. Because it writes into data the user already has, qio
checks compatibility itself and refuses anything it cannot prove safe.
The bundled library compares column count, order, names, physical types,
repetition type, and logical type *identity* – but not logical
*parameters*, so it would happily append microsecond timestamps to a
millisecond file, or a decimal of one scale to another. qio compares the
full declaration, including those parameters, and the schema path of
every column.

Nullability is taken from the existing file rather than inferred from
the new data, so appending a batch that happens to contain no `NA` to a
nullable column works. Appending data that does contain `NA` to a column
the file declares `REQUIRED` is refused.

Row groups are the unit other readers skip on: a reader that can rule a
group out from its statistics never touches its pages. `row_group_size`
sets how many rows go in each. The default writes one row group, which
keeps files compact but leaves nothing to skip, so a file meant to be
filtered by other tools should set it.

`metadata` writes application key/value pairs into the footer, where
[`metadata()`](https://pedrobtz.github.io/qio/reference/metadata.md)
reads them back. Keys and values are stored as UTF-8 text; Parquet
defines no meaning for them.

## See also

[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
[`metadata()`](https://pedrobtz.github.io/qio/reference/metadata.md),
[`row_groups()`](https://pedrobtz.github.io/qio/reference/row_groups.md)

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)

# Several row groups, with provenance in the footer.
write_parquet(
  mtcars,
  path,
  row_group_size = 8,
  metadata = c(source = "mtcars", written_by = "qio")
)
```
