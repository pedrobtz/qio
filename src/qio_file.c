#include "qio_file.h"

#include <R.h>
#include <R_ext/Utils.h>
#include <Rinternals.h>

#include <carquet/carquet.h>
#include <reader/worker_pool.h>

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

typedef struct {
    carquet_reader_t *reader;
    int32_t threads;
    int busy;
} qio_parquet_handle_t;

typedef struct {
    int32_t *columns;
    int32_t num_columns;
    uint8_t *row_group_mask;
    int32_t num_row_groups;
    int filter_row_groups;
    int64_t total_rows;
} qio_selection_t;

typedef struct {
    const uint8_t *mask;
    int32_t length;
} qio_row_group_filter_t;

typedef struct {
    qio_parquet_handle_t *handle;
    qio_selection_t selection;
    int32_t batch_size;
    carquet_batch_reader_t *batch_reader;
    carquet_row_batch_t *batch;
    carquet_column_reader_t *column;  /* in-flight direct-read column reader */
    carquet_worker_pool_t *pool;      /* in-flight parallel-collect pool */
    SEXP file;
    SEXP callback;
    int int32_sentinel;               /* an INT32 -2147483648 became NA */
} qio_batch_context_t;

static SEXP qio_file_tag(void) {
    return Rf_install("qio_parquet_file");
}

static int qio_is_file_pointer(SEXP file) {
    return TYPEOF(file) == EXTPTRSXP &&
           R_ExternalPtrTag(file) == qio_file_tag();
}

static qio_parquet_handle_t *qio_get_handle(SEXP file, int allow_closed) {
    if (!qio_is_file_pointer(file)) {
        Rf_error("qio: `file` is not a qio parquet file handle");
    }

    qio_parquet_handle_t *handle =
        (qio_parquet_handle_t *)R_ExternalPtrAddr(file);
    if (!handle && !allow_closed) {
        Rf_error("qio: parquet file handle is closed or invalid");
    }
    return handle;
}

static void qio_finalize_file(SEXP file) {
    if (!qio_is_file_pointer(file)) return;

    qio_parquet_handle_t *handle =
        (qio_parquet_handle_t *)R_ExternalPtrAddr(file);
    if (!handle) return;

    if (handle->reader) {
        carquet_reader_close(handle->reader);
        handle->reader = NULL;
    }
    free(handle);
    R_ClearExternalPtr(file);
}

static const char *qio_time_unit_name(carquet_time_unit_t unit) {
    switch (unit) {
    case CARQUET_TIME_UNIT_MILLIS: return "MILLIS";
    case CARQUET_TIME_UNIT_MICROS: return "MICROS";
    case CARQUET_TIME_UNIT_NANOS: return "NANOS";
    default: return "UNKNOWN";
    }
}

static const char *qio_logical_type_name(carquet_logical_type_id_t type) {
    switch (type) {
    case CARQUET_LOGICAL_UNKNOWN: return "UNKNOWN";
    case CARQUET_LOGICAL_STRING: return "STRING";
    case CARQUET_LOGICAL_MAP: return "MAP";
    case CARQUET_LOGICAL_LIST: return "LIST";
    case CARQUET_LOGICAL_ENUM: return "ENUM";
    case CARQUET_LOGICAL_DECIMAL: return "DECIMAL";
    case CARQUET_LOGICAL_DATE: return "DATE";
    case CARQUET_LOGICAL_TIME: return "TIME";
    case CARQUET_LOGICAL_TIMESTAMP: return "TIMESTAMP";
    case CARQUET_LOGICAL_INTEGER: return "INTEGER";
    case CARQUET_LOGICAL_NULL: return "NULL";
    case CARQUET_LOGICAL_JSON: return "JSON";
    case CARQUET_LOGICAL_BSON: return "BSON";
    case CARQUET_LOGICAL_UUID: return "UUID";
    case CARQUET_LOGICAL_FLOAT16: return "FLOAT16";
    case CARQUET_LOGICAL_VARIANT: return "VARIANT";
    case CARQUET_LOGICAL_GEOMETRY: return "GEOMETRY";
    case CARQUET_LOGICAL_GEOGRAPHY: return "GEOGRAPHY";
    case CARQUET_LOGICAL_INTERVAL: return "INTERVAL";
    default: return "UNKNOWN";
    }
}

static const char *qio_repetition_name(carquet_field_repetition_t repetition) {
    switch (repetition) {
    case CARQUET_REPETITION_REQUIRED: return "REQUIRED";
    case CARQUET_REPETITION_OPTIONAL: return "OPTIONAL";
    case CARQUET_REPETITION_REPEATED: return "REPEATED";
    default: return "UNKNOWN";
    }
}

static const char *qio_edge_algorithm_name(
    carquet_geospatial_edge_algorithm_t algorithm) {
    switch (algorithm) {
    case CARQUET_GEOSPATIAL_EDGE_SPHERICAL: return "SPHERICAL";
    case CARQUET_GEOSPATIAL_EDGE_VINCENTY: return "VINCENTY";
    case CARQUET_GEOSPATIAL_EDGE_THOMAS: return "THOMAS";
    case CARQUET_GEOSPATIAL_EDGE_ANDOYER: return "ANDOYER";
    case CARQUET_GEOSPATIAL_EDGE_KARNEY: return "KARNEY";
    default: return "UNKNOWN";
    }
}

static int qio_logical_type_details(const carquet_logical_type_t *type,
                                    char *buffer, size_t size) {
    if (!type || !buffer || size == 0) return 0;

    switch (type->id) {
    case CARQUET_LOGICAL_DECIMAL:
        snprintf(buffer, size, "precision=%d, scale=%d",
                 type->params.decimal.precision, type->params.decimal.scale);
        return 1;
    case CARQUET_LOGICAL_INTEGER:
        snprintf(buffer, size, "bit_width=%d, signed=%s",
                 type->params.integer.bit_width,
                 type->params.integer.is_signed ? "true" : "false");
        return 1;
    case CARQUET_LOGICAL_TIME:
        snprintf(buffer, size, "unit=%s, adjusted_to_utc=%s",
                 qio_time_unit_name(type->params.time.unit),
                 type->params.time.is_adjusted_to_utc ? "true" : "false");
        return 1;
    case CARQUET_LOGICAL_TIMESTAMP:
        snprintf(buffer, size, "unit=%s, adjusted_to_utc=%s",
                 qio_time_unit_name(type->params.timestamp.unit),
                 type->params.timestamp.is_adjusted_to_utc ? "true" : "false");
        return 1;
    case CARQUET_LOGICAL_VARIANT:
        snprintf(buffer, size, "specification_version=%d",
                 type->params.variant.specification_version == 0
                     ? 1
                     : type->params.variant.specification_version);
        return 1;
    case CARQUET_LOGICAL_GEOMETRY:
        snprintf(buffer, size, "crs=%s",
                 type->params.geometry.crs[0]
                     ? type->params.geometry.crs
                     : "OGC:CRS84");
        return 1;
    case CARQUET_LOGICAL_GEOGRAPHY:
        snprintf(buffer, size, "crs=%s, algorithm=%s",
                 type->params.geography.crs[0]
                     ? type->params.geography.crs
                     : "OGC:CRS84",
                 type->params.geography.has_algorithm
                     ? qio_edge_algorithm_name(type->params.geography.algorithm)
                     : "SPHERICAL");
        return 1;
    default:
        return 0;
    }
}

