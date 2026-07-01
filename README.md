# qio

`qio` reads and writes Apache Parquet files from R. It uses the fast,
C-based `carquet` library.

## Installation

```r
install.packages("qio")
```

Install the development version from GitHub with:

```r
pak::pak("pedrobtz/qio")
```

## Examples

Write a data frame:

```r
qio::write_parquet(mtcars, "mtcars.parquet")
```

Read a Parquet file:

```r
cars <- qio::read_parquet("mtcars.parquet")
```

Override an inferred writer type when needed:

```r
types <- qio::parquet_schema(mpg = "FLOAT", cyl = "INT64")
qio::write_parquet(mtcars, "mtcars.parquet", schema = types)
```

Open a file for inspection and selective reading:

```r
pf <- qio::parquet_open("mtcars.parquet")
pf
#> <qio_parquet_file>
#> /path/to/mtcars.parquet
#> 32 rows x 11 columns; 1 row group

dim(pf)      # c(32L, 11L)
names(pf)    # column names
schema(pf)   # column types and physical encodings

# Read only two columns
df <- collect(pf, columns = c("mpg", "cyl"))

qio::parquet_close(pf)
```

## References

- [Apache Parquet](https://parquet.apache.org/docs/)
- [`carquet`](https://github.com/Vitruves/carquet)
