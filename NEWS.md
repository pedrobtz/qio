# qio 0.1.1

* Fixed undefined behavior reported by CRAN's sanitizer checks (M1-SAN,
  clang-UBSAN and gcc-UBSAN). Batch reads no longer load integer and
  floating-point values through misaligned pointers, and writing a string
  column that contains empty strings no longer passes a NULL pointer to
  `memcmp()` or `memcpy()`. Results were already correct; only the undefined
  behavior is removed.

# qio 0.1.0

* Initial release.
