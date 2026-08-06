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
#'   \item{Writing bloom filters and page indexes}{Both can be *read*:
#'     [bloom_filter_may_contain()] tests membership and [page_index()] reports
#'     per-page bounds and locations. Neither is written, because the writer
#'     options that control them belong to the writer configuration deferred
#'     below.}
#'   \item{Reading back a declared sort order}{[write_parquet()] can record one
#'     with `sorted_by`, but carquet exposes no way to read it back, so qio
#'     cannot report the declaration in a file it did not write.}
#'   \item{Encryption}{Files with an encrypted footer are rejected by
#'     [validate_parquet()] and cannot be read.}
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
#' @seealso [column_chunks()], [validate_parquet()], [collect()]
NULL
