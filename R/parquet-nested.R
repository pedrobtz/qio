# Nested columns: structs, MAP and LIST of repetition level 1 (#73).
#
# The native layer only decodes. qio_parquet_schema_nodes() returns the schema
# tree and qio_parquet_read_leaf() one leaf's present values with its
# definition and repetition levels; everything below turns those into R values.
# The contract (shapes, null semantics, projection, what is refused) is
# .agents/TYPES.md, "Nested values".

qio_schema_nodes <- function(x) {
  .Call(C_qio_parquet_schema_nodes, x)
}

# The shape of every leaf, from the schema tree. One row per leaf, in leaf
# order, with:
#   top       element index of the leaf's top-level ancestor (itself if flat)
#   shape     "flat", "struct", "list" or "map"; NA when unsupported
#   reason    why an unsupported leaf cannot be read
#   group     path of the group that makes it unsupported, or of its LIST/MAP
#   container element index of its LIST or MAP group, NA otherwise
# `nodes` is what qio_schema_nodes() returns. Also returns, for each element,
# its complete path and cumulative definition level, which assembly needs.
qio_nested_layout <- function(nodes) {
  n <- nrow(nodes)
  parent <- nodes$parent
  leaf_of <- nodes$leaf
  is_leaf <- !is.na(leaf_of)
  repetition <- nodes$repetition_type
  logical <- nodes$logical_type

  path <- character(n)
  def <- integer(n)
  for (i in seq_len(n)) {
    p <- parent[[i]]
    up_path <- if (is.na(p) || p == 0L) "" else paste0(path[[p]], ".")
    up_def <- if (is.na(p) || p == 0L) 0L else def[[p]]
    path[[i]] <- paste0(up_path, nodes$name[[i]])
    def[[i]] <- up_def + as.integer(repetition[[i]] != "REQUIRED")
  }
  children <- split(seq_len(n), factor(parent, levels = 0:n))
  child_of <- function(i) children[[as.character(i)]]

  leaves <- which(is_leaf)
  leaves <- leaves[order(leaf_of[leaves])]
  out <- data.frame(
    element = leaves,
    top = NA_integer_,
    shape = NA_character_,
    reason = NA_character_,
    group = NA_character_,
    container = NA_integer_,
    stringsAsFactors = FALSE
  )
  for (k in seq_along(leaves)) {
    chain <- leaves[[k]]
    while (parent[[chain[[1L]]]] != 0L) {
      chain <- c(parent[[chain[[1L]]]], chain)
    }
    out$top[[k]] <- chain[[1L]]
    verdict <- qio_classify_chain(
      chain,
      is_leaf,
      repetition,
      logical,
      child_of,
      nodes$name
    )
    out$shape[[k]] <- verdict$shape
    out$reason[[k]] <- verdict$reason
    out$group[[k]] <- if (is.na(verdict$group)) {
      NA_character_
    } else {
      path[[verdict$group]]
    }
    out$container[[k]] <- verdict$container
  }
  list(
    leaves = out,
    path = path,
    def = def,
    children = children,
    parent_of = parent,
    names = nodes$name,
    repetition = repetition
  )
}