/* Collect the leaf nodes in schema order, in one pass. Resolving each leaf
 * independently would rescan every element per leaf, making schema inspection
 * quadratic in schema size. Returns the number of leaves found, which the
 * caller must check against the reader's column count. */
static int32_t qio_leaf_nodes(const carquet_schema_t *schema,
                              const carquet_schema_node_t **leaves,
                              int32_t capacity) {
    int32_t seen = 0;
    int32_t elements = carquet_schema_num_elements(schema);
    for (int32_t i = 0; i < elements && seen < capacity; i++) {
        const carquet_schema_node_t *node =
            carquet_schema_get_element(schema, i);
        if (node && carquet_schema_node_is_leaf(node)) {
            leaves[seen++] = node;
        }
    }
    return seen;
}

static int32_t qio_column_path_parts(const carquet_schema_t *schema,
                                     int32_t leaf_index,
                                     const char ***parts_out) {
    int32_t max_depth = carquet_schema_num_elements(schema);
    if (max_depth < 1) max_depth = 1;
    const char **parts =
        (const char **)R_alloc((size_t)max_depth, sizeof(const char *));
    int32_t depth = carquet_schema_column_path(
        schema, leaf_index, parts, max_depth);
    *parts_out = parts;
    return depth;
}

static SEXP qio_column_path_string(const carquet_schema_t *schema,
                                   int32_t leaf_index) {
    const char **parts = NULL;
    int32_t depth = qio_column_path_parts(schema, leaf_index, &parts);
    if (depth <= 0) {
        const char *name = carquet_schema_column_name(schema, leaf_index);
        return Rf_mkCharCE(name ? name : "", CE_UTF8);
    }

    size_t length = 1;
    for (int32_t i = 0; i < depth; i++) {
        length += strlen(parts[i]);
        if (i + 1 < depth) length++;
    }
    char *path = (char *)R_alloc(length, sizeof(char));
    char *at = path;
    for (int32_t i = 0; i < depth; i++) {
        size_t n = strlen(parts[i]);
        memcpy(at, parts[i], n);
        at += n;
        if (i + 1 < depth) *at++ = '.';
    }
    *at = '\0';
    return Rf_mkCharCE(path, CE_UTF8);
}

static void qio_set_data_frame_attributes(SEXP data, SEXP names,
                                          R_xlen_t rows) {
    Rf_setAttrib(data, R_NamesSymbol, names);
    SEXP row_names;
    if (rows == 0) {
        row_names = PROTECT(Rf_allocVector(INTSXP, 0));
    } else {
        row_names = PROTECT(Rf_allocVector(INTSXP, 2));
        INTEGER(row_names)[0] = NA_INTEGER;
        INTEGER(row_names)[1] = -(int)rows;
    }
    Rf_setAttrib(data, R_RowNamesSymbol, row_names);
    Rf_setAttrib(data, R_ClassSymbol, Rf_mkString("data.frame"));
    UNPROTECT(1);
}

static int qio_value_present(const uint8_t *bitmap, int64_t index) {
    return !bitmap || (bitmap[index / 8] & (uint8_t)(1u << (index % 8)));
}

/* Convert a legacy INT96 timestamp to seconds since the Unix epoch, as UTC.
 * The Impala/Spark layout is int64 nanoseconds-of-day in words 0-1 and a Julian
 * day number in word 2; 2440588 is the Julian day of 1970-01-01. carquet has
 * already read the three words little-endian, so this is endian-safe. */
static double qio_int96_to_seconds(carquet_int96_t value) {
    uint64_t nanos = ((uint64_t)value.value[1] << 32) | (uint64_t)value.value[0];
    int64_t julian_day = (int64_t)(int32_t)value.value[2];
    int64_t days = julian_day - 2440588;
    return (double)days * 86400.0 + (double)nanos / 1e9;
}

/* Reject bytes R cannot hold in a CHARSXP before Rf_mkCharLenCE() raises its
 * own message, which names neither the column nor the row. */
static void qio_check_string_bytes(const carquet_byte_array_t *value,
                                   const char *column, int64_t row) {
    if (value->length < 0 || (value->length > 0 && value->data == NULL)) {
        Rf_error("qio: column '%s' returned an invalid byte array", column);
    }
    if (value->length > 0 &&
        memchr(value->data, '\0', (size_t)value->length) != NULL) {
        Rf_error("qio: column '%s' contains an embedded nul at row %lld; R "
                 "character vectors cannot represent it",
                 column, (long long)row + 1);
    }
}

static SEXP qio_allocate_column(carquet_physical_type_t type,
                                R_xlen_t length) {
    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN:
        return Rf_allocVector(LGLSXP, length);
    case CARQUET_PHYSICAL_INT32:
        return Rf_allocVector(INTSXP, length);
    case CARQUET_PHYSICAL_INT64:
    case CARQUET_PHYSICAL_INT96:
    case CARQUET_PHYSICAL_FLOAT:
    case CARQUET_PHYSICAL_DOUBLE:
        return Rf_allocVector(REALSXP, length);
    case CARQUET_PHYSICAL_BYTE_ARRAY:
        return Rf_allocVector(STRSXP, length);
    default:
        Rf_error("qio: unsupported physical type '%s'",
                 carquet_physical_type_name(type));
    }
    return R_NilValue;
}

static void qio_copy_batch_column(SEXP destination, R_xlen_t offset,
                                  carquet_physical_type_t type,
                                  const void *data, const uint8_t *bitmap,
                                  int64_t length, const char *column,
                                  int *sentinel) {
    for (int64_t i = 0; i < length; i++) {
        R_xlen_t out = offset + (R_xlen_t)i;
        if (!qio_value_present(bitmap, i)) {
            switch (type) {
            case CARQUET_PHYSICAL_BOOLEAN:
                LOGICAL(destination)[out] = NA_LOGICAL;
                break;
            case CARQUET_PHYSICAL_INT32:
                INTEGER(destination)[out] = NA_INTEGER;
                break;
            case CARQUET_PHYSICAL_INT64:
            case CARQUET_PHYSICAL_INT96:
            case CARQUET_PHYSICAL_FLOAT:
            case CARQUET_PHYSICAL_DOUBLE:
                REAL(destination)[out] = NA_REAL;
                break;
            case CARQUET_PHYSICAL_BYTE_ARRAY:
                SET_STRING_ELT(destination, out, NA_STRING);
                break;
            default:
                break;
            }
            continue;
        }

        switch (type) {
        case CARQUET_PHYSICAL_BOOLEAN:
            LOGICAL(destination)[out] = ((const uint8_t *)data)[i]
                                            ? TRUE
                                            : FALSE;
            break;
        case CARQUET_PHYSICAL_INT32: {
            /* See qio_scatter_numeric_raw: NA_INTEGER is INT_MIN. Here the
             * value is known present, so testing it directly is exact. */
            int32_t value = ((const int32_t *)data)[i];
            if (sentinel && value == NA_INTEGER) *sentinel = 1;
            INTEGER(destination)[out] = value;
            break;
        }
        case CARQUET_PHYSICAL_INT64:
            REAL(destination)[out] = (double)((const int64_t *)data)[i];
            break;
        case CARQUET_PHYSICAL_INT96:
            REAL(destination)[out] =
                qio_int96_to_seconds(((const carquet_int96_t *)data)[i]);
            break;
        case CARQUET_PHYSICAL_FLOAT:
            REAL(destination)[out] = (double)((const float *)data)[i];
            break;
        case CARQUET_PHYSICAL_DOUBLE:
            REAL(destination)[out] = ((const double *)data)[i];
            break;
        case CARQUET_PHYSICAL_BYTE_ARRAY: {
            const carquet_byte_array_t *value =
                &((const carquet_byte_array_t *)data)[i];
            qio_check_string_bytes(value, column, i);
            const char *bytes = value->length > 0
                                    ? (const char *)value->data
                                    : "";
            SET_STRING_ELT(destination, out,
                           Rf_mkCharLenCE(bytes, value->length, CE_UTF8));
            break;
        }
        default:
            break;
        }
    }
}

