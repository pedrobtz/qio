#!/usr/bin/env python3
"""Fill the gaps the phase 7 fixture audit found.

The audit compared what the corpus contains against what qio claims to
support, and turned up four things qio handles but had no third-party file
for. Each is covered by its own fixture rather than one combined file, so a
failure names the feature:

  delta_encodings.parquet  DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY,
                           DELTA_BYTE_ARRAY, and BYTE_STREAM_SPLIT. qio's own
                           writer emits BYTE_STREAM_SPLIT for compressed
                           floats, so a fault there was only ever checked
                           against qio's own output; the delta encodings were
                           decoded but never read from another writer's file.
  codec_mix.parquet        zstd, gzip, and lz4 in one file, one codec per
                           column. Every codec but Snappy was previously
                           exercised only by round-tripping qio's own writes,
                           which cannot distinguish a reader fault from a
                           matching writer fault. This is what caught nothing
                           and what would have caught the Windows zstd race
                           sooner.
  date_types.parquet       DATE, which qio maps to R's Date and had no
                           third-party fixture at all.
  converter_gaps.parquet   Integer-backed DECIMAL and a non-UTC nanosecond
                           TIMESTAMP. Both were found by logging which read-plan
                           converters the test suite actually reaches: every
                           other converter was exercised, these two were not.
  text_annotations.parquet JSON alongside STRING. qio reads STRING, ENUM, and
                           JSON as character; ENUM has no fixture because no
                           available writer emits it -- pyarrow maps a
                           dictionary to a dictionary-encoded STRING, not to
                           the ENUM annotation. That gap is recorded in
                           SOURCE.md rather than papered over.

Requires pyarrow. Not run during the build or the test suite; the generated
files are committed under tests/testthat/parquet/ with provenance in the
adjacent SOURCE.md.

Usage:
    python3 tools/generate-coverage-fixtures.py [output-directory]
"""

import datetime
import sys
from decimal import Decimal

import pyarrow as pa
import pyarrow.parquet as pq

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
N = 300


def path(name):
    return f"{OUT.rstrip('/')}/{name}"


def report(name, expect):
    meta = pq.ParquetFile(path(name)).metadata
    seen = set()
    for rg in range(meta.num_row_groups):
        for col in range(meta.num_columns):
            seen.update(str(e) for e in meta.row_group(rg).column(col).encodings)
            seen.add(str(meta.row_group(rg).column(col).compression))
    missing = [e for e in expect if e not in seen]
    if missing:
        sys.exit(f"{name}: expected {missing}, got {sorted(seen)}")
    print(f"{name}: {meta.num_rows} rows, {sorted(seen)}")


# --- delta and byte-stream-split encodings -----------------------------------
delta = pa.table(
    {
        "i32": pa.array(list(range(N)), pa.int32()),
        "i64": pa.array([i * 1_000_003 for i in range(N)], pa.int64()),
        "text": pa.array([f"row-{i:04d}" for i in range(N)], pa.string()),
        "varying": pa.array(["x" * (i % 37 + 1) for i in range(N)], pa.string()),
        "dbl": pa.array([i / 7.0 for i in range(N)], pa.float64()),
        "flt": pa.array([i / 3.0 for i in range(N)], pa.float32()),
    }
)
pq.write_table(
    delta,
    path("delta_encodings.parquet"),
    version="2.6",
    compression="snappy",
    use_dictionary=False,
    column_encoding={
        "i32": "DELTA_BINARY_PACKED",
        "i64": "DELTA_BINARY_PACKED",
        "text": "DELTA_LENGTH_BYTE_ARRAY",
        "varying": "DELTA_BYTE_ARRAY",
    },
    use_byte_stream_split=["dbl", "flt"],
)
report(
    "delta_encodings.parquet",
    [
        "DELTA_BINARY_PACKED",
        "DELTA_LENGTH_BYTE_ARRAY",
        "DELTA_BYTE_ARRAY",
        "BYTE_STREAM_SPLIT",
    ],
)

# --- one codec per column ----------------------------------------------------
codecs = pa.table(
    {
        "zstd_col": pa.array([f"zstd-{i:04d}" for i in range(N)], pa.string()),
        "gzip_col": pa.array(list(range(N)), pa.int64()),
        "lz4_col": pa.array([i / 11.0 for i in range(N)], pa.float64()),
        "snappy_col": pa.array([i % 2 == 0 for i in range(N)], pa.bool_()),
    }
)
pq.write_table(
    codecs,
    path("codec_mix.parquet"),
    version="2.6",
    compression={
        "zstd_col": "zstd",
        "gzip_col": "gzip",
        "lz4_col": "lz4",
        "snappy_col": "snappy",
    },
)
report("codec_mix.parquet", ["ZSTD", "GZIP", "LZ4", "SNAPPY"])

# --- DATE --------------------------------------------------------------------
epoch = datetime.date(1970, 1, 1)
dates = [
    datetime.date(1970, 1, 1),
    datetime.date(2020, 2, 29),
    datetime.date(1969, 12, 31),
    datetime.date(2262, 4, 11),
    None,
]
date_table = pa.table(
    {
        "day": pa.array(dates, pa.date32()),
        "offset": pa.array(
            [None if d is None else (d - epoch).days for d in dates], pa.int32()
        ),
    }
)
pq.write_table(
    date_table, path("date_types.parquet"), version="2.6", compression="snappy"
)
report("date_types.parquet", ["SNAPPY"])

# --- JSON --------------------------------------------------------------------
# A BYTE_ARRAY annotation that qio reads as character, alongside STRING.
text = pa.table(
    {
        "plain": pa.array(["alpha", "beta", None, "delta"], pa.string()),
        "as_json": pa.array(
            ['{"a":1}', '{"b":[2,3]}', None, "[]"], pa.json_(pa.string())
        ),
    }
)
pq.write_table(
    text, path("text_annotations.parquet"), version="2.6", compression="snappy"
)
report("text_annotations.parquet", ["SNAPPY"])

# --- converters no test reached ----------------------------------------------
# `decimal_int_*` applies to DECIMAL stored as INT32 or INT64, which pyarrow
# writes only with store_decimal_as_integer. `timestamp_local_nanos_*` applies
# to a nanosecond TIMESTAMP with no UTC adjustment. Both were implemented and
# neither was reachable from any committed fixture.
gaps = pa.table(
    {
        "dec32": pa.array(
            [Decimal("12.30"), Decimal("-4.50"), None], pa.decimal128(7, 2)
        ),
        "dec64": pa.array(
            [Decimal("123456789012.30"), Decimal("-1.00"), None],
            pa.decimal128(17, 2),
        ),
        "local_nanos": pa.array(
            [
                datetime.datetime(2020, 1, 1, 0, 0, 1, 500000),
                datetime.datetime(1999, 12, 31, 23, 59, 59),
                None,
            ],
            pa.timestamp("ns"),
        ),
    }
)
pq.write_table(
    gaps,
    path("converter_gaps.parquet"),
    version="2.6",
    compression="snappy",
    store_decimal_as_integer=True,
)
gap_meta = pq.ParquetFile(path("converter_gaps.parquet")).metadata.schema
storage = {gap_meta.column(i).name: gap_meta.column(i).physical_type for i in range(3)}
if storage["dec32"] != "INT32" or storage["dec64"] != "INT64":
    sys.exit(f"decimals were not stored as integers: {storage}")
report("converter_gaps.parquet", ["SNAPPY"])

print("\nall coverage fixtures written")
