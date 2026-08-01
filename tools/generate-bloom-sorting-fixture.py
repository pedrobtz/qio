#!/usr/bin/env python3
"""Generate a Parquet fixture carrying bloom filters, page indexes, and a
declared sort order.

qio's writer emits none of the three, so nothing it produces can test the
inspection side of any of them. pyarrow writes all three, and is the same
independently written C++ implementation used elsewhere in this corpus.

Requires pyarrow. Not run during the build or the test suite; the generated
file is committed under tests/testthat/parquet/ with its provenance recorded in
the adjacent SOURCE.md.

Usage:
    python3 tools/generate-bloom-sorting-fixture.py [output.parquet]
"""

import sys

import pyarrow as pa
import pyarrow.parquet as pq

N = 4000
OUT = sys.argv[1] if len(sys.argv) > 1 else "bloom_sorted.parquet"

# `key` is sorted ascending so the declared order is truthful, which matters
# because nothing in the format verifies it. `label` is the string column the
# membership tests use; its values are dense and predictable so a test can name
# one that is present and one that cannot be.
table = pa.table(
    {
        "key": pa.array(list(range(N)), pa.int64()),
        "label": pa.array([f"item-{i:05d}" for i in range(N)], pa.string()),
        "score": pa.array([(i % 97) / 4.0 for i in range(N)], pa.float64()),
    }
)

pq.write_table(
    table,
    OUT,
    version="2.6",
    compression="snappy",
    row_group_size=1000,
    data_page_size=4096,
    write_page_index=True,
    write_statistics=True,
    bloom_filter_options={"key": {"ndv": N}, "label": {"ndv": N}},
    sorting_columns=[
        pq.SortingColumn(column_index=0, descending=False, nulls_first=False)
    ],
)

# Fail loudly rather than commit a fixture that silently lacks what it exists
# for.
meta = pq.ParquetFile(OUT).metadata
row_group = meta.row_group(0)
missing = []
if meta.num_row_groups < 2:
    missing.append("more than one row group")
if not any(
    row_group.column(c).has_offset_index for c in range(meta.num_columns)
):
    missing.append("a page index")
if not any(
    row_group.column(c).bloom_filter_offset for c in range(meta.num_columns)
):
    missing.append("a bloom filter")
if row_group.sorting_columns is None or len(row_group.sorting_columns) == 0:
    missing.append("a declared sort order")
if missing:
    sys.exit("pyarrow did not write " + ", ".join(missing))

print(
    f"{OUT}: {meta.num_rows} rows, {meta.num_row_groups} row groups, "
    f"page index + bloom filters + sorting columns present"
)