/* Scatter a column read directly from the carquet column API into an R vector.
 * Input is the Parquet-native dense layout: `values` holds only present values,
 * packed; `def_levels` (NULL for REQUIRED columns) gives the logical shape, with
 * def_levels[i] == max_def marking a present value. A single pass distributes
 * dense values to their logical rows and writes NA elsewhere — replacing the
 * batch reader's expand + null-bitmap passes and qio_copy_batch_column's scatter
 * with one loop. */
/* Emit one type-specialized scatter: a branch-free dense loop for REQUIRED
 * columns and a def-level-guarded loop for nullable ones. `dst` must be the
 * raw destination pointer already advanced by `offset` — the R accessor
 * (REAL/INTEGER/...) is called once per column, never per value. */
#define QIO_SCATTER_LOOP(SRC_T, dst, na_value, CONVERT)                        \
    do {                                                                       \
        const SRC_T *src = (const SRC_T *)values;                              \
        if (def_levels == NULL) {                                              \
            for (int64_t i = 0; i < length; i++) {                             \
                (dst)[i] = CONVERT(src[i]);                                    \
            }                                                                  \
        } else {                                                               \
            int64_t j = 0; /* cursor into the dense present-value stream */    \
            for (int64_t i = 0; i < length; i++) {                             \
                (dst)[i] = (def_levels[i] == max_def) ? CONVERT(src[j++])      \
                                                      : (na_value);            \
            }                                                                  \
        }                                                                      \
    } while (0)

#define QIO_CONVERT_IDENTITY(v) (v)
#define QIO_CONVERT_DOUBLE(v) ((double)(v))
#define QIO_CONVERT_BOOL(v) ((v) ? TRUE : FALSE)
#define QIO_CONVERT_INT96(v) (qio_int96_to_seconds(v))

/* Numeric scatter over raw destination memory. `dst_base` is the R vector's
 * data pointer (int* for BOOLEAN/INT32, double* otherwise), obtained on the
 * main thread; this function makes no R API calls, so it is safe to run on a
 * carquet worker thread (NA_* are constants/globals, only read). */
static void qio_scatter_numeric_raw(void *dst_base, R_xlen_t dst_offset,
                                    carquet_physical_type_t type,
                                    const void *values,
                                    const int16_t *def_levels,
                                    int16_t max_def, int64_t length,
                                    int *sentinel) {
    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN: {
        int *dst = (int *)dst_base + dst_offset;
        QIO_SCATTER_LOOP(uint8_t, dst, NA_LOGICAL, QIO_CONVERT_BOOL);
        break;
    }
    case CARQUET_PHYSICAL_INT32: {
        int *dst = (int *)dst_base + dst_offset;
        int64_t dense = length;
        if (def_levels == NULL) {
            memcpy(dst, values, (size_t)length * sizeof(int32_t));
        } else {
            const int32_t *src = (const int32_t *)values;
            int64_t j = 0;
            for (int64_t i = 0; i < length; i++) {
                dst[i] = (def_levels[i] == max_def) ? src[j++] : NA_INTEGER;
            }
            dense = j;
        }
        /* R's NA_INTEGER is INT_MIN, so a stored -2147483648 becomes NA and is
         * then indistinguishable from a real null. Scan the dense source (never
         * the destination, where nulls also read as NA_INTEGER) and record the
         * substitution for one warning per operation; see TYPES.md. */
        if (sentinel && !*sentinel) {
            const int32_t *src = (const int32_t *)values;
            for (int64_t i = 0; i < dense; i++) {
                if (src[i] == NA_INTEGER) {
                    *sentinel = 1;
                    break;
                }
            }
        }
        break;
    }
    case CARQUET_PHYSICAL_INT64: {
        double *dst = (double *)dst_base + dst_offset;
        QIO_SCATTER_LOOP(int64_t, dst, NA_REAL, QIO_CONVERT_DOUBLE);
        break;
    }
    case CARQUET_PHYSICAL_INT96: {
        double *dst = (double *)dst_base + dst_offset;
        QIO_SCATTER_LOOP(carquet_int96_t, dst, NA_REAL, QIO_CONVERT_INT96);
        break;
    }
    case CARQUET_PHYSICAL_FLOAT: {
        double *dst = (double *)dst_base + dst_offset;
        QIO_SCATTER_LOOP(float, dst, NA_REAL, QIO_CONVERT_DOUBLE);
        break;
    }
    case CARQUET_PHYSICAL_DOUBLE: {
        double *dst = (double *)dst_base + dst_offset;
        if (def_levels == NULL) {
            memcpy(dst, values, (size_t)length * sizeof(double));
        } else {
            QIO_SCATTER_LOOP(double, dst, NA_REAL, QIO_CONVERT_IDENTITY);
        }
        break;
    }
    default:
        break;
    }
}

/* Raw data pointer for a numeric destination vector (main thread only). */
static void *qio_column_data_pointer(SEXP destination,
                                     carquet_physical_type_t type) {
    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN:
        return LOGICAL(destination);
    case CARQUET_PHYSICAL_INT32:
        return INTEGER(destination);
    default:
        return REAL(destination);
    }
}

static void qio_scatter_dense_column(SEXP destination, R_xlen_t offset,
                                     carquet_physical_type_t type,
                                     const void *values,
                                     const int16_t *def_levels,
                                     int16_t max_def, int64_t length,
                                     const char *column, int *sentinel) {
    switch (type) {
    case CARQUET_PHYSICAL_BYTE_ARRAY: {
        /* Strings must go through SET_STRING_ELT (write barrier) and
         * Rf_mkCharLenCE (interning); only the null branch can be hoisted. */
        const carquet_byte_array_t *src =
            (const carquet_byte_array_t *)values;
        int64_t j = 0;
        for (int64_t i = 0; i < length; i++) {
            R_xlen_t out = offset + (R_xlen_t)i;
            if (def_levels != NULL && def_levels[i] != max_def) {
                SET_STRING_ELT(destination, out, NA_STRING);
                continue;
            }
            const carquet_byte_array_t *value = &src[j++];
            qio_check_string_bytes(value, column, i);
            const char *bytes = value->length > 0
                                    ? (const char *)value->data
                                    : "";
            SET_STRING_ELT(destination, out,
                           Rf_mkCharLenCE(bytes, value->length, CE_UTF8));
        }
        break;
    }
    default:
        qio_scatter_numeric_raw(qio_column_data_pointer(destination, type),
                                offset, type, values, def_levels, max_def,
                                length, sentinel);
        break;
    }
}

