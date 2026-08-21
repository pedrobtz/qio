# Getting started with qio

``` r

library(qio)
```

A Parquet file is columnar, compressed, and self-describing: it carries
its own schema and per-chunk statistics in a footer. qio is built around
that shape. Reading a whole file is one call, but the interesting part
is that you can read the footer alone, decide what you need, and
decompress only that.

## A whole file at a time

[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
and
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md)
are the eager pair.

``` r

path <- tempfile(fileext = ".parquet")
write_parquet(mtcars, path)

cars <- read_parquet(path)
dim(cars)
#> [1] 32 11
```

Row names are not a Parquet concept, so they do not survive the round
trip. Everything else does, subject to the type mapping in `?qio-types`.

## Looking before reading

The rest of this article uses a bundled file written by pyarrow, so the
inspection functions have something real to report.

``` r

path <- system.file("extdata", "bloom_sorted.parquet", package = "qio")
pf <- open_parquet(path)
pf
#> <qio_parquet_file>
#> /home/runner/work/_temp/Library/qio/extdata/bloom_sorted.parquet
#> 4000 rows x 3 columns; 4 row groups
```

[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
reads the footer, not the data. The handle is cheap, and everything
below answers from metadata alone.

``` r

schema(pf)
#>   column  name  path physical_type logical_type logical_details repetition_type
#> 1      1   key   key         INT64         <NA>            <NA>        OPTIONAL
#> 2      2 label label    BYTE_ARRAY       STRING            <NA>        OPTIONAL
#> 3      3 score score        DOUBLE         <NA>            <NA>        OPTIONAL
#>   type_length max_definition_level max_repetition_level
#> 1           0                    1                    0
#> 2           0                    1                    0
#> 3           0                    1                    0
```

[`schema()`](https://pedrobtz.github.io/qio/reference/schema.md) reports
what the *file* says.
[`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
reports what R will actually get, which is the question you usually
have:

``` r

read_plan(pf)[, c("path", "physical_type", "logical_type", "r_type")]
#> <qio_read_plan: 3 columns>
#>    path physical_type logical_type    r_type
#> 1   key         INT64         <NA>    double
#> 2 label    BYTE_ARRAY       STRING character
#> 3 score        DOUBLE         <NA>    double
```

The plan is a pure function of the schema and your read options, so it
is the same for
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md),
[`collect()`](https://pedrobtz.github.io/qio/reference/collect.md), and
[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md).
If a column would arrive as something you did not expect, you find out
here rather than after a long read.

Row groups are the unit of selective reading:

``` r

row_groups(pf)
#>   row_group rows compressed_bytes uncompressed_bytes
#> 1         1 1000            12769              26293
#> 2         2 1000            12776              26293
#> 3         3 1000            12780              26293
#> 4         4 1000            12780              26293
```

## Reading only what you need

A column you do not select is never decompressed, which is the cheapest
speed-up available on a wide file.

``` r

head(collect(pf, columns = c("key", "label")), 3)
#>   key      label
#> 1   0 item-00000
#> 2   1 item-00001
#> 3   2 item-00002
```

Row groups select the other axis, and the two compose:

``` r

nrow(collect(pf, row_groups = 1))
#> [1] 1000
nrow(collect(pf, columns = "key", row_groups = c(1, 2)))
#> [1] 2000
```

## Reading from a URL

[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md)
and
[`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
accept an `http://`, `https://`, `ftp://`, `ftps://` or `file://` URL as
well as a path:

``` r

remote <- read_parquet("https://example.com/data.parquet")
```

The whole file is downloaded to the session temporary directory before
any of it is read, and the copy is removed when the read finishes – or,
for a handle, when you call
[`close_parquet()`](https://pedrobtz.github.io/qio/reference/close_parquet.md).
Selecting columns or row groups from a URL therefore saves decoding but
not transfer, so for a large remote file it is usually better to
download once yourself and read the local copy repeatedly.
`?qio-limitations` explains why qio cannot fetch only the parts it
needs.

Writing to a URL is refused rather than silently written somewhere
local.

## Files larger than memory

[`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
calls your function once per batch and keeps one batch alive at a time,
so peak memory follows `batch_size` rather than file size.

``` r

total <- 0
walk_batches(pf, batch_size = 1000, FUN = function(batch, index) {
  total <<- total + sum(batch$score)
})
total
#> [1] 47787.25
```

## What the file knows about itself

Parquet stores per-chunk statistics, and writers may add a page index or
a bloom filter. qio surfaces all three, which is how you prune work
before doing it.

``` r

column_statistics(pf)[1:3, c("row_group", "path", "null_count", "min", "max")]
#>   row_group  path null_count        min        max
#> 1         1   key          0          0        999
#> 2         1 label          0 item-00000 item-00999
#> 3         1 score          0          0         24
```

A bloom filter answers exactly one question – is this value *definitely
absent* – and never proves presence:

``` r

bloom_filter_may_contain(pf, "key", c(42, 123456))
#> [1]  TRUE FALSE
```

`FALSE` is a guarantee; `TRUE` means “maybe, go and read”. qio’s own
writer emits no bloom filters, which is why this file came from
elsewhere.

``` r

close_parquet(pf)
```

Handles hold an open file. Close them when you are done;
[`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md)
opens and closes one for you.

## Types worth knowing about

Two mappings surprise people, and both are deliberate.

**64-bit integers.** R has no native 64-bit integer. By default `INT64`
becomes `double`, which is exact to 2^53 and `NA` beyond it, with one
warning naming the column. Pass `int64 = "integer64"` for the full
range, which needs the suggested `bit64` package.

**Bytes are not text.** An unannotated `BYTE_ARRAY` is arbitrary bytes
and reads as a list of raw vectors. It becomes `character` only when the
file says so with a `STRING`, `ENUM`, or `JSON` annotation. Text is
validated as UTF-8, and an invalid value fails with its column and row
rather than arriving as mojibake.

`?qio-types` documents every mapping and where precision is lost.

## Writing

Inference covers the ordinary R types. Where one R type could mean
several Parquet types,
[`parquet_schema()`](https://pedrobtz.github.io/qio/reference/parquet_schema.md)
decides:

``` r

types <- parquet_schema(mpg = "FLOAT", cyl = "INT64")
out <- tempfile(fileext = ".parquet")
write_parquet(mtcars, out, schema = types, compression = "zstd")

infer_parquet_schema(mtcars[, c("mpg", "cyl")])
#> <qio_parquet_schema: 2 columns>
#>   name physical_type logical_type logical_details repetition_type
#> 1  mpg        DOUBLE         <NA>            <NA>        REQUIRED
#> 2  cyl        DOUBLE         <NA>            <NA>        REQUIRED
```

[`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
also takes `row_group_size`, `metadata`, `sorted_by`, and `append`.

## What qio does not do

Nested and repeated columns are skipped with a message, decimals read as
`double` rather than exact fixed-point, and several types can be read
but not written. None of that is accidental; `?qio-limitations` records
each one and why, so you can tell a deliberate boundary from a bug.
