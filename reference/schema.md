# Inspect a Parquet schema

Reports every physical leaf column in the file, in file order.

## Usage

``` r
schema(x, ...)

# S3 method for class 'qio_parquet_file'
schema(x, ...)
```

## Arguments

- x:

  A `qio_parquet_file` object.

- ...:

  Reserved for future use.

## Value

A data frame with one row per physical leaf column and the columns:

- `column`:

  1-based physical column index.

- `name`:

  Bare leaf name; not unique. See Details.

- `path`:

  Complete dotted path; unique, and what selection uses.

- `physical_type`:

  Parquet physical type.

- `logical_type`:

  Logical annotation, or `NA` when absent.

- `logical_details`:

  Annotation parameters, such as a timestamp unit or a decimal precision
  and scale; `NA` when there are none.

- `repetition_type`:

  `"REQUIRED"`, `"OPTIONAL"`, or `"REPEATED"`.

- `type_length`:

  Declared width of a `FIXED_LEN_BYTE_ARRAY`, else 0.

- `max_definition_level`:

  Above 0 when the leaf is nullable.

- `max_repetition_level`:

  Above 0 when the leaf is repeated.

## Details

**`name` and `path` are not interchangeable.** `name` is the bare leaf
name and is not unique: two leaves under different parents may share
one, and a map's key/value leaves routinely do. `path` is the complete
dotted path and is what identifies a column everywhere else in qio –
[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md),
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md),
and
[`bloom_filter_may_contain()`](https://pedrobtz.github.io/qio/reference/bloom_filter_may_contain.md)
all select by path, and
[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md),
[`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md),
and
[`page_index()`](https://pedrobtz.github.io/qio/reference/page_index.md)
report it under the same name.

## See also

[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
for the R type each column will produce,
[`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md)
for how each is stored, and
[`parquet_type_mapping()`](https://pedrobtz.github.io/qio/reference/parquet_type_mapping.md)
for the physical fallbacks.

## Examples

``` r
path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)
pf <- open_parquet(path)
schema(pf)
#>    column name path physical_type logical_type logical_details repetition_type
#> 1       1  mpg  mpg        DOUBLE         <NA>            <NA>        REQUIRED
#> 2       2  cyl  cyl        DOUBLE         <NA>            <NA>        REQUIRED
#> 3       3 disp disp        DOUBLE         <NA>            <NA>        REQUIRED
#> 4       4   hp   hp        DOUBLE         <NA>            <NA>        REQUIRED
#> 5       5 drat drat        DOUBLE         <NA>            <NA>        REQUIRED
#> 6       6   wt   wt        DOUBLE         <NA>            <NA>        REQUIRED
#> 7       7 qsec qsec        DOUBLE         <NA>            <NA>        REQUIRED
#> 8       8   vs   vs        DOUBLE         <NA>            <NA>        REQUIRED
#> 9       9   am   am        DOUBLE         <NA>            <NA>        REQUIRED
#> 10     10 gear gear        DOUBLE         <NA>            <NA>        REQUIRED
#> 11     11 carb carb        DOUBLE         <NA>            <NA>        REQUIRED
#>    type_length max_definition_level max_repetition_level
#> 1            0                    0                    0
#> 2            0                    0                    0
#> 3            0                    0                    0
#> 4            0                    0                    0
#> 5            0                    0                    0
#> 6            0                    0                    0
#> 7            0                    0                    0
#> 8            0                    0                    0
#> 9            0                    0                    0
#> 10           0                    0                    0
#> 11           0                    0                    0
close_parquet(pf)
```