/* ============================================================================
 * Parallel collect: one task per (row group x numeric column)
 * ============================================================================
 *
 * Worker tasks run carquet decode into private malloc'd scratch and scatter
 * into pre-allocated R vector memory through raw pointers — no R API calls.
 * They are only dispatched when the reader is memory-mapped: the fread path
 * shares FILE-handle and prebuffer state across column readers and is not
 * thread-safe.
 * BYTE_ARRAY columns stay on the main thread (string interning and the write
 * barrier are R API). Errors are recorded in the task and raised on the main
 * thread after carquet_worker_pool_wait().
 */

#define QIO_TASK_BATCH 65536

typedef struct {
    carquet_reader_t *reader;
    int32_t row_group;
    int32_t file_column;
    carquet_physical_type_t type;
    int16_t max_def;
    void *dst;           /* raw R vector data pointer (int* or double*) */
    R_xlen_t dst_offset; /* first row of this row group in the result */
    int64_t rows;        /* rows in this row group */
    int status;          /* 0 = ok; set to 1 on failure */
    int int32_sentinel;  /* task-local; merged on the main thread after wait */
    char message[256];
} qio_column_task_t;

static void qio_column_task_run(void *arg) {
    qio_column_task_t *task = (qio_column_task_t *)arg;
    carquet_error_t err = CARQUET_ERROR_INIT;
    carquet_column_reader_t *column = carquet_reader_get_column(
        task->reader, task->row_group, task->file_column, &err);
    if (!column) {
        carquet_error_format(&err, task->message, sizeof(task->message));
        task->status = 1;
        return;
    }

    int64_t batch = task->rows < QIO_TASK_BATCH ? task->rows : QIO_TASK_BATCH;
    size_t value_width = sizeof(carquet_byte_array_t) > sizeof(carquet_int96_t)
                             ? sizeof(carquet_byte_array_t)
                             : sizeof(carquet_int96_t);
    void *values = malloc((size_t)batch * value_width);
    int16_t *defs = task->max_def > 0
                        ? (int16_t *)malloc((size_t)batch * sizeof(int16_t))
                        : NULL;
    if (!values || (task->max_def > 0 && !defs)) {
        snprintf(task->message, sizeof(task->message),
                 "cannot allocate decode scratch");
        task->status = 1;
        goto done;
    }

    for (int64_t read = 0; read < task->rows;) {
        int64_t want = task->rows - read;
        if (want > batch) want = batch;
        int64_t n = carquet_column_read_batch(column, values, want, defs,
                                              NULL);
        if (n != want) {
            snprintf(task->message, sizeof(task->message),
                     "column %d of row group %d yielded %lld of %lld rows",
                     task->file_column + 1, task->row_group + 1,
                     (long long)(read + (n > 0 ? n : 0)),
                     (long long)task->rows);
            task->status = 1;
            goto done;
        }
        qio_scatter_numeric_raw(task->dst, task->dst_offset + read,
                                task->type, values, defs, task->max_def, n,
                                &task->int32_sentinel);
        read += n;
    }

done:
    free(values);
    free(defs);
    carquet_column_reader_free(column);
}

/* Resolve threads for parallel collect: explicit count, or core count when
 * the handle was opened with threads = 0 ("let carquet choose"). */
static int32_t qio_collect_threads(int32_t requested) {
    if (requested > 0) return requested;
#ifdef _WIN32
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return (int32_t)info.dwNumberOfProcessors;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int32_t)n : 4;
#endif
}

static bool qio_row_group_filter(const carquet_reader_t *reader,
                                 int32_t row_group_index, void *user_data) {
    (void)reader;
    qio_row_group_filter_t *filter =
        (qio_row_group_filter_t *)user_data;
    return row_group_index >= 0 && row_group_index < filter->length &&
           filter->mask[row_group_index];
}

static void qio_prepare_selection(qio_parquet_handle_t *handle,
                                  SEXP columns, SEXP row_groups,
                                  qio_selection_t *selection) {
    const carquet_schema_t *schema =
        carquet_reader_schema(handle->reader);
    int32_t file_columns = carquet_reader_num_columns(handle->reader);

    /* R validates these before calling, but every other entry point re-checks
     * what it dereferences; INTEGER() on a REALSXP would silently reinterpret
     * memory rather than fail. */
    if (columns != R_NilValue && TYPEOF(columns) != STRSXP) {
        Rf_error("qio: `columns` must be a character vector or NULL");
    }
    if (row_groups != R_NilValue && TYPEOF(row_groups) != INTSXP) {
        Rf_error("qio: `row_groups` must be an integer vector or NULL");
    }

    if (columns == R_NilValue) {
        selection->num_columns = file_columns;
        selection->columns = (int32_t *)R_alloc(
            (size_t)(file_columns > 0 ? file_columns : 1), sizeof(int32_t));
        for (int32_t i = 0; i < file_columns; i++) selection->columns[i] = i;
    } else {
        selection->num_columns = Rf_length(columns);
        selection->columns = (int32_t *)R_alloc(
            (size_t)(selection->num_columns > 0 ? selection->num_columns : 1),
            sizeof(int32_t));
        for (int32_t i = 0; i < selection->num_columns; i++) {
            if (STRING_ELT(columns, i) == NA_STRING) {
                Rf_error("qio: `columns` must not contain missing values");
            }
            const char *name = Rf_translateCharUTF8(STRING_ELT(columns, i));
            int32_t index = carquet_schema_find_column(schema, name);
            if (index < 0) {
                Rf_error("qio: unknown parquet column '%s'", name);
            }
            selection->columns[i] = index;
        }
    }

    for (int32_t i = 0; i < selection->num_columns; i++) {
        int32_t column = selection->columns[i];
        const char **parts = NULL;
        int32_t depth = qio_column_path_parts(schema, column, &parts);
        (void)parts;
        carquet_physical_type_t type =
            carquet_schema_column_type(schema, column);
        if (depth > 1 || carquet_schema_max_rep_level(schema, column) > 0) {
            Rf_error("qio: nested parquet column '%s' is not supported",
                     carquet_schema_column_name(schema, column));
        }
        switch (type) {
        case CARQUET_PHYSICAL_BOOLEAN:
        case CARQUET_PHYSICAL_INT32:
        case CARQUET_PHYSICAL_INT64:
        case CARQUET_PHYSICAL_INT96:
        case CARQUET_PHYSICAL_FLOAT:
        case CARQUET_PHYSICAL_DOUBLE:
        case CARQUET_PHYSICAL_BYTE_ARRAY:
            break;
        default:
            Rf_error("qio: column '%s' has unsupported physical type '%s'",
                     carquet_schema_column_name(schema, column),
                     carquet_physical_type_name(type));
        }
    }

    selection->num_row_groups =
        carquet_reader_num_row_groups(handle->reader);
    selection->row_group_mask = (uint8_t *)R_alloc(
        (size_t)(selection->num_row_groups > 0
                     ? selection->num_row_groups
                     : 1),
        sizeof(uint8_t));
    memset(selection->row_group_mask, 0,
           (size_t)(selection->num_row_groups > 0
                        ? selection->num_row_groups
                        : 1));

    if (row_groups == R_NilValue) {
        selection->filter_row_groups = 0;
        memset(selection->row_group_mask, 1,
               (size_t)selection->num_row_groups);
    } else {
        selection->filter_row_groups = 1;
        for (R_xlen_t i = 0; i < XLENGTH(row_groups); i++) {
            int value = INTEGER(row_groups)[i];
            if (value < 1 || value > selection->num_row_groups) {
                Rf_error("qio: row group %d is out of range [1, %d]", value,
                         selection->num_row_groups);
            }
            selection->row_group_mask[value - 1] = 1;
        }
    }

    selection->total_rows = 0;
    for (int32_t i = 0; i < selection->num_row_groups; i++) {
        if (!selection->row_group_mask[i]) continue;
        carquet_row_group_metadata_t metadata;
        carquet_status_t status = carquet_reader_row_group_metadata(
            handle->reader, i, &metadata);
        if (status != CARQUET_OK) {
            Rf_error("qio: cannot inspect row group %d: %s", i + 1,
                     carquet_status_string(status));
        }
        if (metadata.num_rows < 0 ||
            selection->total_rows > INT64_MAX - metadata.num_rows) {
            Rf_error("qio: invalid or overflowing parquet row count");
        }
        selection->total_rows += metadata.num_rows;
    }
}

