/*
 * qio.c — R <-> carquet glue for reading and writing Parquet files.
 *
 * Exposes two .Call entry points:
 *   qio_read_parquet(path)            -> data.frame
 *   qio_write_parquet(x, path, codec, schema) -> invisible(path)
 *
 * Type mapping (v1, flat schemas only):
 *
 *   Parquet physical   ->  R
 *   ----------------       ------------------
 *   BOOLEAN                logical
 *   INT32                  integer
 *   INT64                  double  (precision loss beyond 2^53)
 *   FLOAT                  double
 *   DOUBLE                 double
 *   BYTE_ARRAY             character (assumed UTF-8)
 *
 *   R                  ->  Parquet physical (+ logical)
 *   ----------------       ------------------
 *   logical               BOOLEAN
 *   integer               INT32
 *   double                DOUBLE
 *   Date                  INT32 + DATE
 *   POSIXct               INT64 + TIMESTAMP(MICROS, UTC)
 *   character             BYTE_ARRAY + STRING
 *   factor                character -> BYTE_ARRAY + STRING
 *
 * NULL handling: a column is written OPTIONAL when it contains any NA, else
 * REQUIRED. Parquet nulls map to R NA. For doubles, R's NA maps to null while
 * NaN is preserved as a value.
 */

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include "qio_file.h"

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#include <carquet/carquet.h>

/* Logical rows moved per carquet read/write batch call. */
#define QIO_CHUNK 65536

/* ------------------------------------------------------------------------- */
/* Helpers                                                                   */
/* ------------------------------------------------------------------------- */

static int qio_codec_from_string(const char *s, carquet_compression_t *out) {
    if      (strcmp(s, "snappy") == 0)       *out = CARQUET_COMPRESSION_SNAPPY;
    else if (strcmp(s, "gzip") == 0)         *out = CARQUET_COMPRESSION_GZIP;
    else if (strcmp(s, "zstd") == 0)         *out = CARQUET_COMPRESSION_ZSTD;
    else if (strcmp(s, "lz4") == 0)          *out = CARQUET_COMPRESSION_LZ4_RAW;
    else if (strcmp(s, "uncompressed") == 0) *out = CARQUET_COMPRESSION_UNCOMPRESSED;
    else if (strcmp(s, "none") == 0)         *out = CARQUET_COMPRESSION_UNCOMPRESSED;
    else return 0;
    return 1;
}

/* ------------------------------------------------------------------------- */
/* Read                                                                      */
/* ------------------------------------------------------------------------- */

/* Scatter one decoded batch (packed values + per-row def levels) into the R
 * column starting at logical row `row`. Nulls become R NA. */
static void qio_scatter(SEXP col, carquet_physical_type_t pt, R_xlen_t row,
                        const void *values, const int16_t *def, int16_t max_def,
                        int64_t n) {
    int64_t i, vi = 0;
    for (i = 0; i < n; i++) {
        int present = (max_def <= 0) ? 1 : (def[i] >= max_def);
        R_xlen_t at = row + i;
        switch (pt) {
        case CARQUET_PHYSICAL_BOOLEAN:
            LOGICAL(col)[at] = present ? (((const uint8_t *)values)[vi++] ? TRUE : FALSE)
                                       : NA_LOGICAL;
            break;
        case CARQUET_PHYSICAL_INT32:
            INTEGER(col)[at] = present ? ((const int32_t *)values)[vi++] : NA_INTEGER;
            break;
        case CARQUET_PHYSICAL_INT64:
            REAL(col)[at] = present ? (double)((const int64_t *)values)[vi++] : NA_REAL;
            break;
        case CARQUET_PHYSICAL_FLOAT:
            REAL(col)[at] = present ? (double)((const float *)values)[vi++] : NA_REAL;
            break;
        case CARQUET_PHYSICAL_DOUBLE:
            REAL(col)[at] = present ? ((const double *)values)[vi++] : NA_REAL;
            break;
        case CARQUET_PHYSICAL_BYTE_ARRAY: {
            if (present) {
                const carquet_byte_array_t *e = &((const carquet_byte_array_t *)values)[vi++];
                int len = e->length > 0 ? e->length : 0;
                const char *d = (len > 0) ? (const char *)e->data : "";
                SET_STRING_ELT(col, at, Rf_mkCharLenCE(d, len, CE_UTF8));
            } else {
                SET_STRING_ELT(col, at, NA_STRING);
            }
            break;
        }
        default:
            break;
        }
    }
}

