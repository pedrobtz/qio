#!/usr/bin/env python3
"""Generate a Parquet fixture whose BOOLEAN columns use the RLE data encoding.

Apache Arrow's writer selects Encoding::RLE for BOOLEAN exactly when the data
page version is V2, which is how the Apache reference file
`datapage_v2.snappy.parquet` came to hold one. That file has a single 5-value
page, so it exercises one run and nothing else. This fixture is shaped to reach
the parts of the hybrid decoder that file never touches:

  runs      long repeated stretches, i.e. RLE runs with large counts
  packed    an alternating pattern, i.e. bit-packed runs
  nullable  nulls, so the dense value count is below the page's value count
  allsame   one run spanning every page

`data_page_size` is small enough that each column spans several pages, so the
decoder is re-initialised per page rather than once per column.

Requires pyarrow (any recent version). Not run during the build or the test
suite; the generated file is committed under tests/testthat/parquet/ with its
provenance recorded in the adjacent SOURCE.md.

Usage:
    python3 tools/generate-rle-boolean-fixture.py [output.parquet]
"""

import sys

import pyarrow as pa
import pyarrow.parquet as pq

# RLE booleans compress hard, so the row count has to be well above the page
# size target before a column spans more than one page at all.
N = 30000
OUT = sys.argv[1] if len(sys.argv) > 1 else "rle_boolean.parquet"


def runs():
    """Long repeated stretches of varying length."""
    out = []
    value = True
    length = 1
    while len(out) < N:
        out.extend([value] * length)
        value = not value
        length = length * 2 if length < 512 else 1
    return out[:N]


def packed():
    """No repeats worth a run, so the encoder emits bit-packed groups."""
    return [(i * 7 + 3) % 5 == 0 for i in range(N)]


def nullable():
    """Nulls make the dense value count differ from the page value count."""
    out = []
    for i in range(N):
        out.append(None if i % 7 == 3 else (i % 3 == 0))
    return out


table = pa.table(
    {
        "runs": pa.array(runs(), pa.bool_()),
        "packed": pa.array(packed(), pa.bool_()),
        "nullable": pa.array(nullable(), pa.bool_()),
        "allsame": pa.array([True] * N, pa.bool_()),
    }
)

pq.write_table(
    table,
    OUT,
    version="2.6",
    data_page_version="2.0",
    compression="snappy",
    data_page_size=1024,
    use_dictionary=False,
)

# Fail loudly if this pyarrow did not actually choose RLE: a fixture that
# silently fell back to PLAIN would make the test that reads it vacuous.
meta = pq.ParquetFile(OUT).metadata
seen = set()
for rg in range(meta.num_row_groups):
    for col in range(meta.num_columns):
        seen.update(str(e) for e in meta.row_group(rg).column(col).encodings)
if "RLE" not in seen:
    sys.exit(f"pyarrow did not use RLE for BOOLEAN; encodings were {sorted(seen)}")

# Likewise fail if every column still fits in one page, which would leave the
# per-page reinitialisation of the decoder untested.
rg = meta.row_group(0)
spans = [
    rg.column(c).total_uncompressed_size > 1024 for c in range(meta.num_columns)
]
if not any(spans):
    sys.exit("no column exceeds the page size target; raise N")

print(f"{OUT}: {meta.num_rows} rows, {meta.num_row_groups} row group(s), "
      f"encodings {sorted(seen)}, multi-page columns "
      f"{sum(spans)}/{meta.num_columns}")
