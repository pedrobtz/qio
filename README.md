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

## References

- [Apache Parquet](https://parquet.apache.org/docs/)
- [`carquet`](https://github.com/Vitruves/carquet)
