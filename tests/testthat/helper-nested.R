# The R value of nested_shapes.parquet, written out from the data in
# tools/generate-nested-fixtures.py and the shapes in .agents/TYPES.md
# ("Nested values"), never from a qio read.

nested_frame <- function(columns, rows) {
  structure(
    columns,
    row.names = .set_row_names(rows),
    class = "data.frame"
  )
}

nested_struct <- function(columns, null) {
  out <- nested_frame(columns, length(null))
  attr(out, "null") <- null
  class(out) <- c("qio_struct", "data.frame")
  out
}

nested_map <- function(key, value) {
  nested_frame(list(key = key, value = value), length(key))
}

utc_micros <- function(x) {
  structure(as.double(x) / 1e6, class = c("POSIXct", "POSIXt"), tzone = "UTC")
}

days <- function(x) structure(as.double(x), class = "Date")

expected_nested_shapes <- function() {
  t0 <- 1577836800000000 # 2020-01-01 00:00:00 UTC, microseconds
  t1 <- 1623760245123456 # 2021-06-15 12:30:45.123456 UTC
  nested_frame(
    list(
      id = 1:8,
      s = nested_struct(
        list(
          a = c(1L, NA, NA, 4L, NA, -2147483647L, NA, 8L),
          b = c("one", NA, NA, "", NA, "ñ", NA, "eight"),
          inner = nested_struct(
            list(x = c(1.5, NA, NA, NA, NA, -0.25, NA, 8)),
            null = c(FALSE, TRUE, TRUE, FALSE, FALSE, FALSE, TRUE, FALSE)
          ),
          k = c(10, NA, 30, 40, 50, 60, NA, 80)
        ),
        null = c(FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE)
      ),
      rs = nested_frame(list(y = c(1, NA, 3, 4, NA, 6, 7, 8)), 8L),
      l = list(
        1:3,
        NULL,
        integer(0),
        NA_integer_,
        c(4L, NA, 5L),
        NULL,
        6L,
        0:99
      ),
      lr = list(
        "a",
        character(0),
        c("b", "c"),
        character(0),
        "d",
        c("e", "f", "g"),
        character(0),
        "h"
      ),
      m = list(
        nested_map("a", 1L),
        NULL,
        nested_map(character(0), integer(0)),
        nested_map("b", NA_integer_),
        nested_map(c("c", "d"), 3:4),
        NULL,
        nested_map("e", 5L),
        nested_map(character(0), integer(0))
      ),
      sm = nested_struct(
        list(
          pv = list(
            nested_map("p", "1"),
            NULL,
            nested_map(character(0), character(0)),
            NULL,
            nested_map("q", NA_character_),
            NULL,
            nested_map(c("r", "t"), c("s", "u")),
            NULL
          ),
          tags = list(
            "x",
            NULL,
            NULL,
            character(0),
            NA_character_,
            NULL,
            c("y", "z"),
            NULL
          )
        ),
        null = c(FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE)
      ),
      ts = list(
        utc_micros(t0),
        utc_micros(numeric(0)),
        NULL,
        utc_micros(c(t1, NA)),
        utc_micros(c(t0, t1)),
        NULL,
        utc_micros(numeric(0)),
        utc_micros(t1)
      ),
      d = list(
        days(18262),
        NULL,
        days(numeric(0)),
        days(c(NA, -1)),
        days(numeric(0)),
        days(24855),
        NULL,
        days(0)
      ),
      bin = list(
        list(as.raw(c(0x00, 0x01))),
        list(raw(0)),
        NULL,
        list(NULL),
        list(),
        list(as.raw(0xff), charToRaw("ab")),
        NULL,
        list()
      ),
      tail = c("t1", NA, "t3", "t4", "t5", "t6", NA, "t8")
    ),
    8L
  )
}

nested_shapes_variants <- c(
  "nested_shapes.parquet",
  "nested_shapes-plain.parquet",
  "nested_shapes-pages-v1.parquet",
  "nested_shapes-pages-v2.parquet",
  "nested_shapes-row-groups.parquet",
  "nested_shapes-delta.parquet"
)

# Rows `i` of a nested frame, with row names reset at every level, as a read
# returns them.
nested_rows <- function(x, i) {
  reset <- function(x) {
    if (!is.data.frame(x)) {
      return(x)
    }
    attr(x, "row.names") <- .set_row_names(nrow(x))
    for (j in seq_along(x)) {
      x[[j]] <- reset(x[[j]])
    }
    x
  }
  reset(x[i, , drop = FALSE])
}
