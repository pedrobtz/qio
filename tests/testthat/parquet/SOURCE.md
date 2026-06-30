# External Parquet test fixtures

These files are copied verbatim from the Apache Parquet reference corpus and
are used to test reading real-world, third-party-written Parquet files.

- Source: <https://github.com/apache/parquet-testing/tree/master/data>
- Commit: `1a2a75127be06fc0123f03ebd36c966f7beda27d`
- License: Apache License 2.0

| File | Notable feature |
|------|-----------------|
| `alltypes_plain.parquet` | all primitive types, PLAIN, INT96 `timestamp_col` |
| `alltypes_plain.snappy.parquet` | same, Snappy-compressed |
| `alltypes_dictionary.parquet` | dictionary-encoded |
| `int96_from_spark.parquet` | INT96 timestamps written by Spark |
| `datapage_v2.snappy.parquet` | DATA_PAGE_V2 pages with delta encodings |
| `nested_maps.snappy.parquet` | nested `MAP` columns (repetition) |
| `nullable.impala.parquet` | nullable nested `LIST` columns (Impala) |

Note: `int96_from_spark.parquet` is the upstream name for what was requested as
`int96.parquet`.

The current reader supports flat schemas of the primitive types only; the tests
that exercise these files pin the present behavior (INT96, DATA_PAGE_V2 delta,
and nested columns are not yet readable) and should be promoted to positive
read assertions as those features land.