SEXP qio_read_parquet(SEXP path_sexp) {
    if (TYPEOF(path_sexp) != STRSXP || LENGTH(path_sexp) < 1)
        Rf_error("qio: `file` must be a single path");

    const char *path = Rf_translateChar(STRING_ELT(path_sexp, 0));
    carquet_error_t err = CARQUET_ERROR_INIT;

    carquet_reader_t *reader = carquet_reader_open(path, NULL, &err);
    if (!reader)
        Rf_error("qio: cannot open '%s': %s", path, err.message);

    const carquet_schema_t *schema = carquet_reader_schema(reader);
    int64_t nrow64 = carquet_reader_num_rows(reader);
    int ncol = carquet_reader_num_columns(reader);
    int nrg  = carquet_reader_num_row_groups(reader);

    if (nrow64 < 0 || nrow64 > INT_MAX) {
        carquet_reader_close(reader);
        Rf_error("qio: unsupported row count %lld (max %d)", (long long)nrow64, INT_MAX);
    }
    R_xlen_t nrow = (R_xlen_t)nrow64;

    /* Validate every column's physical type before allocating anything, so an
     * unsupported file fails cleanly with the reader still open to close. */
    for (int c = 0; c < ncol; c++) {
        switch (carquet_schema_column_type(schema, c)) {
        case CARQUET_PHYSICAL_BOOLEAN:
        case CARQUET_PHYSICAL_INT32:
        case CARQUET_PHYSICAL_INT64:
        case CARQUET_PHYSICAL_FLOAT:
        case CARQUET_PHYSICAL_DOUBLE:
        case CARQUET_PHYSICAL_BYTE_ARRAY:
            break;
        default: {
            const char *nm = carquet_schema_column_name(schema, c);
            carquet_reader_close(reader);
            Rf_error("qio: column '%s' has an unsupported physical type", nm ? nm : "");
        }
        }
    }

    SEXP df  = PROTECT(Rf_allocVector(VECSXP, ncol));
    SEXP nms = PROTECT(Rf_allocVector(STRSXP, ncol));
    for (int c = 0; c < ncol; c++) {
        const char *cname = carquet_schema_column_name(schema, c);
        SET_STRING_ELT(nms, c, Rf_mkCharCE(cname ? cname : "", CE_UTF8));
        SEXP col;
        switch (carquet_schema_column_type(schema, c)) {
        case CARQUET_PHYSICAL_BOOLEAN:    col = Rf_allocVector(LGLSXP,  nrow); break;
        case CARQUET_PHYSICAL_INT32:      col = Rf_allocVector(INTSXP,  nrow); break;
        case CARQUET_PHYSICAL_BYTE_ARRAY: col = Rf_allocVector(STRSXP,  nrow); break;
        default:                          col = Rf_allocVector(REALSXP, nrow); break;
        }
        SET_VECTOR_ELT(df, c, col);
    }

    char errmsg[CARQUET_ERROR_MESSAGE_MAX + 64];
    errmsg[0] = '\0';

    for (int c = 0; c < ncol && errmsg[0] == '\0'; c++) {
        void *vmax = vmaxget();
        carquet_physical_type_t pt = carquet_schema_column_type(schema, c);
        int16_t max_def = carquet_schema_max_def_level(schema, c);
        if (max_def < 0) max_def = 0;
        SEXP col = VECTOR_ELT(df, c);

        size_t esz;
        switch (pt) {
        case CARQUET_PHYSICAL_BOOLEAN:    esz = 1; break;
        case CARQUET_PHYSICAL_INT32:      esz = 4; break;
        case CARQUET_PHYSICAL_INT64:      esz = 8; break;
        case CARQUET_PHYSICAL_FLOAT:      esz = 4; break;
        case CARQUET_PHYSICAL_DOUBLE:     esz = 8; break;
        default:                          esz = sizeof(carquet_byte_array_t); break;
        }
        void *valbuf = R_alloc(QIO_CHUNK, esz);
        int16_t *defbuf = (max_def > 0) ? (int16_t *)R_alloc(QIO_CHUNK, sizeof(int16_t)) : NULL;

        R_xlen_t row = 0;
        for (int g = 0; g < nrg && errmsg[0] == '\0'; g++) {
            carquet_error_t cerr = CARQUET_ERROR_INIT;
            carquet_column_reader_t *cr = carquet_reader_get_column(reader, g, c, &cerr);
            if (!cr) {
                snprintf(errmsg, sizeof(errmsg), "column '%s' row group %d: %s",
                         carquet_schema_column_name(schema, c), g, cerr.message);
                break;
            }
            for (;;) {
                int64_t n = carquet_column_read_batch(cr, valbuf, QIO_CHUNK, defbuf, NULL);
                if (n < 0) {
                    snprintf(errmsg, sizeof(errmsg), "decode error in column '%s'",
                             carquet_schema_column_name(schema, c));
                    break;
                }
                if (n == 0) break;
                if (row + n > nrow) { n = nrow - row; }
                qio_scatter(col, pt, row, valbuf, defbuf, max_def, n);
                row += n;
            }
            carquet_column_reader_free(cr);
        }
        vmaxset(vmax);
    }

    carquet_reader_close(reader);

    if (errmsg[0] != '\0') {
        UNPROTECT(2); /* df, nms */
        Rf_error("qio: %s", errmsg);
    }

    Rf_setAttrib(df, R_NamesSymbol, nms);
    SEXP rn = PROTECT(Rf_allocVector(INTSXP, 2));
    INTEGER(rn)[0] = NA_INTEGER;
    INTEGER(rn)[1] = -(int)nrow; /* compact row.names: c(NA, -n) */
    Rf_setAttrib(df, R_RowNamesSymbol, rn);
    Rf_classgets(df, Rf_mkString("data.frame"));

    UNPROTECT(3); /* df, nms, rn */
    return df;
}