# Walk a leaf's chain from its top-level ancestor and decide its shape. The
# first group that is neither a plain struct nor a supported LIST or MAP makes
# the leaf unsupported, and is named. A LIST is recognised by its annotation
# and its three-level structure, never by the names "list" and "element".
qio_classify_chain <- function(
  chain,
  is_leaf,
  repetition,
  logical,
  child_of,
  name
) {
  refuse <- function(reason, at) {
    list(
      shape = NA_character_,
      reason = reason,
      group = at,
      container = NA_integer_
    )
  }
  m <- length(chain)
  if (m == 1L) {
    if (repetition[[chain]] == "REPEATED") {
      return(refuse("repeated field", chain))
    }
    return(list(
      shape = "flat",
      reason = NA_character_,
      group = NA_integer_,
      container = NA_integer_
    ))
  }
  for (i in seq_len(m)) {
    node <- chain[[i]]
    if (is_leaf[[node]]) {
      if (repetition[[node]] == "REPEATED") {
        return(refuse("repeated field", node))
      }
      return(list(
        shape = "struct",
        reason = NA_character_,
        group = NA_integer_,
        container = NA_integer_
      ))
    }
    annotation <- logical[[node]]
    if (identical(annotation, "VARIANT")) {
      return(refuse("VARIANT", node))
    }
    if (repetition[[node]] == "REPEATED") {
      return(refuse("repeated field", node))
    }
    if (identical(annotation, "LIST")) {
      kids <- child_of(node)
      if (length(kids) != 1L || repetition[[kids]] != "REPEATED") {
        return(refuse("legacy list", node))
      }
      repeated <- kids
      if (is_leaf[[repeated]]) {
        return(refuse("legacy list", node))
      }
      element <- child_of(repeated)
      # The Parquet backward-compatibility rules: a repeated group with more
      # than one field, or named "array" or "<list>_tuple", is the element
      # itself -- a struct -- not a wrapper around it.
      legacy_name <- name[[repeated]] == "array" ||
        name[[repeated]] == paste0(name[[node]], "_tuple")
      if (length(element) != 1L || legacy_name) {
        return(refuse("legacy list", node))
      }
      if (!is_leaf[[element]]) {
        reason <- switch(
          qio_or(logical[[element]], "STRUCT"),
          LIST = "nested list",
          MAP = "list of maps",
          "list of structs"
        )
        return(refuse(reason, node))
      }
      if (repetition[[element]] == "REPEATED") {
        return(refuse("legacy list", node))
      }
      return(list(
        shape = "list",
        reason = NA_character_,
        group = node,
        container = node
      ))
    }
    if (identical(annotation, "MAP")) {
      kids <- child_of(node)
      if (
        length(kids) != 1L ||
          repetition[[kids]] != "REPEATED" ||
          is_leaf[[kids]]
      ) {
        return(refuse("legacy map", node))
      }
      entry <- child_of(kids)
      if (length(entry) != 2L) {
        return(refuse("legacy map", node))
      }
      if (!all(is_leaf[entry])) {
        return(refuse("map with group keys or values", node))
      }
      if (any(repetition[entry] == "REPEATED")) {
        return(refuse("legacy map", node))
      }
      return(list(
        shape = "map",
        reason = NA_character_,
        group = node,
        container = node
      ))
    }
  }
  refuse("unrecognised shape", chain[[m]])
}

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

# Resolve `columns` into what a read returns: a list of output items, in order
# of first mention (schema order for NULL), each either one flat leaf or one
# top-level nested column with the leaves selected under it, in schema order.
# Unsupported leaves an ancestor or NULL selects are dropped and reported once
# with `qio_message_nested_skipped`; a selector at or inside an unsupported
# shape, or inside a LIST or MAP, is an error. `nested = FALSE` (walk_batches)
# drops every nested leaf with the same message class instead.
qio_select <- function(plan, columns, layout, nested = TRUE) {
  leaves <- seq_len(nrow(plan))
  is_flat <- !plan$nested
  if (is.null(layout)) {
    info <- NULL
    top <- leaves
  } else {
    info <- layout$leaves
    top <- info$top
  }

  if (is.null(columns)) {
    wanted <- leaves
  } else {
    known <- plan$path
    if (!is.null(layout)) {
      known <- c(known, layout$path)
    }
    unknown <- setdiff(columns, known)
    if (length(unknown)) {
      stop(
        "Unknown Parquet column",
        if (length(unknown) == 1L) "" else "s",
        ": ",
        paste0("`", unknown, "`", collapse = ", "),
        ".",
        call. = FALSE
      )
    }
    wanted <- integer(0)
    for (selector in columns) {
      wanted <- c(wanted, qio_resolve_selector(plan, layout, selector))
    }
    wanted <- unique(wanted)
  }

  skip <- !plan$collectible[wanted] & plan$nested[wanted]
  if (!nested) {
    skip <- plan$nested[wanted]
  }
  skipped <- wanted[skip]
  if (length(skipped)) {
    qio_message_nested_skipped(plan, layout, skipped, walk = !nested)
  }
  wanted <- wanted[!skip]

  # Group into output items by top-level element, in order of first mention.
  keys <- if (is.null(info)) wanted else top[wanted]
  first <- unique(keys)
  items <- lapply(first, function(key) {
    members <- sort(wanted[keys == key])
    if (length(members) == 1L && is_flat[[members]]) {
      list(flat = TRUE, leaves = members, name = plan$path[[members]])
    } else {
      list(
        flat = FALSE,
        leaves = members,
        top = key,
        name = qio_top_name(plan, layout, members[[1L]])
      )
    }
  })
  items
}

