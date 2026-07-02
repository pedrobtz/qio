#ifndef QIO_FILE_H
#define QIO_FILE_H

#include <Rinternals.h>

SEXP qio_parquet_open(SEXP path, SEXP use_mmap, SEXP verify_checksums,
                      SEXP threads);
SEXP qio_parquet_close(SEXP file);
SEXP qio_parquet_is_open(SEXP file);
SEXP qio_parquet_path(SEXP file);
SEXP qio_parquet_dim(SEXP file);
SEXP qio_parquet_names(SEXP file);
SEXP qio_parquet_schema(SEXP file);
SEXP qio_parquet_row_groups(SEXP file);
SEXP qio_parquet_metadata(SEXP file);
SEXP qio_parquet_collect(SEXP file, SEXP columns, SEXP row_groups,
                         SEXP batch_size);
SEXP qio_parquet_walk(SEXP file, SEXP columns, SEXP row_groups,
                      SEXP batch_size, SEXP callback);

#endif
