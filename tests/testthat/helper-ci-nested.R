# Canonical forms of nested columns for test-ci-nested-oracle.R, which compares
# qio with Apache Arrow's R package. Like that file, this one is left out of
# the tarball, so arrow never reaches R CMD check.
#
# Both readers' values are turned into one plain shape, row by row: a struct
# row is NULL or a named list of its fields, a LIST row NULL or the vector of
# its elements, a MAP row NULL or list(key, value), a scalar a length-one
# vector. Numbers become double and times their seconds, so the comparison is
# of values, not of the R classes each package picks.

canon_atomic <- function(x) {
  if (inherits(x, "integer64")) {
    return(as.double(as.character(x)))
  }
  if (inherits(x, c("POSIXct", "Date", "difftime", "hms"))) {
    return(as.double(unclass(x)))
  }
  if (is.numeric(x)) {
    return(as.double(x))
  }
  if (is.list(x)) {
    # Binary values: a raw vector, or NULL for a null value.
    stopifnot(all(vapply(x, function(v) is.null(v) || is.raw(v), logical(1))))
    return(lapply(x, function(v) if (is.null(v)) NULL else as.raw(v)))
  }
  attributes(x) <- NULL
  x
}

canon_rows <- function(x) {
  x <- canon_atomic(x)
  if (is.list(x)) x else as.list(x)
}

# qio's values.
canon_qio <- function(column) {
  if (is.data.frame(column)) {
    null <- is_null_struct(column)
    fields <- lapply(as.list(column), canon_qio)
    return(lapply(seq_len(nrow(column)), function(i) {
      if (null[[i]]) NULL else lapply(fields, `[[`, i)
    }))
  }
  if (
    is.list(column) &&
      !all(vapply(column, function(v) is.null(v) || is.raw(v), logical(1)))
  ) {
    return(lapply(column, function(v) {
      if (is.null(v)) {
        NULL
      } else if (is.data.frame(v)) {
        list(key = canon_atomic(v$key), value = canon_atomic(v$value))
      } else {
        canon_atomic(v)
      }
    }))
  }
  canon_rows(column)
}

# Arrow's values, from the Array itself so that struct validity is its own.
# `like` is qio's column: a struct keeps only the fields qio returned, since
# qio leaves out the ones it cannot read.
canon_arrow <- function(array, like = NULL) {
  type <- array$type
  if (inherits(type, "StructType")) {
    null <- as.vector(arrow::call_function("is_null", array))
    names <- vapply(type$fields(), function(f) f$name, character(1))
    keep <- if (is.data.frame(like)) {
      match(names(like), names)
    } else {
      seq_along(names)
    }
    fields <- lapply(keep, function(i) {
      canon_arrow(array$field(i - 1L), like[[names[[i]]]])
    })
    names(fields) <- names[keep]
    return(lapply(seq_len(array$length()), function(i) {
      if (null[[i]]) NULL else lapply(fields, `[[`, i)
    }))
  }
  if (inherits(type, "MapType")) {
    values <- as.vector(array)
    return(lapply(values, function(v) {
      if (is.null(v)) {
        NULL
      } else {
        list(key = canon_atomic(v$key), value = canon_atomic(v$value))
      }
    }))
  }
  if (inherits(type, c("ListType", "LargeListType"))) {
    values <- as.vector(array)
    return(lapply(values, function(v) {
      if (is.null(v)) NULL else canon_atomic(v)
    }))
  }
  canon_rows(as.vector(array))
}

# The columns of `result` (qio's read of the file), as Arrow reads them. Columns qio skips are
# left out: Arrow converts some of them (a list of lists) in ways this
# canonical form does not cover.
canon_arrow_table <- function(path, result) {
  table <- arrow::read_parquet(path, as_data_frame = FALSE)
  out <- lapply(names(result), function(name) {
    chunked <- table[[name]]
    unlist(
      lapply(chunked$chunks, canon_arrow, like = result[[name]]),
      recursive = FALSE
    )
  })
  names(out) <- names(result)
  out
}

# The fixtures test-ci-nested-oracle.R compares with Arrow.
nested_oracle_files <- function() {
  c(
    file.path("parquet", nested_shapes_variants),
    file.path(
      "parquet",
      c(
        "nested_edge.parquet",
        "nested_empty.parquet",
        "nested_long.parquet",
        "nested_unsupported.parquet",
        "nested_mixed.parquet",
        "nested_maps.snappy.parquet",
        "nullable.impala.parquet",
        "name_collision.parquet",
        "duplicate_paths.parquet"
      )
    ),
    file.path("parquet", "delta", list.files(test_path("parquet", "delta")))
  )
}
