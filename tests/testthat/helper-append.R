writer_pair <- function() {
  list(
    first = data.frame(
      a = 1:5,
      b = c(1.5, 2.5, NA, 4.5, 5.5),
      s = letters[1:5],
      stringsAsFactors = FALSE
    ),
    second = data.frame(
      a = 6:10,
      b = c(6.5, 7.5, 8.5, 9.5, 10.5),
      s = letters[6:10],
      stringsAsFactors = FALSE
    )
  )
}

# A failed append must leave the file exactly as it was. Before 0.1.2 the
# first new row group overwrote the old footer, so any failure after it left
# the user's file unreadable (#34).
bytes_strings <- function(...) {
  s <- c(...)
  Encoding(s) <- "bytes"
  s
}
