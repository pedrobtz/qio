# dplyr exports its own `collect()` generic, and attaching dplyr masks qio's.
# Because they are different generics, the method qio registers on its own is
# invisible to dplyr's: with dplyr attached, both `collect(pf)` and
# `dplyr::collect(pf)` failed with "no applicable method", and only
# `qio::collect(pf)` worked. Registering the method on dplyr's generic as well
# makes all three work.
#
# Registration is deferred, so it costs nothing when dplyr is not installed and
# adds no dependency: qio keeps its own generic for sessions without dplyr.
.onLoad <- function(libname, pkgname) {
  qio_s3_register("dplyr::collect", "qio_parquet_file")
}

# Register an S3 method for a generic that may not exist yet. Vendored from
# vctrs, which publishes it under MIT precisely so packages can copy it rather
# than take a dependency for one function. See ?vctrs::s3_register.
#
# Kept verbatim in behavior: if the package is already loaded the method is
# registered now, and a hook covers the case where it loads later.
qio_s3_register <- function(generic, class, method = NULL) {
  stopifnot(is.character(generic), length(generic) == 1L)
  stopifnot(is.character(class), length(class) == 1L)

  pieces <- strsplit(generic, "::")[[1L]]
  stopifnot(length(pieces) == 2L)
  package <- pieces[[1L]]
  generic_name <- pieces[[2L]]

  caller <- parent.frame()

  get_method_env <- function() {
    top <- topenv(caller)
    if (isNamespace(top)) asNamespace(environmentName(top)) else caller
  }
  get_method <- function(method) {
    if (is.null(method)) {
      get(paste0(generic_name, ".", class), envir = get_method_env())
    } else {
      method
    }
  }

  register <- function(...) {
    envir <- asNamespace(package)
    # Refresh the method each time: the definition may have been reloaded.
    method_fn <- get_method(method)
    stopifnot(is.function(method_fn))
    registerS3method(generic_name, class, method_fn, envir = envir)
  }

  # A namespace that is loading cannot be registered into yet.
  if (isNamespaceLoaded(package)) {
    register()
  }
  setHook(packageEvent(package, "onLoad"), function(...) register())
  invisible()
}
