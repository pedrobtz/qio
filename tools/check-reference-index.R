#!/usr/bin/env Rscript
#
# Check that every exported topic appears in the pkgdown reference index.
#
#   Rscript tools/check-reference-index.R
#
# pkgdown::check_pkgdown() does this too, but refuses to run at all until
# _pkgdown.yml has a `url`, which is a release-time setting rather than a
# documentation one. This checks the part that matters while writing docs: a
# newly exported function that nobody added to the index would otherwise be
# missing from the site with no warning until release week.

suppressMessages(library(pkgdown))

pkg <- pkgdown::as_pkgdown(".")
config <- yaml::read_yaml("_pkgdown.yml")

listed <- unlist(lapply(config$reference, function(section) section$contents))
listed <- listed[!grepl("^-", listed)] # drop any exclusion entries
documented <- pkg$topics$name[!pkg$topics$internal]

missing <- setdiff(documented, listed)
unknown <- setdiff(listed, pkg$topics$name)

status <- 0L
if (length(missing) > 0L) {
  cat("Topics missing from the reference index:\n")
  cat(paste0("  ", missing, collapse = "\n"), "\n")
  status <- 1L
}
if (length(unknown) > 0L) {
  cat("Index entries with no matching topic:\n")
  cat(paste0("  ", unknown, collapse = "\n"), "\n")
  status <- 1L
}
if (status == 0L) {
  cat(sprintf(
    "OK: all %d exported topics are in the reference index.\n",
    length(documented)
  ))
}
quit(status = status)
