# Little-endian ISO WKB for test geometries.
wkb_point <- function(x, y, z = NULL) {
  type <- if (is.null(z)) 1L else 1001L
  c(
    as.raw(1),
    writeBin(type, raw(), size = 4, endian = "little"),
    writeBin(c(x, y, z), raw(), size = 8, endian = "little")
  )
}

wkb_linestring <- function(x, y) {
  c(
    as.raw(1),
    writeBin(2L, raw(), size = 4, endian = "little"),
    writeBin(length(x), raw(), size = 4, endian = "little"),
    writeBin(as.vector(rbind(x, y)), raw(), size = 8, endian = "little")
  )
}
