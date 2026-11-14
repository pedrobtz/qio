## Submission

This is a minor release. It adds writing of binary and geospatial
(`GEOMETRY`, `GEOGRAPHY`) columns and reading of their geospatial
statistics, and fixes four bugs, including one where a failed
`write_parquet(append = TRUE)` could leave the original file unreadable.
See NEWS.md.

## R CMD check results

0 errors | 0 warnings | 0 notes

On every environment below: R CMD check `--as-cran` locally on macOS
(R 4.6.2), and on GitHub Actions for the release commit.

## Test environments

* Local macOS, R release
* GitHub Actions: Ubuntu (release, oldrel-1), Windows (R-devel, release),
  macOS (release), and the CRAN-like clang23, ubuntu-clang and ubuntu-gcc16
  containers (R-devel), plus CRAN's NOSUGGESTS setup
* GitHub Actions: clang and gcc UBSan, clang-asan and gcc-asan, Valgrind,
  rchk, LTO, gctorture, and the rcnst, rlibro and vnu checks

## Downstream dependencies

There are currently no downstream dependencies on CRAN.
