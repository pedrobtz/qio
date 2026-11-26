#!/usr/bin/env python3
"""Nested fixtures for qio's struct, MAP and LIST reading (#73).

nested_shapes.parquet holds every shape qio 0.2.0 reads, with a null at each
level a shape has: a null struct beside a struct of nulls, a null list beside
an empty one and a null element, a null map beside an empty one and a null
value, and maps and lists under a struct, as Delta checkpoints have them. One
row holds a 100-element list so that a small data page cannot hold it whole.

The same table is then written five more ways, which must all read back as the
same R value (the differential pair of the correctness rules): no dictionary
and no compression, small DATA_PAGE_V1 pages with lists spanning pages, small
DATA_PAGE_V2 pages, three row groups, and DELTA encodings.

nested_unsupported.parquet holds the shapes qio refuses (a list of structs and
a list of lists) next to columns it reads, so that skipping them is seen not
to disturb the rest.

The expected values are written out by hand in test-nested.R from the data
below; qio is never used to produce them.

Usage (pyarrow is not a qio dependency):
    uv run --no-project --with pyarrow==25.0.0 \\
        python -I tools/generate-nested-fixtures.py tests/testthat/parquet
"""

import datetime
import sys

import pyarrow as pa
import pyarrow.parquet as pq

OUT = sys.argv[1] if len(sys.argv) > 1 else "."


def path(name):
    return f"{OUT.rstrip('/')}/{name}"


UTC = datetime.timezone.utc
T0 = datetime.datetime(2020, 1, 1, 0, 0, 0, tzinfo=UTC)
T1 = datetime.datetime(2021, 6, 15, 12, 30, 45, 123456, tzinfo=UTC)

inner_type = pa.struct([pa.field("x", pa.float64())])
s_type = pa.struct(
    [
        pa.field("a", pa.int32()),
        pa.field("b", pa.string()),
        pa.field("inner", inner_type),
        pa.field("k", pa.int64(), nullable=False),
    ]
)
rs_type = pa.struct([pa.field("y", pa.int64())])
sm_type = pa.struct(
    [
        pa.field("pv", pa.map_(pa.string(), pa.string())),
        pa.field("tags", pa.list_(pa.string())),
    ]
)

schema = pa.schema(
    [
        pa.field("id", pa.int32(), nullable=False),
        pa.field("s", s_type),
        pa.field("rs", rs_type, nullable=False),
        pa.field("l", pa.list_(pa.int32())),
        pa.field(
            "lr",
            pa.list_(pa.field("element", pa.string(), nullable=False)),
            nullable=False,
        ),
        pa.field("m", pa.map_(pa.string(), pa.int32())),
        pa.field("sm", sm_type),
        pa.field("ts", pa.list_(pa.timestamp("us", tz="UTC"))),
        pa.field("d", pa.list_(pa.date32())),
        pa.field("bin", pa.list_(pa.binary())),
        pa.field("tail", pa.string()),
    ]
)

data = {
    "id": [1, 2, 3, 4, 5, 6, 7, 8],
    "s": [
        {"a": 1, "b": "one", "inner": {"x": 1.5}, "k": 10},
        None,
        {"a": None, "b": None, "inner": None, "k": 30},
        {"a": 4, "b": "", "inner": {"x": None}, "k": 40},
        {"a": None, "b": None, "inner": {"x": None}, "k": 50},
        {"a": -2147483647, "b": "ñ", "inner": {"x": -0.25}, "k": 60},
        None,
        {"a": 8, "b": "eight", "inner": {"x": 8.0}, "k": 80},
    ],
    "rs": [
        {"y": 1},
        {"y": None},
        {"y": 3},
        {"y": 4},
        {"y": None},
        {"y": 6},
        {"y": 7},
        {"y": 8},
    ],
    "l": [
        [1, 2, 3],
        None,
        [],
        [None],
        [4, None, 5],
        None,
        [6],
        list(range(100)),
    ],
    "lr": [["a"], [], ["b", "c"], [], ["d"], ["e", "f", "g"], [], ["h"]],
    "m": [
        [("a", 1)],
        None,
        [],
        [("b", None)],
        [("c", 3), ("d", 4)],
        None,
        [("e", 5)],
        [],
    ],
    "sm": [
        {"pv": [("p", "1")], "tags": ["x"]},
        None,
        {"pv": [], "tags": None},
        {"pv": None, "tags": []},
        {"pv": [("q", None)], "tags": [None]},
        None,
        {"pv": [("r", "s"), ("t", "u")], "tags": ["y", "z"]},
        {"pv": None, "tags": None},
    ],
    "ts": [[T0], [], None, [T1, None], [T0, T1], None, [], [T1]],
    "d": [
        [datetime.date(2020, 1, 1)],
        None,
        [],
        [None, datetime.date(1969, 12, 31)],
        [],
        [datetime.date(2038, 1, 19)],
        None,
        [datetime.date(1970, 1, 1)],
    ],
    "bin": [[b"\x00\x01"], [b""], None, [None], [], [b"\xff", b"ab"], None, []],
    "tail": ["t1", None, "t3", "t4", "t5", "t6", None, "t8"],
}