static carquet_batch_reader_t *qio_create_batch_reader(
    qio_batch_context_t *context, qio_row_group_filter_t *filter) {
    carquet_batch_reader_config_t config;
    carquet_batch_reader_config_init(&config);
    config.column_indices = context->selection.columns;
    config.num_columns = context->selection.num_columns;
    config.batch_size = context->batch_size;
    config.num_threads = context->handle->threads;
    if (context->selection.filter_row_groups) {
        filter->mask = context->selection.row_group_mask;
        filter->length = context->selection.num_row_groups;
        config.row_group_filter = qio_row_group_filter;
        config.row_group_filter_ctx = filter;
    }

    carquet_error_t native_error = CARQUET_ERROR_INIT;
    carquet_batch_reader_t *reader = carquet_batch_reader_create(
        context->handle->reader, &config, &native_error);
    if (!reader) {
        char message[512];
        carquet_error_format(&native_error, message, sizeof(message));
        Rf_error("qio: cannot create parquet batch reader: %s", message);
    }
    return reader;
}

static SEXP qio_allocate_result(qio_batch_context_t *context,
                                R_xlen_t rows) {
    const carquet_schema_t *schema =
        carquet_reader_schema(context->handle->reader);
    int32_t columns = context->selection.num_columns;
    SEXP result = PROTECT(Rf_allocVector(VECSXP, columns));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, columns));
    for (int32_t i = 0; i < columns; i++) {
        int32_t file_column = context->selection.columns[i];
        carquet_physical_type_t type =
            carquet_schema_column_type(schema, file_column);
        SET_VECTOR_ELT(result, i, qio_allocate_column(type, rows));
        SET_STRING_ELT(names, i,
                       qio_column_path_string(schema, file_column));
    }
    qio_set_data_frame_attributes(result, names, rows);
    UNPROTECT(2);
    return result;
}

static void qio_copy_batch(qio_batch_context_t *context, SEXP result,
                           R_xlen_t offset, carquet_row_batch_t *batch) {
    const carquet_schema_t *schema =
        carquet_reader_schema(context->handle->reader);
    int64_t rows = carquet_row_batch_num_rows(batch);
    if (carquet_row_batch_num_columns(batch) !=
        context->selection.num_columns) {
        Rf_error("qio: parquet batch returned an unexpected column count");
    }

    for (int32_t i = 0; i < context->selection.num_columns; i++) {
        const void *data = NULL;
        const uint8_t *bitmap = NULL;
        int64_t values = 0;
        carquet_status_t status = carquet_row_batch_column(
            batch, i, &data, &bitmap, &values);
        if (status != CARQUET_OK || values != rows) {
            Rf_error("qio: cannot materialize parquet batch column %d: %s",
                     i + 1, carquet_status_string(status));
        }
        carquet_physical_type_t type = carquet_schema_column_type(
            schema, context->selection.columns[i]);
        qio_copy_batch_column(
            VECTOR_ELT(result, i), offset, type, data, bitmap, rows,
            carquet_schema_column_name(schema, context->selection.columns[i]),
            &context->int32_sentinel);
    }
}

/* One warning per operation, never per value, column, row group, or batch.
 * Emitted after the read completes so an in-flight error is not preceded by a
 * warning about a partial result; see TYPES.md. */
static void qio_warn_int32_sentinel(const qio_batch_context_t *context) {
    if (!context->int32_sentinel) return;
    Rf_warning("Some INT32 values were coerced to NA because R's integer type "
               "reserves -2147483648 as its missing value.");
}

/* Call FUN(batch, index) with both arguments bound in a child of the base
 * environment. Splicing the values straight into the call would leave the whole
 * batch data frame as a literal, which any error inside the callback then
 * deparses into its traceback. */
static void qio_call_batch_callback(qio_batch_context_t *context,
                                    SEXP batch, int batch_index) {
    /* new.env() rather than R_NewEnv(), which would raise the package's R floor
     * to 4.1 without DESCRIPTION saying so. */
    SEXP new_env_call = PROTECT(Rf_lang1(Rf_install("new.env")));
    SEXP env = PROTECT(Rf_eval(new_env_call, R_BaseEnv));
    SEXP batch_sym = Rf_install("batch");
    SEXP index_sym = Rf_install("index");
    Rf_defineVar(batch_sym, batch, env);
    Rf_defineVar(index_sym, Rf_ScalarInteger(batch_index), env);
    SEXP call = PROTECT(Rf_lang3(context->callback, batch_sym, index_sym));
    SEXP value = PROTECT(Rf_eval(call, env));
    (void)value;
    UNPROTECT(4);
}