qio_top_name <- function(plan, layout, leaf) {
  if (is.null(layout)) {
    return(plan$path[[leaf]])
  }
  layout$path[[layout$leaves$top[[leaf]]]]
}

# One selector: a complete leaf path or a complete group path. Returns leaf
# indexes, every leaf under a group (supported or not; the caller drops the
# unsupported ones with a message), or stops.
qio_resolve_selector <- function(plan, layout, selector) {
  leaf_match <- which(plan$path == selector)
  group_match <- integer(0)
  if (!is.null(layout)) {
    is_group <- !seq_along(layout$path) %in% layout$leaves$element
    group_match <- which(layout$path == selector & is_group)
  }
  matches <- length(leaf_match) + length(group_match)
  if (matches == 0L) {
    stop("Unknown Parquet column: `", selector, "`.", call. = FALSE)
  }
  # A flat column literally named "a.b" and a nested leaf or group b under a
  # both render as the path "a.b". Refuse to guess which one was meant.
  if (matches > 1L) {
    stop(
      "Ambiguous Parquet column: `",
      selector,
      "`. More than one leaf or group has that path.",
      call. = FALSE
    )
  }
  if (is.null(layout)) {
    return(leaf_match)
  }
  info <- layout$leaves
  if (length(leaf_match)) {
    qio_check_selectable(plan, layout, leaf_match, selector)
    return(leaf_match)
  }
  # Leaves under the group: those whose chain passes through it.
  group <- group_match
  under <- which(vapply(
    info$element,
    function(e) {
      qio_has_ancestor(layout, e, group)
    },
    logical(1)
  ))
  if (!length(under)) {
    stop("Parquet group `", selector, "` holds no columns.", call. = FALSE)
  }
  # Selecting a group inside a LIST or MAP, or at or inside an unsupported
  # shape, is an error; selecting an ancestor of one is not.
  for (leaf in under) {
    container <- info$container[[leaf]]
    if (
      !is.na(container) &&
        container != group &&
        qio_has_ancestor(layout, group, container)
    ) {
      qio_stop_inside_container(layout, container, selector)
    }
    if (is.na(info$shape[[leaf]])) {
      bad <- match(info$group[[leaf]], layout$path)
      if (bad == group || qio_has_ancestor(layout, group, bad)) {
        qio_stop_unsupported(info, leaf, selector)
      }
    }
  }
  under
}

qio_check_selectable <- function(plan, layout, leaf, selector) {
  info <- layout$leaves
  if (is.na(info$shape[[leaf]]) && plan$nested[[leaf]]) {
    qio_stop_unsupported(info, leaf, selector)
  }
  if (!is.na(info$container[[leaf]])) {
    qio_stop_inside_container(layout, info$container[[leaf]], selector)
  }
}

qio_stop_inside_container <- function(layout, container, selector) {
  stop(
    "Parquet column `",
    selector,
    "` is part of the ",
    "LIST or MAP `",
    layout$path[[container]],
    "`; select `",
    layout$path[[container]],
    "` whole.",
    call. = FALSE
  )
}

qio_stop_unsupported <- function(info, leaf, selector) {
  stop(
    "Parquet column `",
    selector,
    "` cannot be read: `",
    info$group[[leaf]],
    "` is a ",
    info$reason[[leaf]],
    ", which qio does not read.",
    call. = FALSE
  )
}

# Whether `ancestor` is a strict ancestor of `element` (both element indexes).
qio_has_ancestor <- function(layout, element, ancestor) {
  at <- layout$parent_of[[element]]
  while (!is.na(at) && at != 0L) {
    if (at == ancestor) {
      return(TRUE)
    }
    at <- layout$parent_of[[at]]
  }
  FALSE
}