table = pa.table(data, schema=schema)

variants = {
    "nested_shapes.parquet": dict(),
    "nested_shapes-plain.parquet": dict(use_dictionary=False, compression="none"),
    "nested_shapes-pages-v1.parquet": dict(
        data_page_size=64,
        write_batch_size=2,
        dictionary_pagesize_limit=64,
        data_page_version="1.0",
    ),
    "nested_shapes-pages-v2.parquet": dict(
        data_page_size=64,
        write_batch_size=2,
        dictionary_pagesize_limit=64,
        data_page_version="2.0",
    ),
    "nested_shapes-row-groups.parquet": dict(row_group_size=3),
    "nested_shapes-delta.parquet": dict(
        use_dictionary=False,
        column_encoding={
            "id": "DELTA_BINARY_PACKED",
            "s.a": "DELTA_BINARY_PACKED",
            "s.b": "DELTA_LENGTH_BYTE_ARRAY",
            "s.k": "DELTA_BINARY_PACKED",
            "rs.y": "DELTA_BINARY_PACKED",
            "l.list.element": "DELTA_BINARY_PACKED",
            "lr.list.element": "DELTA_BYTE_ARRAY",
            "m.key_value.key": "DELTA_BYTE_ARRAY",
            "m.key_value.value": "DELTA_BINARY_PACKED",
            "s.inner.x": "BYTE_STREAM_SPLIT",
        },
    ),
}

for name, options in variants.items():
    pq.write_table(table, path(name), **options)
    meta = pq.ParquetFile(path(name)).metadata
    pages = 0
    for g in range(meta.num_row_groups):
        for c in range(meta.num_columns):
            col = meta.row_group(g).column(c)
            pages += 1 if col.dictionary_page_offset is None else 2
    print(name, meta.num_row_groups, "row groups")
    # Read back with pyarrow: every variant is the same table.
    assert pq.read_table(path(name)).equals(table), name

unsupported = pa.table(
    {
        "id": pa.array([1, 2, 3], pa.int32()),
        "ls": pa.array(
            [[{"a": 1}], None, [{"a": None}, None]],
            pa.list_(pa.struct([pa.field("a", pa.int32())])),
        ),
        "s": pa.array(
            [{"v": 1.5}, None, {"v": None}], pa.struct([pa.field("v", pa.float64())])
        ),
        "ll": pa.array([[[1], []], None, [None]], pa.list_(pa.list_(pa.int32()))),
        "tail": pa.array(["x", None, "z"], pa.string()),
    }
)
pq.write_table(unsupported, path("nested_unsupported.parquet"))
print("nested_unsupported.parquet written with pyarrow", pa.__version__)

# Edges: values the converters change inside nested shapes (an INT64 past
# 2^53 and an INT32 sentinel, which must warn naming the nested leaf), and a
# zero-row file, whose nested columns must still have their R types.
edge = pa.table(
    {
        "s": pa.array(
            [{"v": 2**53 + 1}, None, {"v": 1}], pa.struct([pa.field("v", pa.int64())])
        ),
        "li": pa.array([[-(2**31), 1], [], None], pa.list_(pa.int32())),
    }
)
pq.write_table(edge, path("nested_edge.parquet"))
pq.write_table(table.slice(0, 0), path("nested_empty.parquet"))

# Straddle qio's 65,536-entry read chunk: row 1 ends one entry before it, row 2
# is the entry at it, row 3 crosses it, then an empty and a null list.
pattern = [i % 7 for i in range(65535)]
long = pa.table(
    {
        "id": pa.array([1, 2, 3, 4, 5], pa.int32()),
        "l": pa.array([pattern, [7], [8, 9], [], None], pa.list_(pa.int32())),
    }
)
pq.write_table(long, path("nested_long.parquet"))

# Two leaves at one path (#44): Arrow writes duplicate top-level names.
dup = pa.Table.from_arrays(
    [
        pa.array([datetime.date(2020, 1, 1), None], pa.date32()),
        pa.array([1, None], pa.int32()),
        pa.array([T0, None], pa.timestamp("us", tz="UTC")),
        pa.array([1.5, None], pa.float64()),
        pa.array(["a", None], pa.string()),
    ],
    names=["x", "x", "y", "y", "y"],
)
pq.write_table(dup, path("duplicate_paths.parquet"))
print("edge, empty, long and duplicate_paths written")