/* ------------------------------------------------------------------------- */
/* Write                                                                     */
/* ------------------------------------------------------------------------- */

SEXP qio_write_parquet(SEXP x, SEXP path_sexp, SEXP codec_sexp, SEXP spec_sexp) {
    if (TYPEOF(x) != VECSXP)
        Rf_error("qio: `x` must be a data.frame");
    if (TYPEOF(path_sexp) != STRSXP || LENGTH(path_sexp) < 1)
        Rf_error("qio: `file` must be a single path");
    if (TYPEOF(codec_sexp) != STRSXP || LENGTH(codec_sexp) < 1)
        Rf_error("qio: `compression` must be a string");
    if (TYPEOF(spec_sexp) != VECSXP || LENGTH(spec_sexp) != 4)
        Rf_error("qio: invalid writer schema");

    const char *path = Rf_translateChar(STRING_ELT(path_sexp, 0));
    carquet_compression_t codec;
    if (!qio_codec_from_string(CHAR(STRING_ELT(codec_sexp, 0)), &codec))
        Rf_error("qio: unknown compression '%s'", CHAR(STRING_ELT(codec_sexp, 0)));

    int ncol = LENGTH(x);
    if (ncol == 0)
        Rf_error("qio: `x` has no columns");

    R_xlen_t nrow = XLENGTH(VECTOR_ELT(x, 0));
    if (nrow > INT_MAX)
        Rf_error("qio: more than %d rows is not supported", INT_MAX);

    SEXP nms = Rf_getAttrib(x, R_NamesSymbol);

    SEXP ptype_sexp = VECTOR_ELT(spec_sexp, 0);
    SEXP ltype_sexp = VECTOR_ELT(spec_sexp, 1);
    SEXP unit_sexp = VECTOR_ELT(spec_sexp, 2);
    SEXP nullable_sexp = VECTOR_ELT(spec_sexp, 3);
    if (TYPEOF(ptype_sexp) != INTSXP || TYPEOF(ltype_sexp) != INTSXP ||
        TYPEOF(unit_sexp) != INTSXP || TYPEOF(nullable_sexp) != LGLSXP ||
        LENGTH(ptype_sexp) != ncol || LENGTH(ltype_sexp) != ncol ||
        LENGTH(unit_sexp) != ncol || LENGTH(nullable_sexp) != ncol)
        Rf_error("qio: invalid writer schema vectors");

    int *ptype = INTEGER(ptype_sexp);
    int *ltype = INTEGER(ltype_sexp);
    int *time_unit = INTEGER(unit_sexp);
    int *nullable = LOGICAL(nullable_sexp);

    /* R has already validated and converted each column according to the
     * schema. Check storage types again before any output file is created. */
    SEXP cols = x;

    for (int c = 0; c < ncol; c++) {
        SEXP v = VECTOR_ELT(x, c);
        if (XLENGTH(v) != nrow) {
            Rf_error("qio: column %d has length %lld, expected %lld",
                     c + 1, (long long)XLENGTH(v), (long long)nrow);
        }
        int expected = ptype[c] == CARQUET_PHYSICAL_BOOLEAN ? LGLSXP :
                       ptype[c] == CARQUET_PHYSICAL_INT32 ? INTSXP :
                       ptype[c] == CARQUET_PHYSICAL_BYTE_ARRAY ? STRSXP : REALSXP;
        if (ptype[c] != CARQUET_PHYSICAL_BOOLEAN &&
            ptype[c] != CARQUET_PHYSICAL_INT32 &&
            ptype[c] != CARQUET_PHYSICAL_INT64 &&
            ptype[c] != CARQUET_PHYSICAL_FLOAT &&
            ptype[c] != CARQUET_PHYSICAL_DOUBLE &&
            ptype[c] != CARQUET_PHYSICAL_BYTE_ARRAY)
            Rf_error("qio: invalid physical type for column %d", c + 1);
        if (ltype[c] < 0 || ltype[c] > 3 ||
            (ltype[c] == 1 && ptype[c] != CARQUET_PHYSICAL_INT32) ||
            (ltype[c] == 2 && (ptype[c] != CARQUET_PHYSICAL_INT64 ||
                              time_unit[c] < 1 || time_unit[c] > 3)) ||
            (ltype[c] == 3 && ptype[c] != CARQUET_PHYSICAL_BYTE_ARRAY))
            Rf_error("qio: invalid logical type for column %d", c + 1);
        if (nullable[c] != 0 && nullable[c] != 1)
            Rf_error("qio: invalid repetition for column %d", c + 1);
        if (ltype[c] == 1 || ltype[c] == 2) expected = REALSXP;
        if (TYPEOF(v) != expected)
            Rf_error("qio: column %d does not match its writer schema", c + 1);
    }

    carquet_error_t err = CARQUET_ERROR_INIT;
    carquet_schema_t *schema = carquet_schema_create(&err);
    if (!schema) {
        Rf_error("qio: failed to create schema: %s", err.message);
    }

    carquet_logical_type_t string_lt;
    memset(&string_lt, 0, sizeof(string_lt));
    string_lt.id = CARQUET_LOGICAL_STRING;

    carquet_logical_type_t date_lt;
    memset(&date_lt, 0, sizeof(date_lt));
    date_lt.id = CARQUET_LOGICAL_DATE;

    for (int c = 0; c < ncol; c++) {
        char namebuf[64];
        const char *nm;
        if (nms != R_NilValue && STRING_ELT(nms, c) != NA_STRING &&
            CHAR(STRING_ELT(nms, c))[0] != '\0') {
            nm = Rf_translateCharUTF8(STRING_ELT(nms, c));
        } else {
            snprintf(namebuf, sizeof(namebuf), "V%d", c + 1);
            nm = namebuf;
        }
        carquet_logical_type_t timestamp_lt;
        memset(&timestamp_lt, 0, sizeof(timestamp_lt));
        timestamp_lt.id = CARQUET_LOGICAL_TIMESTAMP;
        timestamp_lt.params.timestamp.unit = (carquet_time_unit_t)(time_unit[c] - 1);
        timestamp_lt.params.timestamp.is_adjusted_to_utc = 1;

        const carquet_logical_type_t *lt = NULL;
        if (ltype[c] == 1) lt = &date_lt;
        else if (ltype[c] == 2) lt = &timestamp_lt;
        else if (ltype[c] == 3) lt = &string_lt;
        carquet_field_repetition_t rep =
            nullable[c] ? CARQUET_REPETITION_OPTIONAL : CARQUET_REPETITION_REQUIRED;

        if (carquet_schema_add_column(schema, nm, (carquet_physical_type_t)ptype[c],
                                      lt, rep, 0, 0) != CARQUET_OK) {
            carquet_schema_free(schema);
            Rf_error("qio: failed to add column '%s' to schema", nm);
        }
    }

    carquet_writer_options_t wopts;
    carquet_writer_options_init(&wopts);
    wopts.compression = codec;

    carquet_writer_t *writer = carquet_writer_create(path, schema, &wopts, &err);
    if (!writer) {
        carquet_schema_free(schema);
        Rf_error("qio: cannot create '%s': %s", path, err.message);
    }

    int64_t n = (int64_t)nrow;
    char errmsg[128];
    errmsg[0] = '\0';

    for (int c = 0; c < ncol && errmsg[0] == '\0'; c++) {
        void *vmax = vmaxget();
        SEXP v = VECTOR_ELT(cols, c);
        int16_t *def = nullable[c] ? (int16_t *)R_alloc(nrow, sizeof(int16_t)) : NULL;
        R_xlen_t i, k = 0;
        carquet_status_t st = CARQUET_OK;

        if (ltype[c] == 1) {
            /* Date stores days since 1970-01-01; write them as INT32. */
            int32_t *buf = (int32_t *)R_alloc(nrow, sizeof(int32_t));
            double *p = REAL(v);
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) {
                    buf[k++] = (int32_t)round(p[i]);
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
        } else if (ltype[c] == 2) {
            /* POSIXct stores UTC seconds; rescale to the requested unit. */
            int64_t *buf = (int64_t *)R_alloc(nrow, sizeof(int64_t));
            double *p = REAL(v);
            double scale = time_unit[c] == 1 ? 1e3 :
                           time_unit[c] == 2 ? 1e6 : 1e9;
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) {
                    buf[k++] = (int64_t)llround(p[i] * scale);
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
        } else switch (ptype[c]) {
        case CARQUET_PHYSICAL_BOOLEAN: {
            uint8_t *buf = (uint8_t *)R_alloc(nrow, 1);
            int *p = LOGICAL(v);
            for (i = 0; i < nrow; i++) {
                if (p[i] != NA_LOGICAL) { buf[k++] = p[i] ? 1 : 0; if (def) def[i] = 1; }
                else if (def) def[i] = 0;
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
            break;
        }
        case CARQUET_PHYSICAL_INT32: {
            int32_t *buf = (int32_t *)R_alloc(nrow, sizeof(int32_t));
            int *p = INTEGER(v);
            for (i = 0; i < nrow; i++) {
                if (p[i] != NA_INTEGER) { buf[k++] = p[i]; if (def) def[i] = 1; }
                else if (def) def[i] = 0;
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
            break;
        }
        case CARQUET_PHYSICAL_INT64: {
            int64_t *buf = (int64_t *)R_alloc(nrow, sizeof(int64_t));
            double *p = REAL(v);
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) { buf[k++] = (int64_t)llround(p[i]); if (def) def[i] = 1; }
                else if (def) def[i] = 0;
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
            break;
        }
        case CARQUET_PHYSICAL_FLOAT: {
            float *buf = (float *)R_alloc(nrow, sizeof(float));
            double *p = REAL(v);
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) { buf[k++] = (float)p[i]; if (def) def[i] = 1; }
                else if (def) def[i] = 0;
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
            break;
        }
        case CARQUET_PHYSICAL_DOUBLE: {
            double *buf = (double *)R_alloc(nrow, sizeof(double));
            double *p = REAL(v);
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) { buf[k++] = p[i]; if (def) def[i] = 1; }
                else if (def) def[i] = 0;
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
            break;
        }
        case CARQUET_PHYSICAL_BYTE_ARRAY: {
            carquet_byte_array_t *buf =
                (carquet_byte_array_t *)R_alloc(nrow, sizeof(carquet_byte_array_t));
            /* R_alloc does not zero. Present values are packed densely into
             * [0, k); the null tail [k, nrow) is never filled, but carquet's
             * batch-size estimate scans all nrow entries and reads
             * arrays[i].length. Zero the buffer so those reads are defined
             * (length 0) instead of garbage — uninitialized bytes are benign
             * on some allocators but corrupt the estimate on others (x86). */
            memset(buf, 0, (size_t)nrow * sizeof(carquet_byte_array_t));
            for (i = 0; i < nrow; i++) {
                SEXP e = STRING_ELT(v, i);
                if (e != NA_STRING) {
                    const char *s = Rf_translateCharUTF8(e);
                    buf[k].data = (uint8_t *)s;
                    buf[k].length = (int32_t)strlen(s);
                    k++;
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            st = carquet_writer_write_batch(writer, c, buf, n, def, NULL);
            break;
        }
        default:
            break;
        }

        if (st != CARQUET_OK)
            snprintf(errmsg, sizeof(errmsg), "failed to write column %d", c + 1);
        vmaxset(vmax);
    }

    if (errmsg[0] != '\0') {
        carquet_writer_abort(writer);
        carquet_schema_free(schema);
        Rf_error("qio: %s", errmsg);
    }

    if (carquet_writer_close(writer) != CARQUET_OK) {
        carquet_schema_free(schema);
        Rf_error("qio: failed to finalize '%s'", path);
    }
    carquet_schema_free(schema);

    return path_sexp;
}

/* ------------------------------------------------------------------------- */
/* Registration                                                              */
/* ------------------------------------------------------------------------- */

static const R_CallMethodDef CallEntries[] = {
    {"qio_read_parquet",  (DL_FUNC)&qio_read_parquet,  1},
    {"qio_write_parquet", (DL_FUNC)&qio_write_parquet, 4},
    {"qio_parquet_open", (DL_FUNC)&qio_parquet_open, 4},
    {"qio_parquet_close", (DL_FUNC)&qio_parquet_close, 1},
    {"qio_parquet_is_open", (DL_FUNC)&qio_parquet_is_open, 1},
    {"qio_parquet_path", (DL_FUNC)&qio_parquet_path, 1},
    {"qio_parquet_dim", (DL_FUNC)&qio_parquet_dim, 1},
    {"qio_parquet_names", (DL_FUNC)&qio_parquet_names, 1},
    {"qio_parquet_schema", (DL_FUNC)&qio_parquet_schema, 1},
    {"qio_parquet_row_groups", (DL_FUNC)&qio_parquet_row_groups, 1},
    {"qio_parquet_metadata", (DL_FUNC)&qio_parquet_metadata, 1},
    {"qio_parquet_collect", (DL_FUNC)&qio_parquet_collect, 4},
    {"qio_parquet_walk", (DL_FUNC)&qio_parquet_walk, 5},
    {NULL, NULL, 0}
};

void R_init_qio(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
