## Resubmission

This is a patch release fixing the sanitizer issues reported for qio 0.1.0
(deadline 2026-10-19):

* M1-SAN and the clang-UBSAN and gcc-UBSAN additional issues flagged
  misaligned `int32_t`, `int64_t` and `float` loads in `src/qio_file.c`.
  These values are now read through `memcpy()`.
* clang-UBSAN and gcc-UBSAN also flagged NULL pointers passed to `memcmp()`
  and `memcpy()` in the bundled carquet library (`encoding/dictionary.c` and
  `writer/column_writer.c`) when a string column holds empty strings. Those
  calls are now skipped for zero-length values.

The package is now checked in CI under UBSan with clang and with gcc
(`-fsanitize=undefined,bounds-strict`) and under ASan in the clang-asan and
gcc-asan containers. None of these runs reports anything.

## R CMD check results

0 errors | 0 warnings | 0 notes

## Test environments

* Local macOS arm64, R-devel
* GitHub Actions: Ubuntu (R-devel, release, oldrel-1), Windows (R-devel,
  release), macOS (release)
* GitHub Actions: clang and gcc UBSan, clang-asan and gcc-asan, Valgrind

## Downstream dependencies

There are currently no downstream dependencies.
