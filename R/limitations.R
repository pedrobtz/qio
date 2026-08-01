#' What qio does not do
#'
#' The vendored `carquet` library implements more of the Parquet specification
#' than qio exposes. This topic records what is deliberately left out and why,
#' so an absent function reads as a decision rather than an oversight.
#'
#' @section Not exposed in 0.1.0:
#'
#' \describe{
#'   \item{Nested and repeated columns}{`LIST`, `MAP`, and struct columns are
#'     skipped on read, with one message per operation. carquet returns the
#'     definition and repetition levels needed to rebuild them, but assembling
#'     R objects from those levels, and deciding how a null list differs from an
#'     empty one, is qio's work and is deferred to 0.2.0.}
#'   \item{Predicate pushdown and page filters}{carquet can skip pages using
#'     statistics. qio reads whole columns. Filtering happens in R, after the
#'     read, where the answer does not depend on a writer's honesty about its
#'     own statistics.}
#'   \item{Bloom filters, column indexes, and offset indexes}{Their presence is
#'     reported by [column_chunks()], but their contents are not. They exist to
#'     support pruning, which qio does not do.}
#'   \item{Append mode}{carquet can add row groups to an existing file, but its
#'     compatibility check compares physical types and logical type IDs without
#'     comparing parent paths or logical *parameters*: decimal scale, timestamp
#'     unit, integer signedness. Appending a microsecond timestamp column to a
#'     millisecond file passes that check and corrupts a file that was correct.
#'     Deferred to 0.2.0 with the qio-side validation it needs.}
#'   \item{Sorting declarations}{Parquet can record that a file is sorted by
#'     given columns. Nothing verifies the claim, and qio has no use for it.}
#'   \item{Encryption}{Files with an encrypted footer are rejected by
#'     [parquet_validate()] and cannot be read.}
#'   \item{External column metadata}{Modelled by carquet but not implemented
#'     there; the API returns "not implemented".}
#'   \item{Writer tuning}{Dictionary encoding, per-column encodings, page sizes,
#'     checksums, and index generation are carquet options that qio does not
#'     surface. The reusable writer configuration that would carry them is
#'     deferred to 0.2.0 rather than guessed at now.}
#'   \item{Geospatial and variant types}{Read as their physical storage, without
#'     interpretation.}
#' }
#'
#' @section Boundaries that are not carquet's:
#'
#' Some limits come from R rather than from Parquet. A single result cannot
#' exceed `.Machine$integer.max` rows. `INT64` columns lose precision beyond
#' 2^53 unless read as [bit64::integer64]. R's `integer` reserves
#' `-2147483648` for `NA`, so a Parquet `INT32` holding that value reads as
#' `NA` with a warning. See `vignette` topics and [collect()] for the details.
#'
#' @name qio-limitations
#' @seealso [column_chunks()], [parquet_validate()], [collect()]
NULL
