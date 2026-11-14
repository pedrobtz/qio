# Independent implementations used as oracles are not dependencies of qio.
# The files named test-ci-*.R use them, and .Rbuildignore leaves those files
# out of the tarball, so R CMD check and CRAN never see them. In CI the
# oracles workflow sets QIO_ORACLES=true, which makes a missing oracle a
# failure; locally, devtools::test() skips what is not installed.
skip_without_oracle <- function(package) {
  if (identical(Sys.getenv("QIO_ORACLES"), "true")) {
    if (!requireNamespace(package, quietly = TRUE)) {
      stop(sprintf("The oracle package %s is not installed.", package))
    }
    return(invisible())
  }
  skip_on_cran()
  skip_if_not_installed(package)
}
