# Collect data from a Parquet file

Columns are returned in requested order. Row groups are always returned
in their physical file order, even if their selector is not sorted.

## Usage

``` r
collect(x, ...)

# S3 method for class 'qio_parquet_file'
collect(
  x,
  ...,
  columns = NULL,
  row_groups = NULL,
  batch_size = 65536L,
  int64 = c("double", "integer64"),
  time = c("numeric", "hms"),
  tz = "UTC",
  verbose = FALSE
)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

- columns:

  Character vector of complete column paths, or `NULL` for all columns.
  Paths are matched exactly as
  [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md) and
  [`names()`](https://rdrr.io/r/base/names.html) report them,
  dot-separated for nested leaves, and never by leaf name alone: two
  leaves may share a name under different parents. A path may also name
  a group, which selects every leaf under it; see "Nested columns". An
  unknown path is an error, and so is a path matching more than one leaf
  or group.

- row_groups:

  Integer vector of 1-based row-group IDs, or `NULL` for all row groups.

- batch_size:

  Positive number of rows decoded at a time. It bounds the reader's
  scratch memory, not the size of the result (see Details);
  [`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
  additionally uses it as the size of each batch.

- int64:

  How 64-bit integer columns reach R. `"double"` (the default) is exact
  from `-2^53` through `2^53` and returns `NA` outside it. `"integer64"`
  returns
  [bit64::integer64](https://bit64.r-lib.org/reference/bit64-package.html),
  which needs the suggested `bit64` package and covers the signed 64-bit
  range **except its lowest value**: `bit64` reserves
  `-9223372036854775808` as its own `NA`, so a column storing
  `INT64_MIN` reads as `NA` in either mode. Either way values that
  cannot be represented become `NA`, and one warning naming the column
  is emitted for each column that lost values – once per column, however
  many values, row groups, or batches were affected, and never for a
  column that lost nothing. Unsigned 64-bit columns are never returned
  as negative numbers.

- time:

  How `TIME` columns reach R: `"numeric"` (the default) returns seconds
  since midnight, `"hms"` returns
  [hms::hms](https://hms.tidyverse.org/reference/hms.html) and needs the
  suggested `hms` package. Neither returns `POSIXct`, because a time of
  day is not an instant.

- tz:

  Time zone name, `"UTC"` by default. A UTC-adjusted `TIMESTAMP` is an
  instant, so `tz` changes only how it prints. A non-UTC `TIMESTAMP` is
  a wall clock with no zone stored, so its civil components are
  interpreted in `tz`; base R decides ambiguous and nonexistent times at
  daylight-saving boundaries. The machine's local zone is never used
  implicitly.

- verbose:

  Report what the read is about to do before doing it: the rows,
  columns, and row groups selected, the batch size, and the resolved
  [`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
  for the selected columns only – not for the whole file, so it answers
  "what am I about to get". Written with
  [`message()`](https://rdrr.io/r/base/message.html), so it goes to
  stderr and [`suppressMessages()`](https://rdrr.io/r/base/message.html)
  silences it.

## Value

A data frame. Nested columns are data-frame and list columns; see the
"Nested columns" section.

## Details

`collect()` returns the whole selection, so `batch_size` does not bound
the result; use
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
for that. It does bound the scratch memory the reader allocates while
decoding string and binary columns, which would otherwise scale with the
largest selected row group rather than with anything the caller
controls. Smaller batches lower peak memory and cost a little throughput
on dictionary-encoded text.

Nested columns are read since qio 0.2.0; see the "Nested columns"
section.

## Nested columns

A top-level Parquet group becomes one column of the result, named by its
field name:

- A **struct** is a data-frame column with one column per field (structs
  nest to any depth). A null struct and a struct whose fields are all
  null both have `NA` in every field, so an optional struct carries
  which rows are null;
  [`is_null_struct()`](https://pedrobtz.github.io/qio/reference/is_null_struct.md)
  returns them.

- A **`LIST`** is a list-column with one vector per row: `NULL` for a
  null list, a zero-length vector for an empty one, and `NA` for a null
  element. A list of binary values is a list of lists of raw vectors.

- A **`MAP`** is a list-column with one data frame per row, its columns
  always named `key` and `value`: `NULL` for a null map, a zero-row data
  frame for an empty one. Keys need not be strings or unique, so a map
  is not a named vector.

Under a null struct every field is `NA` and every list or map `NULL`.
Elements, keys, values and fields get the same R types as flat columns,
and `int64`, `time` and `tz` apply to them.

`columns` takes the complete path of a leaf or of a group. A leaf path,
such as `"add.path"`, returns its top-level struct with only the
selected fields, in schema order, and keeps the struct's null rows; a
group path selects every leaf under it. A `LIST` or `MAP` is selected
whole by its own path: a path inside one (`"add.tags.key_value.key"`) is
an error naming the path to use. Top-level columns come in the order
they are first named.

qio reads lists and maps whose elements, keys and values are not
themselves lists, maps or structs (a repetition level of at most 1).
Anything deeper – a list of structs, a list of lists, a map with struct
values, legacy two-level lists, bare repeated fields and `VARIANT` – is
never flattened: read with every column, or through an ancestor, it is
left out with one message of class `qio_message_nested_skipped`, whose
`columns` field is a data frame of the leaves left out with their
`group` and `reason`; named in `columns`, it is an error.
[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
marks such leaves not collectible and says why.
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
reads flat columns only.

## Decimal columns

A `DECIMAL` column is read as `double` with its scale applied, so its
values may be inexact. The unscaled integer survives the conversion only
while it is within `[-2^53, 2^53]`, which every `DECIMAL(p, s)` with
`p <= 15` satisfies; the result is then the `double` nearest the
decimal. A read that selects any decimal column signals one message, of
class `qio_message_decimal_double` (inheriting from `message` and
`condition`), however many columns, row groups or batches it covers. Its
`columns` field is a data frame with one row per selected decimal
column: `path` (the complete column path), `physical_type`, and integer
`precision` and `scale`. A caller that has checked those columns can
silence exactly this message:

    withCallingHandlers(
      collect(pf),
      qio_message_decimal_double = function(m) {
        if (all(m$columns$precision <= 15L)) invokeRestart("muffleMessage")
      }
    )

## See also

[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
for the handle and for `mmap` and `threads`,
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
to process a file that does not fit in memory,
[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
to preview the R type of every column, and
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
which is
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
plus `collect()` for a whole file.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
collect(pf, columns = c("mpg", "cyl"))
#>     mpg cyl
#> 1  21.0   6
#> 2  21.0   6
#> 3  22.8   4
#> 4  21.4   6
#> 5  18.7   8
#> 6  18.1   6
#> 7  14.3   8
#> 8  24.4   4
#> 9  22.8   4
#> 10 19.2   6
#> 11 17.8   6
#> 12 16.4   8
#> 13 17.3   8
#> 14 15.2   8
#> 15 10.4   8
#> 16 10.4   8
#> 17 14.7   8
#> 18 32.4   4
#> 19 30.4   4
#> 20 33.9   4
#> 21 21.5   4
#> 22 15.5   8
#> 23 15.2   8
#> 24 13.3   8
#> 25 19.2   8
#> 26 27.3   4
#> 27 26.0   4
#> 28 30.4   4
#> 29 15.8   8
#> 30 19.7   6
#> 31 15.0   8
#> 32 21.4   4
close_parquet(pf)
```
