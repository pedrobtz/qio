/*
 * qio.c — R -> carquet glue for writing Parquet files.
 *
 * Exposes one .Call entry point:
 *   qio_write_parquet(x, path, codec, schema) -> invisible(path)
 *
 * The read path lives in qio_file.c (the persistent handle and its collect /
 * walk / metadata entry points); read_parquet() is parquet_open() + collect().
 *
 * Type mapping (flat schemas only):
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
/* Write                                                                     */
/* ------------------------------------------------------------------------- */

/* Native resources that must be released if anything between
 * carquet_writer_create() and carquet_writer_close() jumps. Two R calls inside
 * that window can: Rf_translateCharUTF8() on a string it cannot translate, and
 * R_alloc() on allocation failure. Without this, the writer and schema leak and
 * a truncated file is left behind. */
typedef struct {
    carquet_schema_t *schema;
    carquet_writer_t *writer;  /* NULL once close() has consumed it */
    SEXP x;
    SEXP path_sexp;
    SEXP nms;
    const char *path;
    carquet_compression_t codec;
    int ncol;
    R_xlen_t nrow;
    const int *ptype;
    const int *ltype;
    const int *time_unit;
    const int *nullable;
} qio_write_context_t;

static void qio_write_cleanup(void *data, Rboolean jump) {
    (void)jump;
    qio_write_context_t *ctx = (qio_write_context_t *)data;
    /* carquet_writer_close() invalidates the handle, so the success path clears
     * `writer` first; anything still here failed or never finished. */
    if (ctx->writer) {
        carquet_writer_abort(ctx->writer);
        ctx->writer = NULL;
    }
    if (ctx->schema) {
        carquet_schema_free(ctx->schema);
        ctx->schema = NULL;
    }
}