static SEXP qio_collect_body(void *data) {
    qio_batch_context_t *context = (qio_batch_context_t *)data;
    if (context->selection.total_rows > INT_MAX) {
        Rf_error("qio: `collect()` cannot return more than %d rows; use "
                 "`walk_batches()` instead",
                 INT_MAX);
    }

    R_xlen_t rows = (R_xlen_t)context->selection.total_rows;
    SEXP result = PROTECT(qio_allocate_result(context, rows));
    if (rows == 0 || context->selection.num_columns == 0) {
        UNPROTECT(1);
        return result;
    }

    /* Read directly at the column level (carquet_reader_get_column +
     * carquet_column_read_batch) rather than through the batch reader. That
     * yields Parquet-native dense values + definition levels, which
     * qio_scatter_dense_column places into the result in a single pass —
     * skipping the batch reader's dense->row-aligned expansion and null-bitmap
     * build. walk_batches() still uses the batch reader (qio_walk_body). */
    carquet_reader_t *reader = context->handle->reader;
    const carquet_schema_t *schema = carquet_reader_schema(reader);
    int32_t ncol = context->selection.num_columns;

    /* Selected row groups: carquet index, row count, and result offset. */
    int32_t n_all = context->selection.num_row_groups;
    int32_t *rg_index = (int32_t *)R_alloc(
        (size_t)(n_all > 0 ? n_all : 1), sizeof(int32_t));
    int64_t *rg_rows = (int64_t *)R_alloc(
        (size_t)(n_all > 0 ? n_all : 1), sizeof(int64_t));
    R_xlen_t *rg_offset = (R_xlen_t *)R_alloc(
        (size_t)(n_all > 0 ? n_all : 1), sizeof(R_xlen_t));
    int32_t n_groups = 0;
    int64_t max_rg_rows = 0;
    R_xlen_t offset = 0;
    for (int32_t g = 0; g < n_all; g++) {
        if (!context->selection.row_group_mask[g]) continue;
        carquet_row_group_metadata_t meta;
        if (carquet_reader_row_group_metadata(reader, g, &meta) != CARQUET_OK) {
            Rf_error("qio: cannot inspect row group %d", g + 1);
        }
        if (meta.num_rows <= 0) continue;
        if (offset + meta.num_rows > rows) {
            Rf_error("qio: row group %d exceeds the expected row count", g + 1);
        }
        rg_index[n_groups] = g;
        rg_rows[n_groups] = meta.num_rows;
        rg_offset[n_groups] = offset;
        offset += (R_xlen_t)meta.num_rows;
        if (meta.num_rows > max_rg_rows) max_rg_rows = meta.num_rows;
        n_groups++;
    }
    if (offset != rows) {
        Rf_error("qio: expected %lld rows but the selected row groups hold "
                 "%lld",
                 (long long)rows, (long long)offset);
    }

    /* One task per (row group x numeric column); BYTE_ARRAY columns are
     * handled on the main thread below. Size the array in int64_t: the guard
     * must not be evaluated in int, where the product can overflow and take
     * the one-element branch while the loop below fills n_groups * ncol. */
    int64_t max_tasks = (int64_t)n_groups * (int64_t)ncol;
    qio_column_task_t *tasks = (qio_column_task_t *)R_alloc(
        (size_t)(max_tasks > 0 ? max_tasks : 1), sizeof(qio_column_task_t));
    int32_t n_tasks = 0;
    int has_strings = 0;
    for (int32_t s = 0; s < n_groups; s++) {
        for (int32_t i = 0; i < ncol; i++) {
            int32_t file_col = context->selection.columns[i];
            carquet_physical_type_t type =
                carquet_schema_column_type(schema, file_col);
            if (type == CARQUET_PHYSICAL_BYTE_ARRAY) {
                has_strings = 1;
                continue;
            }
            qio_column_task_t *task = &tasks[n_tasks++];
            memset(task, 0, sizeof(*task));
            task->reader = reader;
            task->row_group = rg_index[s];
            task->file_column = file_col;
            task->type = type;
            task->max_def = carquet_schema_max_def_level(schema, file_col);
            task->dst = qio_column_data_pointer(VECTOR_ELT(result, i), type);
            task->dst_offset = rg_offset[s];
            task->rows = rg_rows[s];
        }
    }

    /* Numeric tasks run on carquet's worker pool when the reader is
     * memory-mapped (the fread path shares FILE-handle and prebuffer state
     * and is not thread-safe) and threads != 1; inline otherwise. */
    int32_t threads = qio_collect_threads(context->handle->threads);
    if (context->handle->threads != 1 && threads > 1 && n_tasks > 1 &&
        carquet_reader_is_mmap(reader)) {
        if (threads > n_tasks) threads = n_tasks;
        context->pool = carquet_worker_pool_create(threads);
        /* NULL just means no parallelism; fall through to the inline path. */
    }
    int32_t submitted = 0;
    if (context->pool) {
        /* carquet_worker_pool_submit() blocks once the queue is full, despite
         * its header comment. Submitting every task up front would therefore
         * stall the main thread before it reaches the string pass below, so
         * only prime the queue here and submit the rest afterwards. */
        submitted = n_tasks < CARQUET_POOL_QUEUE_CAPACITY
                        ? n_tasks
                        : CARQUET_POOL_QUEUE_CAPACITY;
        for (int32_t t = 0; t < submitted; t++) {
            carquet_worker_pool_submit(context->pool, qio_column_task_run,
                                       &tasks[t]);
        }
    } else {
        for (int32_t t = 0; t < n_tasks; t++) {
            qio_column_task_run(&tasks[t]);
            if (tasks[t].status) {
                Rf_error("qio: %s", tasks[t].message);
            }
            R_CheckUserInterrupt();
        }
        submitted = n_tasks;
    }

    /* String columns on the main thread (interning and the write barrier are
     * R API), overlapping the workers. An error here unwinds through
     * qio_batch_cleanup, which waits for the pool before the jump continues. */
    if (has_strings) {
        size_t value_width = sizeof(carquet_byte_array_t);
        void *value_buf = R_alloc((size_t)max_rg_rows, (int)value_width);
        int16_t *def_buf =
            (int16_t *)R_alloc((size_t)max_rg_rows, sizeof(int16_t));
        for (int32_t s = 0; s < n_groups; s++) {
            for (int32_t i = 0; i < ncol; i++) {
                int32_t file_col = context->selection.columns[i];
                carquet_physical_type_t type =
                    carquet_schema_column_type(schema, file_col);
                if (type != CARQUET_PHYSICAL_BYTE_ARRAY) continue;
                int16_t max_def =
                    carquet_schema_max_def_level(schema, file_col);

                carquet_error_t err = CARQUET_ERROR_INIT;
                carquet_column_reader_t *col = carquet_reader_get_column(
                    reader, rg_index[s], file_col, &err);
                if (!col) {
                    char message[512];
                    carquet_error_format(&err, message, sizeof(message));
                    Rf_error("qio: cannot open column %d of row group %d: %s",
                             file_col + 1, rg_index[s] + 1, message);
                }
                context->column = col;

                int16_t *def_ptr = (max_def > 0) ? def_buf : NULL;
                int64_t n = carquet_column_read_batch(col, value_buf,
                                                      rg_rows[s], def_ptr,
                                                      NULL);
                if (n != rg_rows[s]) {
                    Rf_error("qio: column %d of row group %d yielded %lld of "
                             "%lld rows",
                             file_col + 1, rg_index[s] + 1, (long long)n,
                             (long long)rg_rows[s]);
                }
                /* Scatter before freeing: BYTE_ARRAY values point into the
                 * column reader's page buffers, released on free. */
                qio_scatter_dense_column(
                    VECTOR_ELT(result, i), rg_offset[s], type, value_buf,
                    def_ptr, max_def, n,
                    carquet_schema_column_name(schema, file_col),
                    &context->int32_sentinel);
                carquet_column_reader_free(col);
                context->column = NULL;
            }
            R_CheckUserInterrupt();
        }
    }

    /* Submit whatever the initial wave left over. Interrupts are checked
     * between submissions: carquet_worker_pool_wait() cannot be interrupted,
     * so this bounds the uninterruptible window to the tasks still in flight. */
    if (context->pool) {
        for (int32_t t = submitted; t < n_tasks; t++) {
            carquet_worker_pool_submit(context->pool, qio_column_task_run,
                                       &tasks[t]);
            R_CheckUserInterrupt();
        }
    }

    /* Join the workers, then surface the first recorded failure (workers
     * must never call Rf_error themselves). */
    if (context->pool) {
        carquet_worker_pool_wait(context->pool);
        carquet_worker_pool_destroy(context->pool);
        context->pool = NULL;
    }
    for (int32_t t = 0; t < n_tasks; t++) {
        if (tasks[t].status) {
            Rf_error("qio: %s", tasks[t].message);
        }
        if (tasks[t].int32_sentinel) context->int32_sentinel = 1;
    }

    UNPROTECT(1);
    return result;
}

