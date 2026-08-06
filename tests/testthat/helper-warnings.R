# Capture every warning an expression raises, not just the first.
#
# expect_warning() consumes one condition and lets the rest escape to the
# console, which hides exactly what the per-column coercion warnings need to
# assert: how many columns warned, and which. Returning the value alongside the
# messages keeps a single read serving both the warning and the data checks.
collect_warnings <- function(expr) {
  messages <- character()
  value <- withCallingHandlers(
    expr,
    warning = function(w) {
      messages <<- c(messages, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  list(value = value, warnings = messages)
}
