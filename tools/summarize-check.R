#!/usr/bin/env Rscript
#
# Summarize R CMD check results into the GitHub job summary.
#
#   Rscript tools/summarize-check.R [check-dir]
#
# r-lib/actions/check-r-package streams the whole check to the log and uploads
# the directory as an artifact when it fails, but never states the outcome
# anywhere you can see without opening one or the other. On a six-way matrix
# that means six logs to read to find which platform produced a NOTE, and a
# green run tells you nothing about NOTEs at all.
#
# This reads every 00check.log under the directory and writes one table plus
# the full text of anything that is not OK. It never fails the job: the check
# step already decides that, and a reporting step that can fail would obscure
# the result it exists to report.

directory <- commandArgs(trailingOnly = TRUE)
directory <- if (length(directory)) directory[[1L]] else "check"

logs <- list.files(
  directory,
  pattern = "^00check\\.log$",
  recursive = TRUE,
  full.names = TRUE
)
if (!length(logs)) {
  cat("No 00check.log under", directory, "\n")
  quit(status = 0L)
}

# A result block is a `* checking ...` line carrying its verdict, followed by
# indented detail lines until the next `*` line. Anything not OK is worth
# printing in full; OK lines are worth counting only.
blocks_not_ok <- function(lines) {
  starts <- grep("^\\* ", lines)
  blocks <- list()
  for (i in seq_along(starts)) {
    from <- starts[[i]]
    to <- if (i < length(starts)) starts[[i + 1L]] - 1L else length(lines)
    head_line <- lines[[from]]
    verdict <- sub(".*\\.\\.\\. ", "", head_line)
    if (!grepl("^(ERROR|WARNING|NOTE)", verdict)) {
      next
    }
    blocks[[length(blocks) + 1L]] <- list(
      severity = sub("^(ERROR|WARNING|NOTE).*", "\\1", verdict),
      text = lines[from:to]
    )
  }
  blocks
}

summary_file <- Sys.getenv("GITHUB_STEP_SUMMARY", "")
emit <- function(...) {
  text <- paste0(..., collapse = "")
  cat(text, "\n", sep = "")
  if (nzchar(summary_file)) {
    cat(text, "\n", sep = "", file = summary_file, append = TRUE)
  }
}

platform <- Sys.getenv("QIO_CHECK_LABEL", "")
if (!nzchar(platform)) {
  platform <- paste(R.version$platform, R.version.string)
}

emit("### R CMD check -- ", platform)
emit("")

any_not_ok <- FALSE
for (log in logs) {
  lines <- readLines(log, warn = FALSE)
  status <- grep("^Status: ", lines, value = TRUE)
  status <- if (length(status)) {
    sub("^Status: ", "", status[[length(status)]])
  } else {
    "unknown"
  }
  blocks <- blocks_not_ok(lines)
  counts <- table(vapply(blocks, function(b) b$severity, character(1)))

  emit("| result | count |")
  emit("|---|---:|")
  for (severity in c("ERROR", "WARNING", "NOTE")) {
    emit(
      "| ",
      severity,
      " | ",
      if (severity %in% names(counts)) counts[[severity]] else 0L,
      " |"
    )
  }
  emit("")
  emit("**Status: ", status, "**")
  # The check runs with --as-cran (the action's default), so a NOTE here is a
  # NOTE CRAN would raise. NOTEs do not fail the job, which is exactly why the
  # summary has to say so rather than leaving a green tick to speak for itself.
  if (any(names(counts) == "NOTE")) {
    emit("")
    emit(
      "> This run is green but carries ",
      counts[["NOTE"]],
      " NOTE",
      if (counts[["NOTE"]] == 1L) "" else "s",
      ". `--as-cran` is on, so these are the NOTEs a CRAN submission would",
      " have to answer for."
    )
  }

  if (length(blocks)) {
    any_not_ok <- TRUE
    emit("")
    for (block in blocks) {
      # `open` on purpose. A NOTE does not fail the job -- the action's
      # error-on default is "warning" -- so a run carrying one is green, and a
      # NOTE hidden behind a disclosure triangle on a green run is a NOTE
      # nobody reads. Every one of them blocks a CRAN submission.
      emit(
        "<details open><summary><b>",
        block$severity,
        "</b>: ",
        sub("^\\* checking ", "", sub(" \\.\\.\\..*$", "", block$text[[1L]])),
        "</summary>"
      )
      emit("")
      emit("```")
      emit(paste(block$text, collapse = "\n"))
      emit("```")
      emit("")
      emit("</details>")
    }
  }
}

if (!any_not_ok) {
  emit("")
  emit("No errors, warnings, or notes.")
}

# Links last, so the tables above stay the thing you read first. The artifact
# holds the untruncated 00check.log, 00install.out, and test output; the run
# link reaches the raw job log when the failure is in the build rather than in
# the check.
artifact <- Sys.getenv("QIO_CHECK_ARTIFACT_URL", "")
run <- Sys.getenv("QIO_RUN_URL", "")
if (nzchar(artifact) || nzchar(run)) {
  emit("")
  parts <- character()
  if (nzchar(artifact)) {
    parts <- c(parts, paste0("[full check logs](", artifact, ")"))
  }
  if (nzchar(run)) {
    parts <- c(parts, paste0("[job log](", run, ")"))
  }
  emit(paste(parts, collapse = " | "))
}