static SEXP qio_walk_empty_columns(qio_batch_context_t *context) {
    int batch_index = 0;
    for (int32_t group = 0; group < context->selection.num_row_groups;
         group++) {
        if (!context->selection.row_group_mask[group]) continue;
        carquet_row_group_metadata_t metadata;
        carquet_status_t status = carquet_reader_row_group_metadata(
            context->handle->reader, group, &metadata);
        if (status != CARQUET_OK) {
            Rf_error("qio: cannot inspect row group %d: %s", group + 1,
                     carquet_status_string(status));
        }
        int64_t remaining = metadata.num_rows;
        while (remaining > 0) {
            int64_t size = remaining > context->batch_size
                               ? context->batch_size
                               : remaining;
            SEXP batch = PROTECT(qio_allocate_result(context,
                                                      (R_xlen_t)size));
            qio_call_batch_callback(context, batch, ++batch_index);
            UNPROTECT(1);
            remaining -= size;
            R_CheckUserInterrupt();
        }
    }
    return context->file;
}

static SEXP qio_walk_body(void *data) {
    qio_batch_context_t *context = (qio_batch_context_t *)data;
    if (context->selection.total_rows == 0) return context->file;
    if (context->selection.num_columns == 0) {
        return qio_walk_empty_columns(context);
    }

    qio_row_group_filter_t filter;
    context->batch_reader = qio_create_batch_reader(context, &filter);
    int batch_index = 0;
    for (;;) {
        carquet_row_batch_t *native_batch = NULL;
        carquet_status_t status = carquet_batch_reader_next(
            context->batch_reader, &native_batch);
        if (status == CARQUET_ERROR_END_OF_DATA) {
            if (native_batch) carquet_row_batch_free(native_batch);
            break;
        }
        context->batch = native_batch;
        if (status != CARQUET_OK) {
            Rf_error("qio: parquet batch read failed: %s",
                     carquet_status_string(status));
        }
        if (!native_batch) {
            Rf_error("qio: parquet batch reader returned no batch");
        }

        int64_t rows = carquet_row_batch_num_rows(native_batch);
        if (rows < 0 || rows > INT_MAX) {
            Rf_error("qio: parquet batch returned an invalid row count");
        }
        if (rows > 0) {
            SEXP batch = PROTECT(qio_allocate_result(context,
                                                      (R_xlen_t)rows));
            qio_copy_batch(context, batch, 0, native_batch);
            qio_call_batch_callback(context, batch, ++batch_index);
            UNPROTECT(1);
        }
        carquet_row_batch_free(native_batch);
        context->batch = NULL;
        R_CheckUserInterrupt();
    }
    return context->file;
}

static void qio_batch_cleanup(void *data, Rboolean jump) {
    (void)jump;
    qio_batch_context_t *context = (qio_batch_context_t *)data;
    if (context->batch) {
        carquet_row_batch_free(context->batch);
        context->batch = NULL;
    }
    if (context->batch_reader) {
        carquet_batch_reader_free(context->batch_reader);
        context->batch_reader = NULL;
    }
    if (context->column) {
        carquet_column_reader_free(context->column);
        context->column = NULL;
    }
    if (context->pool) {
        /* Workers write into the (still PROTECTed) result vectors; block until
         * they finish before the unwind continues and the result is released. */
        carquet_worker_pool_wait(context->pool);
        carquet_worker_pool_destroy(context->pool);
        context->pool = NULL;
    }
    context->handle->busy = 0;
}

/* A non-positive batch size would make qio_walk_empty_columns() loop forever,
 * and NA_INTEGER (INT_MIN) would grow `remaining` on every pass. */
static int32_t qio_batch_size(SEXP batch_size) {
    int value = Rf_asInteger(batch_size);
    if (value == NA_INTEGER || value < 1) {
        Rf_error("qio: `batch_size` must be a positive whole number");
    }
    return (int32_t)value;
}

SEXP qio_parquet_open(SEXP path, SEXP use_mmap, SEXP verify_checksums,
                      SEXP threads) {
    if (TYPEOF(path) != STRSXP || XLENGTH(path) != 1 ||
        STRING_ELT(path, 0) == NA_STRING) {
        Rf_error("qio: `file` must be a single file path");
    }

    int num_threads = Rf_asInteger(threads);
    if (num_threads == NA_INTEGER || num_threads < 0) {
        Rf_error("qio: `threads` must be a non-negative whole number");
    }

    carquet_reader_options_t options;
    carquet_reader_options_init(&options);
    options.use_mmap = Rf_asLogical(use_mmap) == TRUE;
    options.verify_checksums = Rf_asLogical(verify_checksums) == TRUE;
    options.num_threads = num_threads;

    const char *file_path = Rf_translateChar(STRING_ELT(path, 0));
    carquet_error_t native_error = CARQUET_ERROR_INIT;
    carquet_reader_t *reader = carquet_reader_open(
        file_path, &options, &native_error);
    if (!reader) {
        char message[512];
        carquet_error_format(&native_error, message, sizeof(message));
        Rf_error("qio: cannot open '%s': %s", file_path, message);
    }

    qio_parquet_handle_t *handle =
        (qio_parquet_handle_t *)calloc(1, sizeof(qio_parquet_handle_t));
    if (!handle) {
        carquet_reader_close(reader);
        Rf_error("qio: cannot allocate parquet file handle");
    }
    handle->reader = reader;
    handle->threads = options.num_threads;

    SEXP file = PROTECT(R_MakeExternalPtr(handle, qio_file_tag(), path));
    R_RegisterCFinalizerEx(file, qio_finalize_file, TRUE);
    UNPROTECT(1);
    return file;
}

SEXP qio_parquet_close(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 1);
    if (!handle) return file;
    if (handle->busy) {
        Rf_error("qio: cannot close a parquet file during an active read");
    }
    qio_finalize_file(file);
    return file;
}

SEXP qio_parquet_is_open(SEXP file) {
    qio_get_handle(file, 1);
    return Rf_ScalarLogical(R_ExternalPtrAddr(file) != NULL);
}

SEXP qio_parquet_path(SEXP file) {
    qio_get_handle(file, 1);
    return R_ExternalPtrProtected(file);
}

SEXP qio_parquet_dim(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    SEXP dimensions = PROTECT(Rf_allocVector(REALSXP, 2));
    REAL(dimensions)[0] = (double)carquet_reader_num_rows(handle->reader);
    REAL(dimensions)[1] = (double)carquet_reader_num_columns(handle->reader);
    UNPROTECT(1);
    return dimensions;
}

SEXP qio_parquet_names(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    const carquet_schema_t *schema =
        carquet_reader_schema(handle->reader);
    int32_t columns = carquet_reader_num_columns(handle->reader);
    SEXP names = PROTECT(Rf_allocVector(STRSXP, columns));
    for (int32_t i = 0; i < columns; i++) {
        SET_STRING_ELT(names, i, qio_column_path_string(schema, i));
    }
    UNPROTECT(1);
    return names;
}

