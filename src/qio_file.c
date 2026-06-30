#include "qio_file.h"

#include <R.h>
#include <R_ext/Utils.h>
#include <Rinternals.h>

#include <carquet/carquet.h>

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    carquet_reader_t *reader;
    int32_t threads;
    int use_mmap;
    int verify_checksums;
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
    SEXP file;
    SEXP callback;
    int walk;
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

static const carquet_schema_node_t *qio_leaf_node(
    const carquet_schema_t *schema, int32_t leaf_index) {
    int32_t seen = 0;
    int32_t elements = carquet_schema_num_elements(schema);
    for (int32_t i = 0; i < elements; i++) {
        const carquet_schema_node_t *node =
            carquet_schema_get_element(schema, i);
        if (node && carquet_schema_node_is_leaf(node)) {
            if (seen == leaf_index) return node;
            seen++;
        }
    }
    return NULL;
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

static SEXP qio_allocate_column(carquet_physical_type_t type,
                                R_xlen_t length) {
    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN:
        return Rf_allocVector(LGLSXP, length);
    case CARQUET_PHYSICAL_INT32:
        return Rf_allocVector(INTSXP, length);
    case CARQUET_PHYSICAL_INT64:
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
                                  int64_t length) {
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
        case CARQUET_PHYSICAL_INT32:
            INTEGER(destination)[out] = ((const int32_t *)data)[i];
            break;
        case CARQUET_PHYSICAL_INT64:
            REAL(destination)[out] = (double)((const int64_t *)data)[i];
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
            if (value->length < 0 ||
                (value->length > 0 && value->data == NULL)) {
                Rf_error("qio: parquet batch returned an invalid byte array");
            }
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
        qio_copy_batch_column(VECTOR_ELT(result, i), offset, type, data,
                              bitmap, rows);
    }
}

static void qio_call_batch_callback(qio_batch_context_t *context,
                                    SEXP batch, int batch_index) {
    SEXP index = PROTECT(Rf_ScalarInteger(batch_index));
    SEXP call = PROTECT(Rf_lang3(context->callback, batch, index));
    SEXP value = PROTECT(Rf_eval(call, R_GlobalEnv));
    (void)value;
    UNPROTECT(3);
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

    qio_row_group_filter_t filter;
    context->batch_reader = qio_create_batch_reader(context, &filter);
    R_xlen_t offset = 0;
    for (;;) {
        carquet_row_batch_t *batch = NULL;
        carquet_status_t status = carquet_batch_reader_next(
            context->batch_reader, &batch);
        if (status == CARQUET_ERROR_END_OF_DATA) {
            if (batch) carquet_row_batch_free(batch);
            break;
        }
        context->batch = batch;
        if (status != CARQUET_OK) {
            Rf_error("qio: parquet batch read failed: %s",
                     carquet_status_string(status));
        }
        if (!batch) {
            Rf_error("qio: parquet batch reader returned no batch");
        }
        int64_t batch_rows = carquet_row_batch_num_rows(batch);
        if (batch_rows < 0 || offset + batch_rows > rows) {
            Rf_error("qio: parquet batch returned an invalid row count");
        }
        if (batch_rows > 0) {
            qio_copy_batch(context, result, offset, batch);
            offset += (R_xlen_t)batch_rows;
        }
        carquet_row_batch_free(batch);
        context->batch = NULL;
        R_CheckUserInterrupt();
    }

    if (offset != rows) {
        Rf_error("qio: expected %lld rows but decoded %lld",
                 (long long)rows, (long long)offset);
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
    context->handle->busy = 0;
}

SEXP qio_parquet_open(SEXP path, SEXP use_mmap, SEXP verify_checksums,
                      SEXP threads) {
    if (TYPEOF(path) != STRSXP || XLENGTH(path) != 1 ||
        STRING_ELT(path, 0) == NA_STRING) {
        Rf_error("qio: `file` must be a single file path");
    }

    carquet_reader_options_t options;
    carquet_reader_options_init(&options);
    options.use_mmap = Rf_asLogical(use_mmap) == TRUE;
    options.verify_checksums = Rf_asLogical(verify_checksums) == TRUE;
    options.num_threads = Rf_asInteger(threads);

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
    handle->use_mmap = options.use_mmap;
    handle->verify_checksums = options.verify_checksums;

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

    for (int32_t i = 0; i < rows; i++) {
        const carquet_schema_node_t *node = qio_leaf_node(schema, i);
        if (!node) Rf_error("qio: cannot inspect parquet schema column %d", i + 1);
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
    context.batch_size = Rf_asInteger(batch_size);
    qio_prepare_selection(handle, columns, row_groups, &context.selection);

    handle->busy = 1;
    SEXP continuation = PROTECT(R_MakeUnwindCont());
    SEXP result = R_UnwindProtect(qio_collect_body, &context,
                                  qio_batch_cleanup, &context,
                                  continuation);
    UNPROTECT(1);
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
    context.walk = 1;
    context.batch_size = Rf_asInteger(batch_size);
    qio_prepare_selection(handle, columns, row_groups, &context.selection);

    handle->busy = 1;
    SEXP continuation = PROTECT(R_MakeUnwindCont());
    SEXP result = R_UnwindProtect(qio_walk_body, &context,
                                  qio_batch_cleanup, &context,
                                  continuation);
    UNPROTECT(1);
    return result;
}
