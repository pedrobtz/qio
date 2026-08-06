# Package index

## Read and write

- [`read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.md)
  : Read a Parquet file
- [`write_parquet()`](https://pedrobtz.github.io/qio/reference/write_parquet.md)
  : Write a Parquet file
- [`parquet_schema()`](https://pedrobtz.github.io/qio/reference/parquet_schema.md)
  : Create a Parquet writer schema
- [`infer_parquet_schema()`](https://pedrobtz.github.io/qio/reference/infer_parquet_schema.md)
  : Infer the Parquet writer schema for an R object
- [`parquet_type_mapping()`](https://pedrobtz.github.io/qio/reference/parquet_type_mapping.md)
  : Show Parquet physical type mappings
- [`qio-types`](https://pedrobtz.github.io/qio/reference/qio-types.md) :
  Parquet type mapping

## Lazy reading

- [`open_parquet()`](https://pedrobtz.github.io/qio/reference/open_parquet.md)
  : Open a Parquet file
- [`close_parquet()`](https://pedrobtz.github.io/qio/reference/close_parquet.md)
  : Close a Parquet file
- [`collect()`](https://pedrobtz.github.io/qio/reference/collect.md) :
  Collect data from a Parquet file
- [`walk_batches()`](https://pedrobtz.github.io/qio/reference/walk_batches.md)
  : Walk over batches from a Parquet file

## Inspect files

- [`schema()`](https://pedrobtz.github.io/qio/reference/schema.md) :
  Inspect a Parquet schema
- [`row_groups()`](https://pedrobtz.github.io/qio/reference/row_groups.md)
  : Inspect Parquet row groups
- [`column_chunks()`](https://pedrobtz.github.io/qio/reference/column_chunks.md)
  : Inspect Parquet column chunks
- [`column_statistics()`](https://pedrobtz.github.io/qio/reference/column_statistics.md)
  : Inspect Parquet column statistics
- [`page_index()`](https://pedrobtz.github.io/qio/reference/page_index.md)
  : Inspect Parquet page indexes
- [`bloom_filter_may_contain()`](https://pedrobtz.github.io/qio/reference/bloom_filter_may_contain.md)
  : Test values against a Parquet bloom filter
- [`metadata()`](https://pedrobtz.github.io/qio/reference/metadata.md) :
  Inspect Parquet footer metadata
- [`read_plan()`](https://pedrobtz.github.io/qio/reference/read_plan.md)
  : Plan how a Parquet file is read into R
- [`validate_parquet()`](https://pedrobtz.github.io/qio/reference/validate_parquet.md)
  : Check that a file is structurally valid Parquet

## Package

- [`qio`](https://pedrobtz.github.io/qio/reference/qio-package.md)
  [`qio-package`](https://pedrobtz.github.io/qio/reference/qio-package.md)
  : qio: Read and Write 'Apache Parquet' Files
- [`qio-limitations`](https://pedrobtz.github.io/qio/reference/qio-limitations.md)
  : What qio does not do