static SEXP qio_write_body(void *data) {
    qio_write_context_t *ctx = (qio_write_context_t *)data;
    const int *ptype = ctx->ptype;
    const int *ltype = ctx->ltype;
    const int *time_unit = ctx->time_unit;
    const int *nullable = ctx->nullable;
    R_xlen_t nrow = ctx->nrow;
    int ncol = ctx->ncol;

    carquet_error_t err = CARQUET_ERROR_INIT;
    ctx->schema = carquet_schema_create(&err);
    if (!ctx->schema) {
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
        if (ctx->nms != R_NilValue &&
            STRING_ELT(ctx->nms, c) != NA_STRING &&
            CHAR(STRING_ELT(ctx->nms, c))[0] != '\0') {
            nm = Rf_translateCharUTF8(STRING_ELT(ctx->nms, c));
        } else {
            snprintf(namebuf, sizeof(namebuf), "V%d", c + 1);
            nm = namebuf;
        }
        carquet_logical_type_t timestamp_lt;
        memset(&timestamp_lt, 0, sizeof(timestamp_lt));
        timestamp_lt.id = CARQUET_LOGICAL_TIMESTAMP;
        timestamp_lt.params.timestamp.unit =
            (carquet_time_unit_t)(time_unit[c] - 1);
        timestamp_lt.params.timestamp.is_adjusted_to_utc = 1;

        const carquet_logical_type_t *lt = NULL;
        if (ltype[c] == 1) lt = &date_lt;
        else if (ltype[c] == 2) lt = &timestamp_lt;
        else if (ltype[c] == 3) lt = &string_lt;
        carquet_field_repetition_t rep =
            nullable[c] ? CARQUET_REPETITION_OPTIONAL
                        : CARQUET_REPETITION_REQUIRED;

        if (carquet_schema_add_column(ctx->schema, nm,
                                      (carquet_physical_type_t)ptype[c],
                                      lt, rep, 0, 0) != CARQUET_OK) {
            Rf_error("qio: failed to add column '%s' to schema", nm);
        }
    }

    carquet_writer_options_t wopts;
    carquet_writer_options_init(&wopts);
    wopts.compression = ctx->codec;

    ctx->writer = carquet_writer_create(ctx->path, ctx->schema, &wopts, &err);
    if (!ctx->writer) {
        Rf_error("qio: cannot create '%s': %s", ctx->path, err.message);
    }

    /* Force PLAIN for FLOAT and DOUBLE.
     *
     * With a compression codec set, carquet picks BYTE_STREAM_SPLIT for these
     * types, and its encoder is wrong for any page whose values arrive in more
     * than one call: BYTE_STREAM_SPLIT transposes a whole page into byte
     * planes, but encode_double_values() splits each call's subrange on its own
     * and appends, so the decoder de-splits the concatenation as one stride and
     * every value comes back wrong. It silently corrupted nullable double
     * columns past about a megabyte of present values -- the default write
     * path. See .agents/VENDORED.md.
     *
     * PLAIN costs compression ratio on float columns and nothing else. Revert
     * this once the encoder is fixed upstream. */
    for (int c = 0; c < ncol; c++) {
        if (ptype[c] != CARQUET_PHYSICAL_FLOAT &&
            ptype[c] != CARQUET_PHYSICAL_DOUBLE) {
            continue;
        }
        if (carquet_writer_set_column_encoding(ctx->writer, c,
                                               CARQUET_ENCODING_PLAIN) !=
            CARQUET_OK) {
            Rf_error("qio: cannot set PLAIN encoding for column %d", c + 1);
        }
    }

    int64_t n = (int64_t)nrow;

    for (int c = 0; c < ncol; c++) {
        void *vmax = vmaxget();
        SEXP v = VECTOR_ELT(ctx->x, c);
        int16_t *def =
            nullable[c] ? (int16_t *)R_alloc(nrow, sizeof(int16_t)) : NULL;
        R_xlen_t i, k = 0;
        const void *out = NULL;

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
            out = buf;
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
            out = buf;
        } else switch (ptype[c]) {
        case CARQUET_PHYSICAL_BOOLEAN: {
            uint8_t *buf = (uint8_t *)R_alloc(nrow, 1);
            int *p = LOGICAL(v);
            for (i = 0; i < nrow; i++) {
                if (p[i] != NA_LOGICAL) {
                    buf[k++] = p[i] ? 1 : 0;
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            out = buf;
            break;
        }
        case CARQUET_PHYSICAL_INT32: {
            int32_t *buf = (int32_t *)R_alloc(nrow, sizeof(int32_t));
            int *p = INTEGER(v);
            for (i = 0; i < nrow; i++) {
                if (p[i] != NA_INTEGER) {
                    buf[k++] = p[i];
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            out = buf;
            break;
        }
        case CARQUET_PHYSICAL_INT64: {
            int64_t *buf = (int64_t *)R_alloc(nrow, sizeof(int64_t));
            double *p = REAL(v);
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) {
                    buf[k++] = (int64_t)llround(p[i]);
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            out = buf;
            break;
        }
        case CARQUET_PHYSICAL_FLOAT: {
            float *buf = (float *)R_alloc(nrow, sizeof(float));
            double *p = REAL(v);
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) {
                    buf[k++] = (float)p[i];
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            out = buf;
            break;
        }
        case CARQUET_PHYSICAL_DOUBLE: {
            double *buf = (double *)R_alloc(nrow, sizeof(double));
            double *p = REAL(v);
            for (i = 0; i < nrow; i++) {
                if (!R_IsNA(p[i])) {
                    buf[k++] = p[i];
                    if (def) def[i] = 1;
                } else if (def) {
                    def[i] = 0;
                }
            }
            out = buf;
            break;
        }
        case CARQUET_PHYSICAL_BYTE_ARRAY: {
            carquet_byte_array_t *buf = (carquet_byte_array_t *)R_alloc(
                nrow, sizeof(carquet_byte_array_t));
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
            out = buf;
            break;
        }
        default:
            Rf_error("qio: invalid physical type for column %d", c + 1);
        }

        /* A REQUIRED column carries no definition levels, so carquet reads all
         * `n` values from the dense buffer. Any skipped NA would leave that
         * tail uninitialized. R rejects this combination before we get here;
         * this is the C-side backstop the validation comment above promises. */
        if (!def && k != nrow) {
            Rf_error("qio: column %d is REQUIRED but contains missing values",
                     c + 1);
        }

        carquet_status_t written =
            carquet_writer_write_batch(ctx->writer, c, out, n, def, NULL);
        if (written != CARQUET_OK) {
            Rf_error("qio: failed to write column %d: %s", c + 1,
                     carquet_status_string(written));
        }
        vmaxset(vmax);
    }

    carquet_writer_t *writer = ctx->writer;
    ctx->writer = NULL;  /* close consumes the handle; never abort it after */
    if (carquet_writer_close(writer) != CARQUET_OK) {
        Rf_error("qio: failed to finalize '%s'", ctx->path);
    }

    carquet_schema_free(ctx->schema);
    ctx->schema = NULL;
    return ctx->path_sexp;
}

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
     * schema. Check storage types again before any output file is created; the
     * REQUIRED/NA invariant is re-checked per column in qio_write_body(), where
     * the null count is known. */
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

    qio_write_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.x = x;
    ctx.path_sexp = path_sexp;
    ctx.nms = nms;
    ctx.path = path;
    ctx.codec = codec;
    ctx.ncol = ncol;
    ctx.nrow = nrow;
    ctx.ptype = ptype;
    ctx.ltype = ltype;
    ctx.time_unit = time_unit;
    ctx.nullable = nullable;

    SEXP continuation = PROTECT(R_MakeUnwindCont());
    SEXP result = R_UnwindProtect(qio_write_body, &ctx,
                                  qio_write_cleanup, &ctx,
                                  continuation);
    UNPROTECT(1);
    return result;
}

/* ------------------------------------------------------------------------- */
/* Registration                                                              */
/* ------------------------------------------------------------------------- */

static const R_CallMethodDef CallEntries[] = {
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
    {"qio_parquet_collect", (DL_FUNC)&qio_parquet_collect, 6},
    {"qio_parquet_walk", (DL_FUNC)&qio_parquet_walk, 7},
    {NULL, NULL, 0}
};

void R_init_qio(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