# One classed message per read for the leaves a read leaves out. Its `columns`
# field is a data frame with one row per skipped leaf: `path`, the `group`
# that makes it unreadable, and the `reason`. The text names the first five
# groups. See .agents/TYPES.md, "Nested values".
qio_message_nested_skipped <- function(plan, layout, skipped, walk = FALSE) {
  n <- length(skipped)
  if (walk || is.null(layout)) {
    group <- if (is.null(layout)) {
      plan$path[skipped]
    } else {
      layout$path[layout$leaves$top[skipped]]
    }
    reason <- if (walk) "nested" else plan$note[skipped]
  } else {
    group <- layout$leaves$group[skipped]
    reason <- layout$leaves$reason[skipped]
  }
  affected <- data.frame(
    path = plan$path[skipped],
    group = group,
    reason = reason,
    stringsAsFactors = FALSE
  )
  plural <- if (n == 1L) "" else "s"
  if (walk) {
    text <- paste0(
      "Skipping ",
      n,
      " nested Parquet column",
      plural,
      ": walk_batches() reads flat columns only; use collect().\n"
    )
  } else {
    shown <- unique(affected[c("group", "reason")])
    more <- nrow(shown) - 5L
    shown <- utils::head(shown, 5L)
    listed <- paste0(
      "`",
      shown$group,
      "` (",
      shown$reason,
      ")",
      collapse = ", "
    )
    if (more > 0L) {
      listed <- paste0(listed, ", and ", more, " more")
    }
    text <- paste0(
      "Skipping ",
      n,
      " nested Parquet column",
      plural,
      " that qio cannot read: ",
      listed,
      ".\n"
    )
  }
  message(structure(
    class = c("qio_message_nested_skipped", "message", "condition"),
    list(message = text, call = NULL, columns = affected)
  ))
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# Reading and assembly
# ---------------------------------------------------------------------------

# Read one nested output item: every selected leaf under one top-level
# element. Returns the R column. `warnings` collects coercion flags, which the
# caller raises after the whole read so an error is never preceded by a
# warning about a partial result.
qio_read_nested_item <- function(
  x,
  item,
  plan,
  schema,
  layout,
  row_groups,
  int64_code,
  rows,
  flags
) {
  data <- lapply(item$leaves, function(leaf) {
    raw <- .Call(
      C_qio_parquet_read_leaf,
      x,
      as.integer(leaf),
      row_groups,
      qio_column_kinds(plan, leaf),
      int64_code
    )
    if (isTRUE(attr(raw, "int32_sentinel"))) {
      flags$int32 <- c(flags$int32, plan$path[[leaf]])
    }
    if (isTRUE(attr(raw, "int64_coerced"))) {
      flags$int64 <- c(flags$int64, plan$path[[leaf]])
    }
    raw$values <- qio_apply_converter(raw$values, plan$converter[[leaf]])
    raw$max_def <- schema$max_definition_level[[leaf]]
    raw$entries <- if (!is.null(raw$rep)) {
      length(raw$rep)
    } else if (!is.null(raw$def)) {
      length(raw$def)
    } else {
      length(raw$values)
    }
    raw$starts <- if (is.null(raw$rep)) NULL else which(raw$rep == 0L)
    n <- if (is.null(raw$starts)) raw$entries else length(raw$starts)
    if (n != rows) {
      stop(
        "qio: column '",
        plan$path[[leaf]],
        "' has ",
        n,
        " rows; the file's ",
        "row groups have ",
        rows,
        ".",
        call. = FALSE
      )
    }
    present <- if (is.null(raw$def)) {
      raw$entries
    } else {
      sum(raw$def == raw$max_def)
    }
    if (present != length(raw$values)) {
      stop(
        "qio: column '",
        plan$path[[leaf]],
        "' decoded ",
        length(raw$values),
        " values for ",
        present,
        " present entries.",
        call. = FALSE
      )
    }
    raw
  })
  names(data) <- as.character(layout$leaves$element[item$leaves])
  qio_build_node(item$top, data, layout, rows)
}

# The coercion warnings of TYPES.md, once per affected nested leaf, named by
# its complete path.
qio_warn_nested_coercion <- function(flags, options) {
  for (path in flags$int32) {
    warning(
      "Some INT32 values in column '",
      path,
      "' were coerced to NA because ",
      "R's integer type reserves -2147483648 as its missing value.",
      call. = FALSE
    )
  }
  for (path in flags$int64) {
    if (options$int64 == "integer64") {
      warning(
        "Some INT64 or UINT64 values in column '",
        path,
        "' were coerced to ",
        "NA because they cannot be represented by bit64::integer64.",
        call. = FALSE
      )
    } else {
      warning(
        "Some INT64 or UINT64 values in column '",
        path,
        "' were coerced to ",
        "NA because they cannot be represented exactly as R doubles; use ",
        "int64 = \"integer64\" to preserve the supported 64-bit range.",
        call. = FALSE
      )
    }
  }
}

# Definition level per row: a leaf's level at the first entry of each row,
# which says how far down its non-repeated ancestors are defined.
qio_row_def <- function(leaf, rows) {
  if (is.null(leaf$def)) {
    return(rep(0L, rows))
  }
  if (is.null(leaf$starts)) leaf$def else leaf$def[leaf$starts]
}

# Expand a leaf's present values to one slot per entry (or per kept entry):
# the value where the entry's definition level is at its maximum, NA (NULL in
# a list of raw vectors) elsewhere.
qio_expand <- function(values, def, max_def, keep = NULL) {
  if (is.null(def)) {
    return(if (is.null(keep)) values else values[keep])
  }
  present <- def == max_def
  if (is.null(keep) && all(present)) {
    return(values)
  }
  index <- rep(NA_integer_, length(present))
  index[present] <- seq_len(length(values))
  if (!is.null(keep)) {
    index <- index[keep]
  }
  values[index]
}

qio_frame <- function(columns, names, rows) {
  structure(
    columns,
    names = names,
    row.names = .set_row_names(rows),
    class = "data.frame"
  )
}

qio_build_node <- function(node, data, layout, rows) {
  key <- as.character(node)
  if (!is.null(data[[key]])) {
    leaf <- data[[key]]
    return(qio_expand(leaf$values, leaf$def, leaf$max_def))
  }
  info <- layout$leaves
  container <- info$container[match(as.integer(names(data)), info$element)]
  if (node %in% container) {
    shape <- info$shape[match(node, info$container)]
    return(qio_build_container(node, shape, data, layout, rows))
  }

  # A struct: the children that hold selected leaves, in schema order.
  kids <- layout$children[[key]]
  wanted <- as.integer(names(data))
  kids <- kids[vapply(
    kids,
    function(k) {
      k %in%
        wanted ||
        any(vapply(
          wanted,
          function(e) {
            qio_has_ancestor(layout, e, k)
          },
          logical(1)
        ))
    },
    logical(1)
  )]
  columns <- lapply(
    kids,
    qio_build_node,
    data = data,
    layout = layout,
    rows = rows
  )
  out <- qio_frame(columns, layout$names[kids], rows)
  if (layout$repetition[[node]] == "OPTIONAL") {
    # Any leaf under the struct says, at each row's first entry, how far down
    # its ancestors are defined.
    below <- wanted[vapply(
      wanted,
      function(e) {
        qio_has_ancestor(layout, e, node)
      },
      logical(1)
    )][[1L]]
    row_def <- qio_row_def(data[[as.character(below)]], rows)
    attr(out, "null") <- row_def < layout$def[[node]]
    class(out) <- c("qio_struct", "data.frame")
  }
  out
}

# A LIST of one leaf, or a MAP of a key and a value leaf: one R value per row,
# NULL where the container (or an ancestor) is null.
qio_build_container <- function(node, shape, data, layout, rows) {
  repeated <- layout$children[[as.character(node)]]
  members <- layout$children[[as.character(repeated)]]
  first <- data[[as.character(members[[1L]])]]
  if (
    is.null(first) ||
      (shape == "map" && is.null(data[[as.character(members[[2L]])]]))
  ) {
    stop(
      "qio: internal error: a LIST or MAP was read without its leaves.",
      call. = FALSE
    )
  }
  def <- if (is.null(first$def)) rep(0L, first$entries) else first$def
  row <- cumsum(first$rep == 0L)
  is_entry <- def >= layout$def[[repeated]]
  defined <- qio_row_def(first, rows) >= layout$def[[node]]
  group <- factor(row[is_entry], levels = seq_len(rows))

  part <- function(leaf) {
    if (!is.null(leaf$rep) && length(leaf$rep) != length(first$rep)) {
      stop(
        "qio: the key and value of a MAP disagree on their entries.",
        call. = FALSE
      )
    }
    values <- qio_expand(
      leaf$values,
      leaf$def,
      leaf$max_def,
      keep = which(is_entry)
    )
    split(values, group)
  }

  if (shape == "list") {
    out <- part(first)
  } else {
    keys <- part(first)
    values <- part(data[[as.character(members[[2L]])]])
    out <- lapply(seq_len(rows), function(i) {
      k <- keys[[i]]
      qio_frame(list(k, values[[i]]), c("key", "value"), length(k))
    })
  }
  names(out) <- NULL
  out[!defined] <- list(NULL)
  out
}

#' Find the null rows of a struct column
#'
#' qio reads a Parquet struct as a data-frame column. A null struct and a
#' struct whose fields are all null both have `NA` in every field, so an
#' optional struct carries which rows are null itself. `is_null_struct()`
#' returns that.
#'
#' @param x A data-frame column that [collect()] or [read_parquet()] returned
#'   for a Parquet struct, or any data frame.
#'
#' @return A logical vector with one value per row of `x`: `TRUE` where the
#'   struct is null. A required struct, or any data frame qio did not make, is
#'   never null, so the result is all `FALSE`.
#'
#'   Row subsetting (`x[i, ]`, and subsetting the data frame holding `x`)
#'   keeps the mask in step. Combining rows with `rbind()` does not, and
#'   `is_null_struct()` then refuses rather than guess.
#' @seealso The "Nested columns" section of [collect()].
#' @export
#' @examples
#' path <- tempfile(fileext = ".parquet")
#' write_parquet(data.frame(x = 1:3), path)
#' is_null_struct(read_parquet(path))
is_null_struct <- function(x) {
  if (!is.data.frame(x)) {
    stop("`x` must be a data frame.", call. = FALSE)
  }
  mask <- attr(x, "null", exact = TRUE)
  if (!inherits(x, "qio_struct") || is.null(mask)) {
    return(rep(FALSE, nrow(x)))
  }
  if (!is.logical(mask) || length(mask) != nrow(x)) {
    stop(
      "The null mask of this struct column no longer matches its rows; ",
      "it was probably combined with rbind() after reading.",
      call. = FALSE
    )
  }
  mask
}

#' @export
`[.qio_struct` <- function(x, i, j, drop) {
  mask <- attr(x, "null", exact = TRUE)
  plain <- x
  attr(plain, "null") <- NULL
  class(plain) <- setdiff(class(plain), "qio_struct")
  # A missing argument cannot be passed on to `[` as a variable (the primitive
  # drops it, turning x[i, ] into x[i]), so each form is spelled out.
  # `!` binds more loosely than `>=`, so the count is taken first.
  given <- nargs() - as.integer(!missing(drop))
  matrix_form <- given >= 3L
  out <- if (!matrix_form) {
    if (missing(i)) plain[] else plain[i]
  } else if (missing(i) && missing(j)) {
    if (missing(drop)) plain[,] else plain[,, drop = drop]
  } else if (missing(i)) {
    if (missing(drop)) plain[, j] else plain[, j, drop = drop]
  } else if (missing(j)) {
    if (missing(drop)) plain[i, ] else plain[i, , drop = drop]
  } else {
    if (missing(drop)) plain[i, j] else plain[i, j, drop = drop]
  }
  if (!is.data.frame(out)) {
    return(out)
  }
  if (matrix_form && !missing(i) && !is.null(mask)) {
    names(mask) <- row.names(plain)
    mask <- unname(mask[i])
  }
  attr(out, "null") <- mask
  class(out) <- c("qio_struct", class(out))
  out
}
