/*
 * qio.c — R -> carquet glue for writing Parquet files.
 *
 * Exposes one .Call entry point:
 *   qio_write_parquet(x, path, codec, schema, row_group, metadata)
 *       -> invisible(path)
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
#include "qio_path.h"

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
    /* qio opens the output itself so a path outside Windows' active code page
     * still works; see qio_path.h. That makes qio, not carquet, responsible
     * for closing the stream and for removing a half-written file. */
    FILE *file;
    int finished; /* the file is complete and must survive cleanup */
    /* Appending writes into a file that already holds the user's data. The
     * cleanup below removes a failed write, which for an append would destroy
     * exactly what it was meant to add to, so it must never fire here. */
    int append;
    SEXP x;
    SEXP path_sexp;
    SEXP nms;
    SEXP meta_keys;   /* character, or R_NilValue */
    SEXP meta_values; /* character, same length as meta_keys */
    /* Declared sort order: parallel vectors of 0-based leaf index, descending
     * flag, and nulls-first flag. R_NilValue when nothing was declared. */
    SEXP sort_columns;
    SEXP sort_descending;
    SEXP sort_nulls_first;
    qio_path_t path;
    carquet_compression_t codec;
    int ncol;
    R_xlen_t nrow;
    R_xlen_t row_group_rows; /* 0 means one row group for the whole frame */
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
    /* abort() only deletes a file it opened itself, and this one was opened
     * here, so removing a partial write is qio's job. Nothing below calls back
     * into R: the path was resolved into every form it needs before the
     * protected window began, precisely so an unwind cannot longjmp again. */
    if (ctx->file) {
        fclose(ctx->file);
        ctx->file = NULL;
    }
    /* Only a file this call created may be removed. An append failure leaves
     * the original alone: carquet's abort closes it without truncating, and
     * the footer it did not rewrite still describes the original row groups. */
    if (!ctx->finished && !ctx->append) {
        qio_path_remove(&ctx->path);
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

    if (ctx->append) {
        /* carquet reopens the path itself for append, so there is no stream to
         * hand it and no FILE* for qio to own. That also means an append needs
         * a path the byte interface can express, which on Windows is not every
         * path; say so rather than fail inside the open. */
        if (!qio_path_opens_natively(&ctx->path)) {
            Rf_error("qio: cannot append to '%s': appending needs a path the "
                     "system's active code page can represent",
                     ctx->path.display);
        }
        ctx->writer = carquet_writer_open_append(ctx->path.native, ctx->schema,
                                                 &wopts, &err);
        if (!ctx->writer) {
            Rf_error("qio: cannot append to '%s': %s", ctx->path.display,
                     err.message);
        }
    } else {
        /* Opened here rather than by carquet so that a path outside Windows'
         * active code page still works; see qio_path.h. */
        ctx->file = qio_path_fopen(&ctx->path, "wb");
        if (!ctx->file) {
            Rf_error("qio: cannot create '%s'", ctx->path.display);
        }
        ctx->writer =
            carquet_writer_create_file(ctx->file, ctx->schema, &wopts, &err);
        if (!ctx->writer) {
            Rf_error("qio: cannot create '%s': %s", ctx->path.display,
                     err.message);
        }
    }

    /* Footer key/value metadata, added before any data so a failure costs
     * nothing. Keys and values are written as UTF-8; carquet copies both. */
    if (ctx->meta_keys != R_NilValue) {
        R_xlen_t entries = XLENGTH(ctx->meta_keys);
        for (R_xlen_t m = 0; m < entries; m++) {
            void *vmax_entry = vmaxget();
            const char *key = Rf_translateCharUTF8(STRING_ELT(ctx->meta_keys, m));
            SEXP value_elt = STRING_ELT(ctx->meta_values, m);
            /* NA is not a value; carquet accepts NULL and writes an empty one. */
            const char *value = value_elt == NA_STRING
                                    ? NULL
                                    : Rf_translateCharUTF8(value_elt);
            carquet_status_t added =
                carquet_writer_add_metadata(ctx->writer, key, value);
            if (added != CARQUET_OK) {
                Rf_error("qio: failed to add metadata key '%s': %s", key,
                         carquet_status_string(added));
            }
            vmaxset(vmax_entry);
        }
    }

    /* A declared sort order is metadata only: carquet records it on every row
     * group and neither sorts nor verifies anything, which is also what
     * PyArrow does. qio validates the column names, not the data. */
    if (ctx->sort_columns != R_NilValue) {
        int32_t count = (int32_t)XLENGTH(ctx->sort_columns);
        carquet_sorting_column_t *order =
            (carquet_sorting_column_t *)R_alloc((size_t)(count > 0 ? count : 1),
                                                sizeof(carquet_sorting_column_t));
        for (int32_t i = 0; i < count; i++) {
            order[i].column_index = INTEGER(ctx->sort_columns)[i];
            order[i].descending = LOGICAL(ctx->sort_descending)[i] == TRUE;
            order[i].nulls_first = LOGICAL(ctx->sort_nulls_first)[i] == TRUE;
        }
        carquet_status_t declared =
            carquet_writer_set_sorting_columns(ctx->writer, order, count);
        if (declared != CARQUET_OK) {
            Rf_error("qio: failed to declare the sort order: %s",
                     carquet_status_string(declared));
        }
    }

    /* Rows moved per carquet_writer_write_batch() call. Bounds the scratch a
     * write allocates and gives interrupts somewhere to land: a column used to
     * be encoded in one pass, so a large frame allocated nrow-sized buffers per
     * column and could not be interrupted at all.
     *
     * This needs every encoding to resume correctly across batches. Two did
     * not, and both are fixed in the vendored tree: BYTE_STREAM_SPLIT split
     * each call separately, and BOOLEAN bit packing restarted at each call.
     * See .agents/VENDORED.md. */
#define QIO_WRITE_CHUNK 65536

    /* Row groups are the unit other readers prune on, so they are written
     * row-group-major: every column advances through one group before the next
     * begins. carquet requires all columns to sit at the same logical row
     * before a group ends, and its own byte-target flush only fires when they
     * do, which under qio's column-at-a-time ordering means never until the
     * last column. An explicit boundary is the only way to get more than one.
     *
     * `row_group_rows` of 0 means one group for the whole frame, which is what
     * qio always produced before. */
    R_xlen_t group_rows = ctx->row_group_rows > 0 ? ctx->row_group_rows : nrow;
    if (group_rows < 1) group_rows = 1;
    R_xlen_t num_groups = (nrow + group_rows - 1) / group_rows;
    if (num_groups < 1) num_groups = 1; /* a zero-row frame still declares its columns */

    for (R_xlen_t group = 0; group < num_groups; group++) {
        R_xlen_t group_start = group * group_rows;
        R_xlen_t group_end = group_start + group_rows;
        if (group_end > nrow) group_end = nrow;

    for (int c = 0; c < ncol; c++) {
        void *vmax_column = vmaxget();
        SEXP v = VECTOR_ELT(ctx->x, c);
        R_xlen_t chunk = nrow < QIO_WRITE_CHUNK ? nrow : QIO_WRITE_CHUNK;
        if (chunk < 1) chunk = 1;

        /* Allocated once per column, outside the per-chunk vmax scope. */
        int16_t *def =
            nullable[c] ? (int16_t *)R_alloc(chunk, sizeof(int16_t)) : NULL;
        size_t width = sizeof(double);
        if (ptype[c] == CARQUET_PHYSICAL_BYTE_ARRAY) {
            width = sizeof(carquet_byte_array_t);
        }
        void *buf = R_alloc(chunk, (int)width);

        for (R_xlen_t row0 = group_start; row0 < group_end; row0 += chunk) {
            R_xlen_t len = group_end - row0;
            if (len > chunk) len = chunk;
            /* Translated strings live only for this chunk. */
            void *vmax_chunk = vmaxget();
            R_xlen_t i, k = 0;

            if (ltype[c] == 1) {
                /* Date stores days since 1970-01-01; write them as INT32. */
                int32_t *out = (int32_t *)buf;
                double *p = REAL(v) + row0;
                for (i = 0; i < len; i++) {
                    if (!R_IsNA(p[i])) {
                        out[k++] = (int32_t)round(p[i]);
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
            } else if (ltype[c] == 2) {
                /* POSIXct stores UTC seconds; rescale to the requested unit. */
                int64_t *out = (int64_t *)buf;
                double *p = REAL(v) + row0;
                double scale = time_unit[c] == 1 ? 1e3 :
                               time_unit[c] == 2 ? 1e6 : 1e9;
                for (i = 0; i < len; i++) {
                    if (!R_IsNA(p[i])) {
                        out[k++] = (int64_t)llround(p[i] * scale);
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
            } else switch (ptype[c]) {
            case CARQUET_PHYSICAL_BOOLEAN: {
                uint8_t *out = (uint8_t *)buf;
                int *p = LOGICAL(v) + row0;
                for (i = 0; i < len; i++) {
                    if (p[i] != NA_LOGICAL) {
                        out[k++] = p[i] ? 1 : 0;
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
                break;
            }
            case CARQUET_PHYSICAL_INT32: {
                int32_t *out = (int32_t *)buf;
                int *p = INTEGER(v) + row0;
                for (i = 0; i < len; i++) {
                    if (p[i] != NA_INTEGER) {
                        out[k++] = p[i];
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
                break;
            }
            case CARQUET_PHYSICAL_INT64: {
                int64_t *out = (int64_t *)buf;
                double *p = REAL(v) + row0;
                for (i = 0; i < len; i++) {
                    if (!R_IsNA(p[i])) {
                        out[k++] = (int64_t)llround(p[i]);
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
                break;
            }
            case CARQUET_PHYSICAL_FLOAT: {
                float *out = (float *)buf;
                double *p = REAL(v) + row0;
                for (i = 0; i < len; i++) {
                    if (!R_IsNA(p[i])) {
                        out[k++] = (float)p[i];
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
                break;
            }
            case CARQUET_PHYSICAL_DOUBLE: {
                double *out = (double *)buf;
                double *p = REAL(v) + row0;
                for (i = 0; i < len; i++) {
                    if (!R_IsNA(p[i])) {
                        out[k++] = p[i];
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
                break;
            }
            case CARQUET_PHYSICAL_BYTE_ARRAY: {
                carquet_byte_array_t *out = (carquet_byte_array_t *)buf;
                /* R_alloc does not zero. Present values pack densely into
                 * [0, k); the null tail is never filled, but carquet's
                 * batch-size estimate scans every entry and reads
                 * arrays[i].length. Zero it so those reads are defined. */
                memset(out, 0, (size_t)len * sizeof(carquet_byte_array_t));
                for (i = 0; i < len; i++) {
                    SEXP e = STRING_ELT(v, row0 + i);
                    if (e != NA_STRING) {
                        const char *str = Rf_translateCharUTF8(e);
                        out[k].data = (uint8_t *)str;
                        out[k].length = (int32_t)strlen(str);
                        k++;
                        if (def) def[i] = 1;
                    } else if (def) {
                        def[i] = 0;
                    }
                }
                break;
            }
            default:
                Rf_error("qio: invalid physical type for column %d", c + 1);
            }

            /* A REQUIRED column carries no definition levels, so carquet reads
             * all `len` values from the dense buffer. Any skipped NA would
             * leave that tail uninitialized. R rejects this combination before
             * we get here; this is the C-side backstop. */
            if (!def && k != len) {
                Rf_error(
                    "qio: column %d is REQUIRED but contains missing values",
                    c + 1);
            }

            carquet_status_t written = carquet_writer_write_batch(
                ctx->writer, c, buf, (int64_t)len, def, NULL);
            if (written != CARQUET_OK) {
                Rf_error("qio: failed to write column %d at row %lld: %s",
                         c + 1, (long long)row0 + 1,
                         carquet_status_string(written));
            }
            vmaxset(vmax_chunk);
            R_CheckUserInterrupt();
        }
        vmaxset(vmax_column);
    }

        /* Closed only between groups: close() finalizes the last one, and an
         * empty trailing group would otherwise appear in the footer. */
        if (group + 1 < num_groups) {
            carquet_status_t boundary =
                carquet_writer_new_row_group(ctx->writer);
            if (boundary != CARQUET_OK) {
                Rf_error("qio: failed to close row group %lld: %s",
                         (long long)group + 1,
                         carquet_status_string(boundary));
            }
        }
    }

    carquet_writer_t *writer = ctx->writer;
    ctx->writer = NULL;  /* close consumes the handle; never abort it after */
    if (carquet_writer_close(writer) != CARQUET_OK) {
        Rf_error("qio: failed to finalize '%s'", ctx->path.display);
    }

    /* The footer is written, so the file is complete: flush it and tell the
     * cleanup to leave it alone. A failure to flush still counts as a failed
     * write, and the cleanup then removes the file as it would for any other.
     * An append owns no stream; carquet closed its own. */
    if (ctx->file) {
        FILE *file = ctx->file;
        ctx->file = NULL;
        if (fclose(file) != 0) {
            Rf_error("qio: failed to finalize '%s'", ctx->path.display);
        }
    }
    ctx->finished = 1;

    carquet_schema_free(ctx->schema);
    ctx->schema = NULL;
    return ctx->path_sexp;
}

SEXP qio_write_parquet(SEXP x, SEXP path_sexp, SEXP codec_sexp, SEXP spec_sexp,
                       SEXP row_group_sexp, SEXP meta_sexp,
                       SEXP sort_sexp, SEXP append_sexp) {
    if (TYPEOF(x) != VECSXP)
        Rf_error("qio: `x` must be a data.frame");
    if (TYPEOF(path_sexp) != STRSXP || LENGTH(path_sexp) < 1)
        Rf_error("qio: `file` must be a single path");
    if (TYPEOF(codec_sexp) != STRSXP || LENGTH(codec_sexp) < 1)
        Rf_error("qio: `compression` must be a string");
    if (TYPEOF(spec_sexp) != VECSXP || LENGTH(spec_sexp) != 4)
        Rf_error("qio: invalid writer schema");

    /* Resolved here, before the protected window: it calls into R, which the
     * cleanup running under an unwind must not. */
    qio_path_t path;
    qio_path_resolve(path_sexp, &path);

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

    /* R has already validated and normalized both of these; the checks here
     * guard the native contract, not the user. */
    R_xlen_t row_group_rows = 0;
    if (row_group_sexp != R_NilValue) {
        double requested = Rf_asReal(row_group_sexp);
        if (!R_FINITE(requested) || requested < 1)
            Rf_error("qio: invalid `row_group_size`");
        row_group_rows = (R_xlen_t)requested;
    }

    SEXP meta_keys = R_NilValue;
    SEXP meta_values = R_NilValue;
    if (meta_sexp != R_NilValue) {
        if (TYPEOF(meta_sexp) != VECSXP || LENGTH(meta_sexp) != 2)
            Rf_error("qio: invalid `metadata`");
        meta_keys = VECTOR_ELT(meta_sexp, 0);
        meta_values = VECTOR_ELT(meta_sexp, 1);
        if (TYPEOF(meta_keys) != STRSXP || TYPEOF(meta_values) != STRSXP ||
            XLENGTH(meta_keys) != XLENGTH(meta_values))
            Rf_error("qio: invalid `metadata`");
    }

    SEXP sort_columns = R_NilValue;
    SEXP sort_descending = R_NilValue;
    SEXP sort_nulls_first = R_NilValue;
    if (sort_sexp != R_NilValue) {
        if (TYPEOF(sort_sexp) != VECSXP || LENGTH(sort_sexp) != 3)
            Rf_error("qio: invalid `sorted_by`");
        sort_columns = VECTOR_ELT(sort_sexp, 0);
        sort_descending = VECTOR_ELT(sort_sexp, 1);
        sort_nulls_first = VECTOR_ELT(sort_sexp, 2);
        if (TYPEOF(sort_columns) != INTSXP ||
            TYPEOF(sort_descending) != LGLSXP ||
            TYPEOF(sort_nulls_first) != LGLSXP ||
            XLENGTH(sort_columns) != XLENGTH(sort_descending) ||
            XLENGTH(sort_columns) != XLENGTH(sort_nulls_first))
            Rf_error("qio: invalid `sorted_by`");
        for (R_xlen_t i = 0; i < XLENGTH(sort_columns); i++) {
            int index = INTEGER(sort_columns)[i];
            if (index == NA_INTEGER || index < 0 || index >= ncol)
                Rf_error("qio: invalid `sorted_by` column");
        }
    }

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
    ctx.meta_keys = meta_keys;
    ctx.meta_values = meta_values;
    ctx.sort_columns = sort_columns;
    ctx.sort_descending = sort_descending;
    ctx.sort_nulls_first = sort_nulls_first;
    ctx.append = Rf_asLogical(append_sexp) == TRUE;
    ctx.path = path;
    ctx.codec = codec;
    ctx.ncol = ncol;
    ctx.nrow = nrow;
    ctx.row_group_rows = row_group_rows;
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
    {"qio_write_parquet", (DL_FUNC)&qio_write_parquet, 8},
    {"qio_parquet_open", (DL_FUNC)&qio_parquet_open, 4},
    {"qio_parquet_close", (DL_FUNC)&qio_parquet_close, 1},
    {"qio_parquet_is_open", (DL_FUNC)&qio_parquet_is_open, 1},
    {"qio_parquet_path", (DL_FUNC)&qio_parquet_path, 1},
    {"qio_parquet_dim", (DL_FUNC)&qio_parquet_dim, 1},
    {"qio_parquet_names", (DL_FUNC)&qio_parquet_names, 1},
    {"qio_parquet_schema", (DL_FUNC)&qio_parquet_schema, 1},
    {"qio_parquet_row_groups", (DL_FUNC)&qio_parquet_row_groups, 1},
    {"qio_parquet_metadata", (DL_FUNC)&qio_parquet_metadata, 1},
    {"qio_parquet_column_chunks", (DL_FUNC)&qio_parquet_column_chunks, 1},
    {"qio_parquet_column_statistics", (DL_FUNC)&qio_parquet_column_statistics, 1},
    {"qio_parquet_page_index", (DL_FUNC)&qio_parquet_page_index, 1},
    {"qio_parquet_bloom_check", (DL_FUNC)&qio_parquet_bloom_check, 4},
    {"qio_parquet_collect", (DL_FUNC)&qio_parquet_collect, 6},
    {"qio_parquet_walk", (DL_FUNC)&qio_parquet_walk, 7},
    {NULL, NULL, 0}
};

void R_init_qio(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