SEXP qio_parquet_schema(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    const carquet_schema_t *schema =
        carquet_reader_schema(handle->reader);
    int32_t rows = carquet_reader_num_columns(handle->reader);

    const char *column_names[] = {
        "column", "name", "path", "physical_type", "logical_type",
        "logical_details", "repetition", "type_length",
        "max_definition_level", "max_repetition_level"};

    SEXP result = PROTECT(Rf_allocVector(VECSXP, 10));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 10));
    SET_VECTOR_ELT(result, 0, Rf_allocVector(INTSXP, rows));
    for (int i = 1; i <= 6; i++)
        SET_VECTOR_ELT(result, i, Rf_allocVector(STRSXP, rows));
    for (int i = 7; i <= 9; i++)
        SET_VECTOR_ELT(result, i, Rf_allocVector(INTSXP, rows));
    for (int i = 0; i < 10; i++)
        SET_STRING_ELT(names, i, Rf_mkChar(column_names[i]));

    const carquet_schema_node_t **leaves =
        (const carquet_schema_node_t **)R_alloc(
            (size_t)(rows > 0 ? rows : 1), sizeof(*leaves));
    if (qio_leaf_nodes(schema, leaves, rows) != rows) {
        Rf_error("qio: parquet schema does not describe all %d columns", rows);
    }

    for (int32_t i = 0; i < rows; i++) {
        const carquet_schema_node_t *node = leaves[i];
        const carquet_logical_type_t *logical =
            carquet_schema_node_logical_type(node);
        INTEGER(VECTOR_ELT(result, 0))[i] = i + 1;
        SET_STRING_ELT(VECTOR_ELT(result, 1), i,
                       Rf_mkCharCE(carquet_schema_column_name(schema, i),
                                   CE_UTF8));
        SET_STRING_ELT(VECTOR_ELT(result, 2), i,
                       qio_column_path_string(schema, i));
        SET_STRING_ELT(VECTOR_ELT(result, 3), i,
                       Rf_mkChar(carquet_physical_type_name(
                           carquet_schema_column_type(schema, i))));
        if (logical) {
            SET_STRING_ELT(VECTOR_ELT(result, 4), i,
                           Rf_mkChar(qio_logical_type_name(logical->id)));
            char details[256];
            if (qio_logical_type_details(logical, details, sizeof(details))) {
                SET_STRING_ELT(VECTOR_ELT(result, 5), i,
                               Rf_mkCharCE(details, CE_UTF8));
            } else {
                SET_STRING_ELT(VECTOR_ELT(result, 5), i, NA_STRING);
            }
        } else {
            SET_STRING_ELT(VECTOR_ELT(result, 4), i, NA_STRING);
            SET_STRING_ELT(VECTOR_ELT(result, 5), i, NA_STRING);
        }
        SET_STRING_ELT(VECTOR_ELT(result, 6), i,
                       Rf_mkChar(qio_repetition_name(
                           carquet_schema_node_repetition(node))));
        INTEGER(VECTOR_ELT(result, 7))[i] =
            carquet_schema_node_type_length(node);
        INTEGER(VECTOR_ELT(result, 8))[i] =
            carquet_schema_max_def_level(schema, i);
        INTEGER(VECTOR_ELT(result, 9))[i] =
            carquet_schema_max_rep_level(schema, i);
    }

    qio_set_data_frame_attributes(result, names, rows);
    UNPROTECT(2);
    return result;
}

SEXP qio_parquet_row_groups(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    int32_t rows = carquet_reader_num_row_groups(handle->reader);
    SEXP result = PROTECT(Rf_allocVector(VECSXP, 4));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 4));
    const char *column_names[] = {
        "row_group", "rows", "compressed_bytes", "uncompressed_bytes"};
    SET_VECTOR_ELT(result, 0, Rf_allocVector(INTSXP, rows));
    for (int i = 1; i < 4; i++)
        SET_VECTOR_ELT(result, i, Rf_allocVector(REALSXP, rows));
    for (int i = 0; i < 4; i++)
        SET_STRING_ELT(names, i, Rf_mkChar(column_names[i]));

    for (int32_t i = 0; i < rows; i++) {
        carquet_row_group_metadata_t metadata;
        carquet_status_t status = carquet_reader_row_group_metadata(
            handle->reader, i, &metadata);
        if (status != CARQUET_OK) {
            Rf_error("qio: cannot inspect row group %d: %s", i + 1,
                     carquet_status_string(status));
        }
        INTEGER(VECTOR_ELT(result, 0))[i] = i + 1;
        REAL(VECTOR_ELT(result, 1))[i] = (double)metadata.num_rows;
        REAL(VECTOR_ELT(result, 2))[i] =
            (double)metadata.total_compressed_size;
        REAL(VECTOR_ELT(result, 3))[i] =
            (double)metadata.total_byte_size;
    }
    qio_set_data_frame_attributes(result, names, rows);
    UNPROTECT(2);
    return result;
}

SEXP qio_parquet_metadata(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    int32_t rows = carquet_reader_num_metadata(handle->reader);
    SEXP result = PROTECT(Rf_allocVector(VECSXP, 2));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP keys = PROTECT(Rf_allocVector(STRSXP, rows));
    SEXP values = PROTECT(Rf_allocVector(STRSXP, rows));
    SET_VECTOR_ELT(result, 0, keys);
    SET_VECTOR_ELT(result, 1, values);
    SET_STRING_ELT(names, 0, Rf_mkChar("key"));
    SET_STRING_ELT(names, 1, Rf_mkChar("value"));
    for (int32_t i = 0; i < rows; i++) {
        const char *key = NULL;
        const char *value = NULL;
        carquet_status_t status = carquet_reader_get_metadata(
            handle->reader, i, &key, &value);
        if (status != CARQUET_OK) {
            Rf_error("qio: cannot read parquet metadata entry %d: %s", i + 1,
                     carquet_status_string(status));
        }
        SET_STRING_ELT(keys, i, Rf_mkCharCE(key ? key : "", CE_UTF8));
        SET_STRING_ELT(values, i,
                       value ? Rf_mkCharCE(value, CE_UTF8) : NA_STRING);
    }
    qio_set_data_frame_attributes(result, names, rows);
    UNPROTECT(4);
    return result;
}

SEXP qio_parquet_collect(SEXP file, SEXP columns, SEXP row_groups,
                         SEXP batch_size) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    if (handle->busy) {
        Rf_error("qio: parquet file already has an active read");
    }

    qio_batch_context_t context;
    memset(&context, 0, sizeof(context));
    context.handle = handle;
    context.file = file;
    context.batch_size = qio_batch_size(batch_size);
    qio_prepare_selection(handle, columns, row_groups, &context.selection);

    handle->busy = 1;
    SEXP continuation = PROTECT(R_MakeUnwindCont());
    SEXP result = PROTECT(R_UnwindProtect(qio_collect_body, &context,
                                          qio_batch_cleanup, &context,
                                          continuation));
    qio_warn_int32_sentinel(&context);
    UNPROTECT(2);
    return result;
}

SEXP qio_parquet_walk(SEXP file, SEXP columns, SEXP row_groups,
                      SEXP batch_size, SEXP callback) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    if (handle->busy) {
        Rf_error("qio: parquet file already has an active read");
    }
    if (!Rf_isFunction(callback)) {
        Rf_error("qio: `FUN` must be a function");
    }

    qio_batch_context_t context;
    memset(&context, 0, sizeof(context));
    context.handle = handle;
    context.file = file;
    context.callback = callback;
    context.batch_size = qio_batch_size(batch_size);
    qio_prepare_selection(handle, columns, row_groups, &context.selection);

    handle->busy = 1;
    SEXP continuation = PROTECT(R_MakeUnwindCont());
    SEXP result = PROTECT(R_UnwindProtect(qio_walk_body, &context,
                                          qio_batch_cleanup, &context,
                                          continuation));
    qio_warn_int32_sentinel(&context);
    UNPROTECT(2);
    return result;
}
