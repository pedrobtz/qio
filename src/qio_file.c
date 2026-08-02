#include "qio_file.h"
#include "qio_path.h"

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
    /* Non-NULL when qio opened the stream itself rather than handing carquet a
     * path, which is how a path outside Windows' active code page stays
     * readable; see qio_path.h. carquet does not own it, so this closes it. */
    FILE *file;
    int32_t threads;
    /* How this handle was opened. Needed to reopen an identical private reader
     * per worker for parallel buffered collects: the buffered path shares
     * FILE* and prebuffer state, so workers cannot share one reader.
     * `use_mmap` records what actually happened, not what was asked for. */
    int use_mmap;
    int verify_checksums;
    int busy;
} qio_parquet_handle_t;

/* How a 64-bit integer column reaches R. Chosen once per read by the `int64`
 * option and applied to every INT64 column; see .agents/TYPES.md. */
#define QIO_INT64_DOUBLE 0
#define QIO_INT64_BIT64 1

/* What R object a selected column materializes into. The read plan decides
 * this and passes one code per selected column; C never infers it from the
 * schema, so a new annotation only changes the plan. */
#define QIO_KIND_DEFAULT 0 /* physical fallback for the type */
#define QIO_KIND_INT64 1   /* INT64 under the `int64` range rules */
#define QIO_KIND_TEXT 2    /* BYTE_ARRAY with a text annotation -> character */
#define QIO_KIND_BINARY 3  /* BYTE_ARRAY or FIXED_LEN_BYTE_ARRAY -> raw list */
#define QIO_KIND_UINT32 4  /* INT32 bits read as unsigned -> double */
#define QIO_KIND_UUID 5    /* FIXED_LEN_BYTE_ARRAY(16) + UUID -> character */

/* R's exact integer range in a double. Both bounds are representable. */
#define QIO_DOUBLE_EXACT_MAX 9007199254740992LL /* 2^53 */

typedef struct {
    int32_t *columns;
    int32_t num_columns;
    /* Per selected column: 1 when the leaf is an unsigned 64-bit integer.
     * Resolved once from the schema so the decode loops never re-walk it. */
    uint8_t *unsigned64;
    /* Per selected column: what R object to build (QIO_KIND_*). The plan
     * decides. A TIMESTAMP is physically INT64 but is a count of sub-second
     * units R converts later, so range-checking it against 2^53 would destroy
     * nanosecond timestamps; likewise a UUID is physically a fixed byte array
     * whose text form R produces. C never infers any of this. */
    uint8_t *kind;
    /* Per selected column: declared width of a FIXED_LEN_BYTE_ARRAY leaf. */
    int32_t *type_length;
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
    carquet_reader_t **private_readers; /* one per lane, buffered reads only */
    FILE **private_streams;             /* what those readers read through */
    int32_t num_private_readers;
    SEXP file;
    SEXP callback;
    int int64_mode;                   /* QIO_INT64_DOUBLE or QIO_INT64_BIT64 */
    int int32_sentinel;               /* an INT32 -2147483648 became NA */
    int int64_coerced;                /* a 64-bit value could not be kept */
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
    /* After the reader, which reads through it until closed. */
    if (handle->file) {
        fclose(handle->file);
        handle->file = NULL;
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

/* Complete dotted schema path as a C string, for diagnostics. */
static const char *qio_column_path_cstr(const carquet_schema_t *schema,
                                        int32_t leaf_index) {
    const char **parts = NULL;
    int32_t depth = qio_column_path_parts(schema, leaf_index, &parts);
    if (depth <= 0) {
        const char *name = carquet_schema_column_name(schema, leaf_index);
        return name ? name : "";
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
    return path;
}

/* Leaf node by index. Linear in schema size, so diagnostics only; bulk callers
 * use qio_leaf_nodes(). */
static const carquet_schema_node_t *qio_leaf_node_at(
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

/* Describe a leaf's logical annotation for an error message: the annotation
 * name plus its parameters, or "none". */
static const char *qio_logical_description(const carquet_schema_t *schema,
                                           int32_t leaf_index) {
    const carquet_schema_node_t *node = qio_leaf_node_at(schema, leaf_index);
    if (!node) return "none";
    const carquet_logical_type_t *logical =
        carquet_schema_node_logical_type(node);
    if (!logical) return "none";

    const char *name = qio_logical_type_name(logical->id);
    char details[256];
    if (!qio_logical_type_details(logical, details, sizeof(details))) {
        return name;
    }
    size_t size = strlen(name) + strlen(details) + 4;
    char *out = (char *)R_alloc(size, sizeof(char));
    snprintf(out, size, "%s(%s)", name, details);
    return out;
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

/* Validate UTF-8. Returns the 1-based byte offset of the first malformed
 * sequence, or 0 when the whole range is well formed.
 *
 * Rf_mkCharLenCE(CE_UTF8) does not check, so without this a text column of
 * arbitrary bytes would produce CHARSXPs that claim an encoding they do not
 * have, misbehaving later rather than failing here. Overlong forms, surrogate
 * halves, and anything above U+10FFFF are rejected: they are all invalid UTF-8
 * even though a naive length-only check accepts them. */
/* Any byte below 0x80 is a complete, valid UTF-8 sequence on its own, and real
 * text is overwhelmingly made of them. Testing eight at a time turns the common
 * case into one load and one mask per eight bytes instead of a decode step per
 * byte.
 *
 * The mask is byte-wise, so it holds on either endianness, and memcpy is used
 * rather than a cast because the bytes come from a page buffer with no
 * alignment guarantee -- compilers fold it into a single unaligned load. */
#define QIO_ASCII_HIGH_BITS 0x8080808080808080ULL

static int32_t qio_skip_ascii(const uint8_t *bytes, int32_t length, int32_t i) {
    while (length - i >= 8) {
        uint64_t word;
        memcpy(&word, bytes + i, sizeof(word));
        if (word & QIO_ASCII_HIGH_BITS) break;
        i += 8;
    }
    return i;
}

static int64_t qio_utf8_invalid_at(const uint8_t *bytes, int32_t length) {
    int32_t i = 0;
    while (i < length) {
        i = qio_skip_ascii(bytes, length, i);
        if (i >= length) break;
        uint8_t byte = bytes[i];
        int32_t extra;
        uint32_t code;
        if (byte < 0x80) {
            i++;
            continue;
        } else if ((byte & 0xE0) == 0xC0) {
            extra = 1;
            code = byte & 0x1Fu;
        } else if ((byte & 0xF0) == 0xE0) {
            extra = 2;
            code = byte & 0x0Fu;
        } else if ((byte & 0xF8) == 0xF0) {
            extra = 3;
            code = byte & 0x07u;
        } else {
            return (int64_t)i + 1;
        }
        if (i + extra >= length) return (int64_t)i + 1;
        for (int32_t k = 1; k <= extra; k++) {
            uint8_t cont = bytes[i + k];
            if ((cont & 0xC0) != 0x80) return (int64_t)i + 1;
            code = (code << 6) | (uint32_t)(cont & 0x3Fu);
        }
        if ((extra == 1 && code < 0x80u) ||
            (extra == 2 && code < 0x800u) ||
            (extra == 3 && code < 0x10000u)) {
            return (int64_t)i + 1; /* overlong encoding */
        }
        if (code > 0x10FFFFu || (code >= 0xD800u && code <= 0xDFFFu)) {
            return (int64_t)i + 1; /* out of range, or a surrogate half */
        }
        i += extra + 1;
    }
    return 0;
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
    if (value->length > 0) {
        int64_t at = qio_utf8_invalid_at(value->data, value->length);
        if (at > 0) {
            Rf_error("qio: column '%s' is annotated as text but row %lld is "
                     "not valid UTF-8 (first bad byte at offset %lld)",
                     column, (long long)row + 1, (long long)at);
        }
    }
}

/* 16 bytes to the canonical 8-4-4-4-12 hyphenated form, lowercase.
 *
 * Formatted here rather than in the read plan because the bytes are already
 * in C: building the text in R meant one closure call and several string
 * allocations per value, about 23 microseconds each before it was vectorized
 * and 3.6 after. The output is always exactly 36 characters. */
static void qio_format_uuid(const uint8_t *bytes, char *out) {
    static const char digits[] = "0123456789abcdef";
    static const int group_bytes[] = {4, 2, 2, 2, 6};
    int at = 0;
    int byte = 0;
    for (int group = 0; group < 5; group++) {
        if (group > 0) out[at++] = '-';
        for (int k = 0; k < group_bytes[group]; k++, byte++) {
            out[at++] = digits[bytes[byte] >> 4];
            out[at++] = digits[bytes[byte] & 0x0F];
        }
    }
}

#define QIO_UUID_TEXT_LENGTH 36
#define QIO_UUID_BYTES 16

/* A UUID is FIXED_LEN_BYTE_ARRAY(16) by definition. A file that annotates a
 * different width is malformed rather than something to reinterpret. */
static void qio_check_uuid_width(int32_t type_length, const char *column) {
    if (type_length != QIO_UUID_BYTES) {
        Rf_error("qio: column '%s' is annotated as UUID but its values are %d "
                 "bytes; UUID requires exactly %d",
                 column, (int)type_length, QIO_UUID_BYTES);
    }
}

static SEXP qio_allocate_column(carquet_physical_type_t type,
                                R_xlen_t length, int kind) {
    /* A binary column is a list of raw vectors whatever its physical type. */
    if (kind == QIO_KIND_BINARY) {
        return Rf_allocVector(VECSXP, length);
    }
    /* A UUID is formatted straight to text; its bytes never reach R. */
    if (kind == QIO_KIND_UUID) {
        return Rf_allocVector(STRSXP, length);
    }
    /* R's integer is signed, so the top half of an unsigned 32-bit column
     * needs a double to stay positive. */
    if (kind == QIO_KIND_UINT32) {
        return Rf_allocVector(REALSXP, length);
    }
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

/* True when a column materializes into an R list or character vector, both of
 * which need the R API and so cannot be built on a worker thread. */
static int qio_needs_main_thread(carquet_physical_type_t type, int kind) {
    return kind == QIO_KIND_BINARY || kind == QIO_KIND_UUID ||
           type == CARQUET_PHYSICAL_BYTE_ARRAY ||
           type == CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY;
}

/* Copy one value into a raw vector element of a binary list-column. NULL
 * elements stay NULL, which is how a raw list-column spells NA. */
static void qio_set_raw_element(SEXP destination, R_xlen_t out,
                                const uint8_t *bytes, int32_t length) {
    SEXP value = PROTECT(Rf_allocVector(RAWSXP, length));
    if (length > 0) memcpy(RAW(value), bytes, (size_t)length);
    SET_VECTOR_ELT(destination, out, value);
    UNPROTECT(1);
}

/* Place one 64-bit value into an R double, per the read's `int64` mode.
 *
 * Range checks read the original 64-bit payload, never a converted double: by
 * the time a value has been through `(double)` the information needed to know
 * whether it survived is gone. Returns 1 when the value could not be kept, so
 * the caller can raise a single warning per read instead of one per value.
 *
 * In "double" mode the exact range is [-2^53, 2^53] signed and [0, 2^53]
 * unsigned. In "integer64" mode the destination holds raw int64 bits for
 * bit64, whose NA is INT64_MIN; a stored INT64_MIN and any unsigned value
 * above INT64_MAX therefore both become NA. See .agents/TYPES.md. */
static int qio_place_int64(double *dst, int64_t raw, int mode,
                           int is_unsigned) {
    if (mode == QIO_INT64_BIT64) {
        int64_t out;
        if (is_unsigned && raw < 0) {
            /* Above INT64_MAX once read as unsigned; bit64 cannot hold it. */
            out = INT64_MIN;
            memcpy(dst, &out, sizeof(out));
            return 1;
        }
        if (!is_unsigned && raw == INT64_MIN) {
            /* Indistinguishable from bit64's own NA once stored. */
            memcpy(dst, &raw, sizeof(raw));
            return 1;
        }
        memcpy(dst, &raw, sizeof(raw));
        return 0;
    }

    if (is_unsigned) {
        uint64_t value = (uint64_t)raw;
        if (value > (uint64_t)QIO_DOUBLE_EXACT_MAX) {
            *dst = NA_REAL;
            return 1;
        }
        *dst = (double)value;
        return 0;
    }

    if (raw < -QIO_DOUBLE_EXACT_MAX || raw > QIO_DOUBLE_EXACT_MAX) {
        *dst = NA_REAL;
        return 1;
    }
    *dst = (double)raw;
    return 0;
}

/* NA for a 64-bit destination: bit64 spells it INT64_MIN, not NaN. */
static void qio_place_int64_na(double *dst, int mode) {
    if (mode == QIO_INT64_BIT64) {
        int64_t na = INT64_MIN;
        memcpy(dst, &na, sizeof(na));
    } else {
        *dst = NA_REAL;
    }
}

static void qio_scatter_int64(double *dst, const void *values,
                              const int16_t *def_levels, int16_t max_def,
                              int64_t length, int mode, int is_unsigned,
                              int *coerced) {
    const int64_t *src = (const int64_t *)values;
    int any = 0;
    if (def_levels == NULL) {
        for (int64_t i = 0; i < length; i++) {
            any |= qio_place_int64(&dst[i], src[i], mode, is_unsigned);
        }
    } else {
        int64_t j = 0;
        for (int64_t i = 0; i < length; i++) {
            if (def_levels[i] == max_def) {
                any |= qio_place_int64(&dst[i], src[j++], mode, is_unsigned);
            } else {
                qio_place_int64_na(&dst[i], mode);
            }
        }
    }
    if (any && coerced) *coerced = 1;
}

static void qio_copy_batch_column(SEXP destination, R_xlen_t offset,
                                  carquet_physical_type_t type,
                                  const void *data, const uint8_t *bitmap,
                                  int64_t length, const char *column,
                                  int *sentinel, int int64_mode,
                                  int is_unsigned64, int *int64_coerced,
                                  int kind, int32_t type_length) {
    if (kind == QIO_KIND_UUID) {
        qio_check_uuid_width(type_length, column);
    }
    for (int64_t i = 0; i < length; i++) {
        R_xlen_t out = offset + (R_xlen_t)i;
        if (kind == QIO_KIND_UUID) {
            if (!qio_value_present(bitmap, i)) {
                SET_STRING_ELT(destination, out, NA_STRING);
                continue;
            }
            char text[QIO_UUID_TEXT_LENGTH];
            qio_format_uuid((const uint8_t *)data +
                                (size_t)i * (size_t)type_length,
                            text);
            SET_STRING_ELT(destination, out,
                           Rf_mkCharLenCE(text, QIO_UUID_TEXT_LENGTH, CE_UTF8));
            continue;
        }
        if (kind == QIO_KIND_BINARY) {
            /* The batch reader hands back row-aligned values, so index by row
             * rather than tracking a dense cursor. */
            if (!qio_value_present(bitmap, i)) {
                SET_VECTOR_ELT(destination, out, R_NilValue);
                continue;
            }
            if (type == CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY) {
                const uint8_t *src = (const uint8_t *)data;
                qio_set_raw_element(destination, out,
                                    src + (size_t)i * (size_t)type_length,
                                    type_length);
            } else {
                const carquet_byte_array_t *value =
                    &((const carquet_byte_array_t *)data)[i];
                if (value->length < 0 ||
                    (value->length > 0 && value->data == NULL)) {
                    Rf_error("qio: column '%s' returned an invalid byte array",
                             column);
                }
                qio_set_raw_element(destination, out, value->data,
                                    value->length);
            }
            continue;
        }
        if (!qio_value_present(bitmap, i)) {
            switch (type) {
            case CARQUET_PHYSICAL_BOOLEAN:
                LOGICAL(destination)[out] = NA_LOGICAL;
                break;
            case CARQUET_PHYSICAL_INT32:
                if (kind == QIO_KIND_UINT32) {
                    REAL(destination)[out] = NA_REAL;
                } else {
                    INTEGER(destination)[out] = NA_INTEGER;
                }
                break;
            case CARQUET_PHYSICAL_INT64:
                /* bit64 spells NA as INT64_MIN, not NaN. */
                if (int64_mode < 0) {
                    REAL(destination)[out] = NA_REAL;
                } else {
                    qio_place_int64_na(&REAL(destination)[out], int64_mode);
                }
                break;
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
            int32_t value = ((const int32_t *)data)[i];
            if (kind == QIO_KIND_UINT32) {
                REAL(destination)[out] = (double)(uint32_t)value;
                break;
            }
            /* See qio_scatter_numeric_raw: NA_INTEGER is INT_MIN. Here the
             * value is known present, so testing it directly is exact. */
            if (sentinel && value == NA_INTEGER) *sentinel = 1;
            INTEGER(destination)[out] = value;
            break;
        }
        case CARQUET_PHYSICAL_INT64:
            if (int64_mode < 0) {
                REAL(destination)[out] = (double)((const int64_t *)data)[i];
            } else if (qio_place_int64(&REAL(destination)[out],
                                       ((const int64_t *)data)[i], int64_mode,
                                       is_unsigned64) &&
                       int64_coerced) {
                *int64_coerced = 1;
            }
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
                                    int *sentinel, int int64_mode,
                                    int is_unsigned64, int *int64_coerced,
                                    int kind) {
    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN: {
        int *dst = (int *)dst_base + dst_offset;
        QIO_SCATTER_LOOP(uint8_t, dst, NA_LOGICAL, QIO_CONVERT_BOOL);
        break;
    }
    case CARQUET_PHYSICAL_INT32: {
        if (kind == QIO_KIND_UINT32) {
            /* Reinterpret the same bits as unsigned; the upper half must never
             * surface as a negative number. */
            double *out = (double *)dst_base + dst_offset;
            const int32_t *src = (const int32_t *)values;
            if (def_levels == NULL) {
                for (int64_t i = 0; i < length; i++) {
                    out[i] = (double)(uint32_t)src[i];
                }
            } else {
                int64_t j = 0;
                for (int64_t i = 0; i < length; i++) {
                    out[i] = (def_levels[i] == max_def)
                                 ? (double)(uint32_t)src[j++]
                                 : NA_REAL;
                }
            }
            break;
        }
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
        if (int64_mode < 0) {
            /* Not a plain integer column (a TIMESTAMP, say). Keep the plain
             * widening; the read plan converts it afterwards. */
            QIO_SCATTER_LOOP(int64_t, dst, NA_REAL, QIO_CONVERT_DOUBLE);
        } else {
            qio_scatter_int64(dst, values, def_levels, max_def, length,
                              int64_mode, is_unsigned64, int64_coerced);
        }
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
                                     carquet_physical_type_t type, int kind) {
    if (kind == QIO_KIND_UINT32) return REAL(destination);
    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN:
        return LOGICAL(destination);
    case CARQUET_PHYSICAL_INT32:
        return INTEGER(destination);
    default:
        return REAL(destination);
    }
}

/* Cache of CHARSXPs keyed by the address of the bytes they were built from.
 *
 * A dictionary-encoded page materializes every occurrence of a value as a
 * pointer into one decoded dictionary entry, so in a low-cardinality column
 * the same address recurs constantly: measured 200 distinct addresses across
 * 65536 rows. Rf_mkCharLenCE() hashes the bytes and probes R's global string
 * cache on every call, so caching by address turns 65536 hashes into 200.
 *
 * Keyed on (address, length) and valid only for one carquet_column_read_batch()
 * result, because the next read may reuse the same buffers for other bytes.
 * A plain-encoded page gives every value its own address, so the cache simply
 * misses and costs one probe. Cached CHARSXPs are held in a protected STRSXP:
 * a bare SEXP in C memory could otherwise be collected between allocations. */
#define QIO_CHARCACHE_BITS 10
#define QIO_CHARCACHE_SIZE (1 << QIO_CHARCACHE_BITS)

typedef struct {
    const uint8_t *key;
    int32_t length;
    int32_t slot; /* -1 when the entry is empty */
} qio_charcache_entry_t;

/* Insertions stop at half capacity so a lookup never walks a long run, and the
 * cache switches itself off when it is not paying for itself: a plain-encoded
 * column gives every value a distinct address, where probing is pure overhead.
 * Measured at +9% on a high-cardinality column before this. */
#define QIO_CHARCACHE_MAX_USED (QIO_CHARCACHE_SIZE / 2)
#define QIO_CHARCACHE_TRIAL 4096

typedef struct {
    qio_charcache_entry_t entries[QIO_CHARCACHE_SIZE];
    SEXP values; /* protected by the caller */
    int32_t used;
    int64_t lookups;
    int64_t hits;
    int enabled;
} qio_charcache_t;

static void qio_charcache_reset(qio_charcache_t *cache) {
    for (int32_t i = 0; i < QIO_CHARCACHE_SIZE; i++) cache->entries[i].slot = -1;
    cache->used = 0;
    cache->lookups = 0;
    cache->hits = 0;
    cache->enabled = 1;
}

static uint32_t qio_charcache_hash(const uint8_t *key) {
    /* Addresses are aligned, so the low bits carry little information. */
    uintptr_t value = (uintptr_t)key >> 3;
    value *= 2654435761u;
    return (uint32_t)(value & (QIO_CHARCACHE_SIZE - 1));
}

/* Returns the cached CHARSXP, or R_NilValue when the value is not cached and
 * `out_probe` receives the slot to fill. */
static SEXP qio_charcache_get(qio_charcache_t *cache, const uint8_t *key,
                              int32_t length, uint32_t *out_probe) {
    *out_probe = QIO_CHARCACHE_SIZE;
    if (!cache->enabled) return R_NilValue;
    if (++cache->lookups == QIO_CHARCACHE_TRIAL && cache->hits * 4 < cache->lookups) {
        cache->enabled = 0; /* not a dictionary column; stop paying for probes */
        return R_NilValue;
    }
    uint32_t probe = qio_charcache_hash(key);
    for (int32_t step = 0; step < 8; step++) {
        qio_charcache_entry_t *entry = &cache->entries[probe];
        if (entry->slot < 0) {
            *out_probe = probe;
            return R_NilValue;
        }
        if (entry->key == key && entry->length == length) {
            cache->hits++;
            return STRING_ELT(cache->values, entry->slot);
        }
        probe = (probe + 1) & (QIO_CHARCACHE_SIZE - 1);
    }
    *out_probe = QIO_CHARCACHE_SIZE; /* full run of probes: do not cache */
    return R_NilValue;
}

static void qio_charcache_put(qio_charcache_t *cache, uint32_t probe,
                              const uint8_t *key, int32_t length, SEXP value) {
    if (probe >= QIO_CHARCACHE_SIZE) return;
    if (cache->used >= QIO_CHARCACHE_MAX_USED) return;
    int32_t slot = cache->used++;
    SET_STRING_ELT(cache->values, slot, value);
    cache->entries[probe].key = key;
    cache->entries[probe].length = length;
    cache->entries[probe].slot = slot;
}

/* ============================================================================
 * Dictionary-preserved string materialization
 * ============================================================================
 *
 * carquet can return one uint32 index per row plus the dictionary, instead of
 * materializing a carquet_byte_array_t per row. Building the dictionary's
 * CHARSXPs once and gathering by index removes two costs at once: carquet's
 * expansion (16 bytes per row) and the address cache below, which existed only
 * to rediscover duplicates the dictionary had already identified.
 *
 * UTF-8 validation moves rather than disappears: once per distinct value
 * instead of once per row. The guarantee in ?qio-types is unchanged.
 */

/* Build the dictionary as a STRSXP. The caller must PROTECT the result
 * immediately; nothing allocates between the UNPROTECT here and the return. */
static SEXP qio_dictionary_strings(const uint8_t *data, size_t size,
                                   int32_t count, const uint32_t *offsets,
                                   const char *column) {
    SEXP dict = PROTECT(Rf_allocVector(STRSXP, count));
    for (int32_t i = 0; i < count; i++) {
        /* Both the offset and the length prefix come from the file, so every
         * entry is bounds-checked against the dictionary buffer before it is
         * read. Without this a malformed -- or merely unexpected -- dictionary
         * walks off the end of the buffer instead of failing. */
        if ((size_t)offsets[i] + 4u > size) {
            Rf_error("qio: column '%s' has a dictionary entry (%d) starting "
                     "past the end of its %llu-byte dictionary",
                     column, i + 1, (unsigned long long)size);
        }
        /* A PLAIN BYTE_ARRAY dictionary entry is a little-endian 4-byte
         * length followed by the bytes. Read it byte-wise: the entry is not
         * guaranteed to be aligned for a uint32 load. */
        const uint8_t *entry = data + offsets[i];
        uint32_t length = (uint32_t)entry[0] |
                          ((uint32_t)entry[1] << 8) |
                          ((uint32_t)entry[2] << 16) |
                          ((uint32_t)entry[3] << 24);
        if (length > (uint32_t)INT32_MAX ||
            (size_t)offsets[i] + 4u + (size_t)length > size) {
            Rf_error("qio: column '%s' has a dictionary entry (%d) of %u "
                     "bytes, which does not fit in its %llu-byte dictionary",
                     column, i + 1, length, (unsigned long long)size);
        }
        carquet_byte_array_t value;
        value.data = (uint8_t *)(entry + 4);
        value.length = (int32_t)length;
        /* Row is reported as the dictionary position: the offending bytes are
         * a property of the dictionary, and every row using this entry shares
         * them, so naming one of those rows would be arbitrary. */
        qio_check_string_bytes(&value, column, i);
        SET_STRING_ELT(dict, i,
                       Rf_mkCharLenCE(length > 0 ? (const char *)value.data : "",
                                      (int)length, CE_UTF8));
    }
    UNPROTECT(1);
    return dict;
}

static void qio_scatter_dictionary_strings(SEXP destination, R_xlen_t offset,
                                           SEXP dict, const uint32_t *indices,
                                           const int16_t *def_levels,
                                           int16_t max_def, int64_t length,
                                           const char *column) {
    R_xlen_t dict_count = XLENGTH(dict);
    int64_t j = 0;
    for (int64_t i = 0; i < length; i++) {
        R_xlen_t out = offset + (R_xlen_t)i;
        if (def_levels != NULL && def_levels[i] != max_def) {
            SET_STRING_ELT(destination, out, NA_STRING);
            continue;
        }
        uint32_t index = indices[j++];
        if ((R_xlen_t)index >= dict_count) {
            Rf_error("qio: column '%s' has a dictionary index (%u) past the "
                     "end of its %lld-entry dictionary at row %lld",
                     column, index, (long long)dict_count, (long long)i + 1);
        }
        SET_STRING_ELT(destination, out, STRING_ELT(dict, (R_xlen_t)index));
    }
}

/* Which read path each text column chunk took.
 *
 * The three paths -- dictionary indices, an abandoned attempt followed by a
 * re-read, and no attempt at all -- produce byte-identical results, so a test
 * comparing values cannot tell them apart. Without this, a regression that
 * quietly sent every column down the slowest path would pass the entire suite;
 * diagnosing exactly that during development needed a temporary fprintf build.
 *
 * Only the main thread touches these: BYTE_ARRAY columns never run on the
 * worker pool, because interning and the write barrier are R API. */
static struct {
    int64_t dictionary; /* read through preserved indices */
    int64_t fallback;   /* attempted, abandoned mid-chunk, chunk re-read */
    int64_t declined;   /* no dictionary page in the footer, never attempted */
} qio_read_paths;

SEXP qio_read_path_counters(void) {
    const char *names[] = {"dictionary", "fallback", "declined", ""};
    SEXP out = PROTECT(Rf_mkNamed(REALSXP, names));
    REAL(out)[0] = (double)qio_read_paths.dictionary;
    REAL(out)[1] = (double)qio_read_paths.fallback;
    REAL(out)[2] = (double)qio_read_paths.declined;
    /* Reading resets, so a test states what one operation did rather than
     * having to subtract a previous total. */
    qio_read_paths.dictionary = 0;
    qio_read_paths.fallback = 0;
    qio_read_paths.declined = 0;
    UNPROTECT(1);
    return out;
}

/* Read one whole column chunk through the dictionary path.
 *
 * Returns 1 when the chunk was read, 0 when the caller must fall back to the
 * materializing path. A chunk may open with a dictionary page and then switch
 * to PLAIN or RLE data pages -- rare, but Apache Arrow writes it -- and
 * preserve mode cannot represent such a page.
 *
 * Any read failure returns 0 rather than raising. A genuine decode error then
 * resurfaces on the fallback path, which reports it with the column, the row
 * group, and the encodings; distinguishing the two here would duplicate that
 * message and risk disagreeing with it. Rows already written are simply
 * overwritten when the caller re-reads the chunk from its first row. */
static int qio_collect_dictionary_chunk(carquet_reader_t *reader,
                                        int32_t row_group, int32_t file_column,
                                        carquet_column_reader_t *col,
                                        SEXP destination, R_xlen_t offset,
                                        void *value_buf, int16_t *def_buf,
                                        int16_t max_def, int64_t rows,
                                        int64_t chunk, const char *column) {
    /* Ask the footer first. Preservation is only meaningful for a chunk that
     * actually carries a dictionary page, and skipping the attempt for the
     * rest avoids decoding a page just to throw it away. */
    carquet_column_chunk_metadata_t meta;
    if (carquet_reader_column_chunk_metadata(reader, row_group, file_column,
                                             &meta) != CARQUET_OK ||
        !meta.has_dictionary_page) {
        qio_read_paths.declined++;
        return 0;
    }

    const uint8_t *dict_data = NULL;
    size_t dict_size = 0;
    int32_t dict_count = 0;
    const uint32_t *dict_offsets = NULL;

    if (carquet_column_set_preserve_dictionary(col, true) != CARQUET_OK) {
        qio_read_paths.fallback++;
        return 0;
    }
    /* A zero-length read loads the first page, and with it the dictionary
     * page, without consuming any rows. */
    if (carquet_column_read_batch(col, value_buf, 0, NULL, NULL) < 0) {
        qio_read_paths.fallback++;
        return 0;
    }
    if (!carquet_column_get_dictionary(col, &dict_data, &dict_size,
                                       &dict_count, &dict_offsets)) {
        qio_read_paths.fallback++;
        return 0; /* no dictionary: a plain chunk, nothing to gain */
    }
    if (dict_offsets == NULL || dict_count < 0) {
        qio_read_paths.fallback++;
        return 0; /* fixed-width dictionary; not a BYTE_ARRAY layout */
    }

    SEXP dict = PROTECT(qio_dictionary_strings(dict_data, dict_size, dict_count,
                                               dict_offsets, column));
    int16_t *def_ptr = (max_def > 0) ? def_buf : NULL;
    for (int64_t read = 0; read < rows;) {
        int64_t want = rows - read;
        if (want > chunk) want = chunk;
        int64_t n = carquet_column_read_batch(col, value_buf, want, def_ptr,
                                              NULL);
        if (n <= 0 || n != want) {
            UNPROTECT(1);
            qio_read_paths.fallback++;
            return 0; /* fallback page, short read, or error */
        }
        qio_scatter_dictionary_strings(destination,
                                       offset + (R_xlen_t)read, dict,
                                       (const uint32_t *)value_buf, def_ptr,
                                       max_def, n, column);
        read += n;
    }
    UNPROTECT(1);
    qio_read_paths.dictionary++;
    return 1;
}

static void qio_scatter_dense_column(SEXP destination, R_xlen_t offset,
                                     carquet_physical_type_t type,
                                     const void *values,
                                     const int16_t *def_levels,
                                     int16_t max_def, int64_t length,
                                     const char *column, int *sentinel,
                                     int int64_mode, int is_unsigned64,
                                     int *int64_coerced, int kind,
                                     int32_t type_length) {
    if (kind == QIO_KIND_UUID) {
        qio_check_uuid_width(type_length, column);
        int64_t j = 0;
        for (int64_t i = 0; i < length; i++) {
            R_xlen_t out = offset + (R_xlen_t)i;
            if (def_levels != NULL && def_levels[i] != max_def) {
                SET_STRING_ELT(destination, out, NA_STRING);
                continue;
            }
            char text[QIO_UUID_TEXT_LENGTH];
            qio_format_uuid((const uint8_t *)values +
                                (size_t)j * (size_t)type_length,
                            text);
            j++;
            SET_STRING_ELT(destination, out,
                           Rf_mkCharLenCE(text, QIO_UUID_TEXT_LENGTH, CE_UTF8));
        }
        return;
    }
    if (kind == QIO_KIND_BINARY) {
        int64_t j = 0;
        for (int64_t i = 0; i < length; i++) {
            R_xlen_t out = offset + (R_xlen_t)i;
            if (def_levels != NULL && def_levels[i] != max_def) {
                SET_VECTOR_ELT(destination, out, R_NilValue);
                continue;
            }
            if (type == CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY) {
                /* Values are packed at exactly type_length bytes each. */
                const uint8_t *src = (const uint8_t *)values;
                qio_set_raw_element(destination, out,
                                    src + (size_t)j * (size_t)type_length,
                                    type_length);
            } else {
                const carquet_byte_array_t *value =
                    &((const carquet_byte_array_t *)values)[j];
                if (value->length < 0 ||
                    (value->length > 0 && value->data == NULL)) {
                    Rf_error("qio: column '%s' returned an invalid byte array",
                             column);
                }
                qio_set_raw_element(destination, out, value->data,
                                    value->length);
            }
            j++;
        }
        return;
    }

    switch (type) {
    case CARQUET_PHYSICAL_BYTE_ARRAY: {
        /* Strings must go through SET_STRING_ELT (write barrier) and
         * Rf_mkCharLenCE (interning). Repeated dictionary values are served
         * from the address cache, so validation and interning happen once per
         * distinct value rather than once per row. */
        const carquet_byte_array_t *src =
            (const carquet_byte_array_t *)values;
        qio_charcache_t cache;
        cache.values = PROTECT(Rf_allocVector(STRSXP, QIO_CHARCACHE_SIZE));
        qio_charcache_reset(&cache);
        int64_t j = 0;
        for (int64_t i = 0; i < length; i++) {
            R_xlen_t out = offset + (R_xlen_t)i;
            if (def_levels != NULL && def_levels[i] != max_def) {
                SET_STRING_ELT(destination, out, NA_STRING);
                continue;
            }
            const carquet_byte_array_t *value = &src[j++];
            uint32_t probe = 0;
            SEXP cached = value->length > 0
                              ? qio_charcache_get(&cache, value->data,
                                                  value->length, &probe)
                              : R_NilValue;
            if (cached != R_NilValue) {
                SET_STRING_ELT(destination, out, cached);
                continue;
            }
            qio_check_string_bytes(value, column, i);
            const char *bytes = value->length > 0
                                    ? (const char *)value->data
                                    : "";
            SEXP made = Rf_mkCharLenCE(bytes, value->length, CE_UTF8);
            SET_STRING_ELT(destination, out, made);
            if (value->length > 0) {
                qio_charcache_put(&cache, probe, value->data, value->length,
                                  made);
            }
        }
        UNPROTECT(1);
        break;
    }
    default:
        qio_scatter_numeric_raw(qio_column_data_pointer(destination, type, kind),
                                offset, type, values, def_levels, max_def,
                                length, sentinel, int64_mode, is_unsigned64,
                                int64_coerced, kind);
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

/* Below this many selected rows a buffered parallel collect is not worth it:
 * every private reader re-parses the footer, and that fixed cost dominates a
 * small read. Chosen by measurement; see bench/README.md. */
#define QIO_PRIVATE_READER_MIN_ROWS 50000

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
    int int64_mode;
    int is_unsigned64;
    int int64_coerced;   /* task-local; merged with int32_sentinel */
    int decode_failed;   /* carquet returned an error, not a short read */
    int kind;
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
        if (n < 0) {
            /* A decode failure, not a short read. Workers cannot call the R
             * API, so the main thread turns this into a message naming the
             * column's encodings. */
            task->decode_failed = 1;
            task->status = 1;
            goto done;
        }
        if (n != want) {
            snprintf(task->message, sizeof(task->message),
                     "column %d of row group %d yielded %lld of %lld rows",
                     task->file_column + 1, task->row_group + 1,
                     (long long)(read + n), (long long)task->rows);
            task->status = 1;
            goto done;
        }
        qio_scatter_numeric_raw(task->dst, task->dst_offset + read,
                                task->type, values, defs, task->max_def, n,
                                &task->int32_sentinel, task->int64_mode,
                                task->is_unsigned64, &task->int64_coerced,
                                task->kind);
        read += n;
    }

done:
    free(values);
    free(defs);
    carquet_column_reader_free(column);
}

/* A lane is a group of tasks that share one reader and therefore must run one
 * after another. Memory-mapped reads need no lanes, because every column
 * reader on a mapped file is independent; buffered reads do, because they
 * share FILE* and prebuffer state. One lane runs on one worker, so the reader
 * it owns is never touched concurrently. */
typedef struct {
    qio_column_task_t **tasks;
    int32_t num_tasks;
} qio_lane_t;

static void qio_lane_run(void *arg) {
    qio_lane_t *lane = (qio_lane_t *)arg;
    for (int32_t i = 0; i < lane->num_tasks; i++) {
        qio_column_task_run(lane->tasks[i]);
        /* Stop this lane at its first failure; the reader's position is
         * undefined afterwards. Other lanes are unaffected and the main thread
         * reports the first error it finds. */
        if (lane->tasks[i]->status) return;
    }
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

/* Describe a column's encodings for an error message. carquet's
 * carquet_column_read_batch() returns a bare negative on failure, discarding
 * the status and hint its internals produced, so a column whose encoding is
 * not supported is indistinguishable from a short read. Naming the encodings
 * is the most useful thing available through the public API. */
static const char *qio_column_encodings(carquet_reader_t *reader,
                                        int32_t row_group, int32_t column) {
    carquet_column_chunk_metadata_t meta;
    if (carquet_reader_column_chunk_metadata(reader, row_group, column,
                                             &meta) != CARQUET_OK) {
        return "unknown";
    }
    char *out = (char *)R_alloc(256, sizeof(char));
    out[0] = '\0';
    size_t at = 0;
    for (int32_t i = 0; i < meta.num_encodings && at < 200; i++) {
        int written = snprintf(out + at, 256 - at, "%s%s", at ? ", " : "",
                               carquet_encoding_name(meta.encodings[i]));
        if (written <= 0) break;
        at += (size_t)written;
    }
    return out[0] ? out : "unknown";
}

static void qio_prepare_selection(qio_parquet_handle_t *handle,
                                  SEXP columns, SEXP row_groups,
                                  SEXP column_kinds,
                                  qio_selection_t *selection) {
    const carquet_schema_t *schema =
        carquet_reader_schema(handle->reader);
    int32_t file_columns = carquet_reader_num_columns(handle->reader);

    /* R validates these before calling, but every other entry point re-checks
     * what it dereferences; INTEGER() on a REALSXP would silently reinterpret
     * memory rather than fail. */
    if (columns != R_NilValue && TYPEOF(columns) != INTSXP) {
        Rf_error("qio: `columns` must be an integer vector or NULL");
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
        /* Already resolved from complete schema paths by qio_resolve_columns().
         * carquet_schema_find_column() is deliberately not used: it compares
         * leaf names only, so a name shared by two leaves under different
         * parents resolves to whichever comes first. */
        selection->num_columns = Rf_length(columns);
        selection->columns = (int32_t *)R_alloc(
            (size_t)(selection->num_columns > 0 ? selection->num_columns : 1),
            sizeof(int32_t));
        for (int32_t i = 0; i < selection->num_columns; i++) {
            int index = INTEGER(columns)[i];
            if (index == NA_INTEGER || index < 1 || index > file_columns) {
                Rf_error("qio: column index %d is out of range [1, %d]",
                         index, file_columns);
            }
            selection->columns[i] = index - 1;
        }
    }

    size_t flags = (size_t)(selection->num_columns > 0
                                ? selection->num_columns
                                : 1);
    selection->unsigned64 = (uint8_t *)R_alloc(flags, sizeof(uint8_t));
    memset(selection->unsigned64, 0, flags);
    selection->kind = (uint8_t *)R_alloc(flags, sizeof(uint8_t));
    memset(selection->kind, 0, flags);
    selection->type_length = (int32_t *)R_alloc(flags, sizeof(int32_t));
    memset(selection->type_length, 0, flags * sizeof(int32_t));

    /* One kind per selected column, produced by the read plan. */
    if (TYPEOF(column_kinds) != INTSXP ||
        Rf_length(column_kinds) != selection->num_columns) {
        Rf_error("qio: `column_kinds` must have one entry per selected column");
    }
    for (int32_t i = 0; i < selection->num_columns; i++) {
        int kind = INTEGER(column_kinds)[i];
        if (kind < QIO_KIND_DEFAULT || kind > QIO_KIND_UUID) {
            Rf_error("qio: invalid column kind %d", kind);
        }
        selection->kind[i] = (uint8_t)kind;
    }

    for (int32_t i = 0; i < selection->num_columns; i++) {
        int32_t column = selection->columns[i];
        const char **parts = NULL;
        int32_t depth = qio_column_path_parts(schema, column, &parts);
        (void)parts;

        /* An unsigned 64-bit annotation changes how the same bits are read, so
         * resolve it once here rather than per value or per row group. */
        const carquet_schema_node_t *node = qio_leaf_node_at(schema, column);
        const carquet_logical_type_t *logical =
            node ? carquet_schema_node_logical_type(node) : NULL;
        if (logical && logical->id == CARQUET_LOGICAL_INTEGER &&
            logical->params.integer.bit_width == 64 &&
            !logical->params.integer.is_signed) {
            selection->unsigned64[i] = 1;
        }
        selection->type_length[i] =
            node ? carquet_schema_node_type_length(node) : 0;
        carquet_physical_type_t type =
            carquet_schema_column_type(schema, column);
        /* R drops nested leaves before selecting, so this is a backstop. */
        if (depth > 1 || carquet_schema_max_rep_level(schema, column) > 0) {
            Rf_error("qio: column '%s' is nested or repeated; nested reading "
                     "is deferred to qio 0.2.0",
                     qio_column_path_cstr(schema, column));
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
        case CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY:
            /* Raw bytes, or UUID text formatted here. Every other mapping
             * (FLOAT16, DECIMAL) is produced by the read plan from the bytes. */
            if (selection->kind[i] != QIO_KIND_BINARY &&
                selection->kind[i] != QIO_KIND_UUID) {
                Rf_error("qio: column '%s' is FIXED_LEN_BYTE_ARRAY but the "
                         "read plan did not ask for raw bytes",
                         qio_column_path_cstr(schema, column));
            }
            if (selection->type_length[i] <= 0) {
                Rf_error("qio: column '%s' declares an invalid "
                         "FIXED_LEN_BYTE_ARRAY width of %d",
                         qio_column_path_cstr(schema, column),
                         selection->type_length[i]);
            }
            break;
        default:
            Rf_error("qio: column '%s' has unsupported physical type %s "
                     "(logical type: %s, type_length: %d)",
                     qio_column_path_cstr(schema, column),
                     carquet_physical_type_name(type),
                     qio_logical_description(schema, column),
                     carquet_schema_node_type_length(
                         qio_leaf_node_at(schema, column)));
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
        SET_VECTOR_ELT(
            result, i,
            qio_allocate_column(type, rows, context->selection.kind[i]));
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
            &context->int32_sentinel,
            context->selection.kind[i] == QIO_KIND_INT64 ? context->int64_mode
                                                         : -1,
            context->selection.unsigned64[i], &context->int64_coerced,
            context->selection.kind[i], context->selection.type_length[i]);
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

/* One warning per operation, aggregated across signed and unsigned columns.
 * The two messages are fixed by .agents/TYPES.md. */
static void qio_warn_int64_coerced(const qio_batch_context_t *context) {
    if (!context->int64_coerced) return;
    if (context->int64_mode == QIO_INT64_BIT64) {
        Rf_warning("Some INT64 or UINT64 values were coerced to NA because "
                   "they cannot be represented by bit64::integer64.");
    } else {
        Rf_warning("Some INT64 or UINT64 values were coerced to NA because "
                   "they cannot be represented exactly as R doubles; use "
                   "int64 = \"integer64\" to preserve the supported 64-bit "
                   "range.");
    }
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
    int has_main_thread = 0;
    for (int32_t s = 0; s < n_groups; s++) {
        for (int32_t i = 0; i < ncol; i++) {
            int32_t file_col = context->selection.columns[i];
            carquet_physical_type_t type =
                carquet_schema_column_type(schema, file_col);
            if (qio_needs_main_thread(type, context->selection.kind[i])) {
                has_main_thread = 1;
                continue;
            }
            qio_column_task_t *task = &tasks[n_tasks++];
            memset(task, 0, sizeof(*task));
            task->reader = reader;
            task->row_group = rg_index[s];
            task->file_column = file_col;
            task->type = type;
            task->max_def = carquet_schema_max_def_level(schema, file_col);
            task->dst = qio_column_data_pointer(VECTOR_ELT(result, i), type,
                                               context->selection.kind[i]);
            task->dst_offset = rg_offset[s];
            task->rows = rg_rows[s];
            task->int64_mode = context->selection.kind[i] == QIO_KIND_INT64
                                   ? context->int64_mode
                                   : -1;
            task->is_unsigned64 = context->selection.unsigned64[i];
            task->kind = context->selection.kind[i];
        }
    }

    /* Numeric tasks run on carquet's worker pool whenever there is more than
     * one of them and the caller did not ask for a serial read.
     *
     * A mapped reader is shared: every column reader on it is independent. A
     * buffered reader is not, so each worker gets a private reader opened on
     * the same path with the same options, and tasks are grouped into lanes so
     * that one reader is only ever used by one lane at a time. Measured worth
     * about 2.6x on a buffered handle, which is what parquet_open() defaults
     * to; see bench/README.md.
     *
     * Opening a private reader re-parses the footer, so the buffered path is
     * only taken when there are enough rows to amortize that. */
    int32_t threads = qio_collect_threads(context->handle->threads);
    int use_lanes = 0;
    if (context->handle->threads != 1 && threads > 1 && n_tasks > 1) {
        if (threads > n_tasks) threads = n_tasks;
        if (carquet_reader_is_mmap(reader)) {
            context->pool = carquet_worker_pool_create(threads);
        } else if (context->selection.total_rows >= QIO_PRIVATE_READER_MIN_ROWS) {
            use_lanes = 1;
        }
        /* A NULL pool just means no parallelism; the inline path follows. */
    }

    qio_lane_t *lanes = NULL;
    if (use_lanes) {
        qio_path_t path;
        qio_path_resolve(R_ExternalPtrProtected(context->file), &path);
        carquet_reader_options_t options;
        carquet_reader_options_init(&options);
        options.use_mmap = 0;
        options.verify_checksums = context->handle->verify_checksums;
        options.num_threads = 1;

        carquet_reader_t **readers = (carquet_reader_t **)R_alloc(
            (size_t)threads, sizeof(carquet_reader_t *));
        memset(readers, 0, (size_t)threads * sizeof(carquet_reader_t *));
        /* One stream per lane, opened here for the same reason the handle's is:
         * carquet's own path entry point cannot reach a path outside Windows'
         * active code page, and a lane that failed to open would silently cost
         * the read its parallelism. */
        FILE **streams = (FILE **)R_alloc((size_t)threads, sizeof(FILE *));
        memset(streams, 0, (size_t)threads * sizeof(FILE *));
        int32_t opened = 0;
        for (int32_t i = 0; i < threads; i++) {
            carquet_error_t err = CARQUET_ERROR_INIT;
            streams[i] = qio_path_fopen(&path, "rb");
            if (!streams[i]) break; /* fall back to fewer lanes, or to serial */
            readers[i] = carquet_reader_open_file(streams[i], &options, &err);
            if (!readers[i]) {
                fclose(streams[i]);
                streams[i] = NULL;
                break;
            }
            opened++;
        }
        /* Registered before use so an unwind from here on closes them. */
        context->private_readers = readers;
        context->private_streams = streams;
        context->num_private_readers = opened;

        if (opened > 1) {
            lanes = (qio_lane_t *)R_alloc((size_t)opened, sizeof(qio_lane_t));
            qio_column_task_t **slots = (qio_column_task_t **)R_alloc(
                (size_t)n_tasks, sizeof(qio_column_task_t *));
            /* Round-robin so lanes get comparable work; tasks are one row
             * group by one column, so they are of similar size. */
            int32_t at = 0;
            for (int32_t lane = 0; lane < opened; lane++) {
                lanes[lane].tasks = slots + at;
                lanes[lane].num_tasks = 0;
                for (int32_t t = lane; t < n_tasks; t += opened) {
                    slots[at++] = &tasks[t];
                    lanes[lane].num_tasks++;
                    tasks[t].reader = readers[lane];
                }
            }
            context->pool = carquet_worker_pool_create(opened);
            if (!context->pool) lanes = NULL;
            if (!lanes) {
                /* Reverting to the shared reader for the inline path. */
                for (int32_t t = 0; t < n_tasks; t++) tasks[t].reader = reader;
            }
        } else {
            lanes = NULL;
        }
    }

    if (lanes) {
        /* One submission per lane, so a lane's tasks never overlap. */
        for (int32_t lane = 0; lane < context->num_private_readers; lane++) {
            carquet_worker_pool_submit(context->pool, qio_lane_run,
                                       &lanes[lane]);
        }
    }

    int32_t submitted = 0;
    if (lanes) {
        /* Every task is already queued, inside its lane. Nothing runs here:
         * running them inline as well would execute each task twice, once on a
         * worker and once on the main thread, against the same reader. */
        submitted = n_tasks;
    } else if (context->pool) {
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
                if (tasks[t].decode_failed) {
                    Rf_error("qio: cannot decode column '%s' of row group %d; "
                             "its encodings are %s and one of them is not "
                             "supported",
                             carquet_schema_column_name(schema,
                                                        tasks[t].file_column),
                             tasks[t].row_group + 1,
                             qio_column_encodings(reader, tasks[t].row_group,
                                                  tasks[t].file_column));
                }
                Rf_error("qio: %s", tasks[t].message);
            }
            R_CheckUserInterrupt();
        }
        submitted = n_tasks;
    }

    /* String columns on the main thread (interning and the write barrier are
     * R API), overlapping the workers. An error here unwinds through
     * qio_batch_cleanup, which waits for the pool before the jump continues.
     * Binary columns build R lists, so they belong here too. */
    if (has_main_thread) {
        /* One value buffer for every main-thread column, so size it for the
         * widest: a variable byte array descriptor, or a fixed-width value. */
        size_t value_width = sizeof(carquet_byte_array_t);
        for (int32_t i = 0; i < ncol; i++) {
            if (context->selection.type_length[i] > 0 &&
                (size_t)context->selection.type_length[i] > value_width) {
                value_width = (size_t)context->selection.type_length[i];
            }
        }
        /* Scratch is bounded by batch_size, not by the largest row group. A
         * row group can hold millions of rows, and sizing the buffer to it
         * made peak memory a property of the file rather than of anything the
         * caller controls. Each column is read in batch_size chunks and
         * scattered as it goes; this is what gives collect(batch_size =) its
         * observable effect. */
        int64_t chunk = context->batch_size;
        if (chunk > max_rg_rows) chunk = max_rg_rows;
        if (chunk < 1) chunk = 1;
        void *value_buf = R_alloc((size_t)chunk, (int)value_width);
        int16_t *def_buf = (int16_t *)R_alloc((size_t)chunk, sizeof(int16_t));
        for (int32_t s = 0; s < n_groups; s++) {
            for (int32_t i = 0; i < ncol; i++) {
                int32_t file_col = context->selection.columns[i];
                carquet_physical_type_t type =
                    carquet_schema_column_type(schema, file_col);
                if (!qio_needs_main_thread(type, context->selection.kind[i])) {
                    continue;
                }
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

                /* Text columns try the dictionary path first. It is declined
                 * for a chunk with no dictionary page, and abandoned for one
                 * that starts dictionary-encoded and later falls back to
                 * PLAIN. Either way the chunk is re-read from its first row by
                 * the materializing path below, overwriting anything the
                 * attempt wrote. */
                if (context->selection.kind[i] == QIO_KIND_TEXT &&
                    type == CARQUET_PHYSICAL_BYTE_ARRAY) {
                    if (qio_collect_dictionary_chunk(
                            reader, rg_index[s], file_col, col,
                            VECTOR_ELT(result, i), rg_offset[s],
                            value_buf, def_buf, max_def, rg_rows[s], chunk,
                            carquet_schema_column_name(schema, file_col))) {
                        carquet_column_reader_free(col);
                        context->column = NULL;
                        continue;
                    }
                    /* Declined or abandoned. Preserve mode may have consumed
                     * pages first and a column reader has no rewind, so start
                     * over on a fresh one; carquet_reader_get_column()
                     * allocates per call. */
                    carquet_column_reader_free(col);
                    context->column = NULL;
                    col = carquet_reader_get_column(reader, rg_index[s],
                                                    file_col, &err);
                    if (!col) {
                        char message[512];
                        carquet_error_format(&err, message, sizeof(message));
                        Rf_error("qio: cannot open column %d of row group "
                                 "%d: %s",
                                 file_col + 1, rg_index[s] + 1, message);
                    }
                    context->column = col;
                }

                int16_t *def_ptr = (max_def > 0) ? def_buf : NULL;
                for (int64_t read = 0; read < rg_rows[s];) {
                    int64_t want = rg_rows[s] - read;
                    if (want > chunk) want = chunk;
                    int64_t n = carquet_column_read_batch(col, value_buf, want,
                                                          def_ptr, NULL);
                    if (n < 0) {
                        Rf_error("qio: cannot decode column '%s' of row group "
                                 "%d; its encodings are %s and one of them is "
                                 "not supported",
                                 carquet_schema_column_name(schema, file_col),
                                 rg_index[s] + 1,
                                 qio_column_encodings(reader, rg_index[s],
                                                      file_col));
                    }
                    if (n != want) {
                        Rf_error("qio: column '%s' of row group %d yielded %lld "
                                 "of %lld rows",
                                 carquet_schema_column_name(schema, file_col),
                                 rg_index[s] + 1, (long long)(read + n),
                                 (long long)rg_rows[s]);
                    }
                    /* Scatter before the next read: BYTE_ARRAY values point
                     * into the column reader's page buffers, which the next
                     * read may release. */
                    qio_scatter_dense_column(
                        VECTOR_ELT(result, i), rg_offset[s] + (R_xlen_t)read,
                        type, value_buf, def_ptr, max_def, n,
                        carquet_schema_column_name(schema, file_col),
                        &context->int32_sentinel,
                        context->selection.kind[i] == QIO_KIND_INT64
                            ? context->int64_mode
                            : -1,
                        context->selection.unsigned64[i],
                        &context->int64_coerced, context->selection.kind[i],
                        context->selection.type_length[i]);
                    read += n;
                }
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
            if (tasks[t].decode_failed) {
                Rf_error("qio: cannot decode column '%s' of row group %d; its "
                         "encodings are %s and one of them is not supported",
                         carquet_schema_column_name(schema,
                                                    tasks[t].file_column),
                         tasks[t].row_group + 1,
                         qio_column_encodings(reader, tasks[t].row_group,
                                              tasks[t].file_column));
            }
            Rf_error("qio: %s", tasks[t].message);
        }
        if (tasks[t].int32_sentinel) context->int32_sentinel = 1;
        if (tasks[t].int64_coerced) context->int64_coerced = 1;
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
    /* Closed only after the pool has stopped: a worker may still be reading
     * through one of these. */
    if (context->private_readers) {
        for (int32_t i = 0; i < context->num_private_readers; i++) {
            if (context->private_readers[i]) {
                carquet_reader_close(context->private_readers[i]);
                context->private_readers[i] = NULL;
            }
            /* After its reader, which reads through it until closed. */
            if (context->private_streams && context->private_streams[i]) {
                fclose(context->private_streams[i]);
                context->private_streams[i] = NULL;
            }
        }
        context->private_readers = NULL;
        context->private_streams = NULL;
        context->num_private_readers = 0;
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

/* R passes the validated `int64` option as a small integer code. */
static int qio_int64_mode(SEXP mode) {
    int value = Rf_asInteger(mode);
    if (value != QIO_INT64_DOUBLE && value != QIO_INT64_BIT64) {
        Rf_error("qio: invalid `int64` mode");
    }
    return value;
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

    qio_path_t file_path;
    qio_path_resolve(path, &file_path);

    /* Mapping is the one thing qio cannot do through a stream, because carquet
     * maps from a path. So a mapped read keeps the path entry point, and only
     * falls back to buffered I/O when the path cannot survive the active code
     * page -- Windows only, and preferable to refusing the file. Buffered reads
     * always go through the stream, which keeps this code on the common path
     * for every platform rather than only the one that needs it.
     *
     * The fallback costs little: buffered collects have been parallel since the
     * private-reader work, so the two paths are close in speed. */
    int mapped = options.use_mmap && qio_path_opens_natively(&file_path);
    options.use_mmap = mapped;

    FILE *stream = NULL;
    if (!mapped) {
        stream = qio_path_fopen(&file_path, "rb");
        if (!stream) {
            Rf_error("qio: cannot open '%s'", file_path.display);
        }
    }

    carquet_error_t native_error = CARQUET_ERROR_INIT;
    carquet_reader_t *reader =
        mapped ? carquet_reader_open(file_path.native, &options, &native_error)
               : carquet_reader_open_file(stream, &options, &native_error);
    if (!reader) {
        char message[512];
        carquet_error_format(&native_error, message, sizeof(message));
        if (stream) fclose(stream);
        Rf_error("qio: cannot open '%s': %s", file_path.display, message);
    }

    qio_parquet_handle_t *handle =
        (qio_parquet_handle_t *)calloc(1, sizeof(qio_parquet_handle_t));
    if (!handle) {
        carquet_reader_close(reader);
        if (stream) fclose(stream);
        Rf_error("qio: cannot allocate parquet file handle");
    }
    handle->reader = reader;
    handle->file = stream;
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

/* Physical width of a statistics min/max payload, or 0 when the type is
 * variable-length. Statistics are PLAIN-encoded, so a fixed-width type has one
 * exact size and anything else is a malformed footer to be ignored rather than
 * decoded. */
static int32_t qio_statistic_width(carquet_physical_type_t type,
                                   int32_t type_length) {
    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN: return 1;
    case CARQUET_PHYSICAL_INT32:
    case CARQUET_PHYSICAL_FLOAT: return 4;
    case CARQUET_PHYSICAL_INT64:
    case CARQUET_PHYSICAL_DOUBLE: return 8;
    case CARQUET_PHYSICAL_INT96: return 12;
    case CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY: return type_length;
    default: return 0; /* BYTE_ARRAY */
    }
}

/* One statistics bound as an R value.
 *
 * These are the writer's claims about its own data, decoded at the physical
 * level only: no timestamp becomes a POSIXct and no decimal is scaled, because
 * a bound is a sort key rather than a value to compute with, and silently
 * reinterpreting it would invite arithmetic that the annotation does not
 * license. Text is the exception, since a string bound is unreadable as bytes.
 *
 * Returns R_NilValue when the bound is absent or the wrong width, which the
 * caller stores as NULL rather than guessing. */
static SEXP qio_statistic_value(const void *bytes, int32_t size,
                                carquet_physical_type_t type,
                                int32_t type_length, int is_text) {
    if (!bytes || size < 0) return R_NilValue;
    int32_t width = qio_statistic_width(type, type_length);
    if (width > 0 && size != width) return R_NilValue;

    switch (type) {
    case CARQUET_PHYSICAL_BOOLEAN:
        return Rf_ScalarLogical(((const uint8_t *)bytes)[0] != 0);
    case CARQUET_PHYSICAL_INT32: {
        int32_t value;
        memcpy(&value, bytes, sizeof(value));
        /* R's integer reserves INT_MIN for NA, so a legal Parquet bound of
         * -2147483648 would read as missing; widen it instead. */
        if (value == NA_INTEGER) return Rf_ScalarReal((double)value);
        return Rf_ScalarInteger(value);
    }
    case CARQUET_PHYSICAL_INT64: {
        int64_t value;
        memcpy(&value, bytes, sizeof(value));
        return Rf_ScalarReal((double)value);
    }
    case CARQUET_PHYSICAL_FLOAT: {
        float value;
        memcpy(&value, bytes, sizeof(value));
        return Rf_ScalarReal((double)value);
    }
    case CARQUET_PHYSICAL_DOUBLE: {
        double value;
        memcpy(&value, bytes, sizeof(value));
        return Rf_ScalarReal(value);
    }
    default:
        break;
    }

    if (type == CARQUET_PHYSICAL_BYTE_ARRAY && is_text) {
        /* Positive is the 1-based offset of the first bad byte; 0 means the
         * whole range is well formed. */
        if (qio_utf8_invalid_at((const uint8_t *)bytes, size) > 0) {
            return R_NilValue; /* annotated as text but not valid UTF-8 */
        }
        return Rf_ScalarString(
            Rf_mkCharLenCE((const char *)bytes, (int)size, CE_UTF8));
    }

    SEXP raw = PROTECT(Rf_allocVector(RAWSXP, size));
    if (size > 0) memcpy(RAW(raw), bytes, (size_t)size);
    UNPROTECT(1);
    return raw;
}

SEXP qio_parquet_column_chunks(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    const carquet_schema_t *schema = carquet_reader_schema(handle->reader);
    int32_t groups = carquet_reader_num_row_groups(handle->reader);
    int32_t columns = carquet_reader_num_columns(handle->reader);
    R_xlen_t rows = (R_xlen_t)groups * columns;

    const int ncol = 12;
    const char *column_names[] = {
        "row_group",       "column",      "name",         "type",
        "compression",     "num_values",  "compressed_bytes",
        "uncompressed_bytes", "encodings", "dictionary_page",
        "bloom_filter",    "page_index"};
    SEXP result = PROTECT(Rf_allocVector(VECSXP, ncol));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, ncol));
    SET_VECTOR_ELT(result, 0, Rf_allocVector(INTSXP, rows));
    SET_VECTOR_ELT(result, 1, Rf_allocVector(INTSXP, rows));
    SET_VECTOR_ELT(result, 2, Rf_allocVector(STRSXP, rows));
    SET_VECTOR_ELT(result, 3, Rf_allocVector(STRSXP, rows));
    SET_VECTOR_ELT(result, 4, Rf_allocVector(STRSXP, rows));
    SET_VECTOR_ELT(result, 5, Rf_allocVector(REALSXP, rows));
    SET_VECTOR_ELT(result, 6, Rf_allocVector(REALSXP, rows));
    SET_VECTOR_ELT(result, 7, Rf_allocVector(REALSXP, rows));
    SET_VECTOR_ELT(result, 8, Rf_allocVector(STRSXP, rows));
    SET_VECTOR_ELT(result, 9, Rf_allocVector(LGLSXP, rows));
    SET_VECTOR_ELT(result, 10, Rf_allocVector(LGLSXP, rows));
    SET_VECTOR_ELT(result, 11, Rf_allocVector(LGLSXP, rows));
    for (int i = 0; i < ncol; i++)
        SET_STRING_ELT(names, i, Rf_mkChar(column_names[i]));

    R_xlen_t at = 0;
    for (int32_t g = 0; g < groups; g++) {
        for (int32_t c = 0; c < columns; c++, at++) {
            carquet_column_chunk_metadata_t chunk;
            carquet_status_t status = carquet_reader_column_chunk_metadata(
                handle->reader, g, c, &chunk);
            if (status != CARQUET_OK) {
                Rf_error("qio: cannot inspect column %d of row group %d: %s",
                         c + 1, g + 1, carquet_status_string(status));
            }
            INTEGER(VECTOR_ELT(result, 0))[at] = g + 1;
            INTEGER(VECTOR_ELT(result, 1))[at] = c + 1;
            SET_STRING_ELT(VECTOR_ELT(result, 2), at,
                           qio_column_path_string(schema, c));
            SET_STRING_ELT(VECTOR_ELT(result, 3), at,
                           Rf_mkChar(carquet_physical_type_name(chunk.type)));
            SET_STRING_ELT(VECTOR_ELT(result, 4), at,
                           Rf_mkChar(carquet_compression_name(chunk.codec)));
            REAL(VECTOR_ELT(result, 5))[at] = (double)chunk.num_values;
            REAL(VECTOR_ELT(result, 6))[at] =
                (double)chunk.total_compressed_size;
            REAL(VECTOR_ELT(result, 7))[at] =
                (double)chunk.total_uncompressed_size;

            /* One comma-separated string rather than a list column: the set is
             * tiny, bounded at four, and useful mostly for reading. */
            char encodings[128];
            size_t used = 0;
            encodings[0] = '\0';
            for (int32_t e = 0; e < chunk.num_encodings && e < 4; e++) {
                const char *name = carquet_encoding_name(chunk.encodings[e]);
                int wrote = snprintf(encodings + used, sizeof(encodings) - used,
                                     "%s%s", used ? ", " : "", name);
                if (wrote < 0 || (size_t)wrote >= sizeof(encodings) - used) break;
                used += (size_t)wrote;
            }
            SET_STRING_ELT(VECTOR_ELT(result, 8), at, Rf_mkChar(encodings));

            LOGICAL(VECTOR_ELT(result, 9))[at] = chunk.has_dictionary_page;
            LOGICAL(VECTOR_ELT(result, 10))[at] = chunk.has_bloom_filter;
            LOGICAL(VECTOR_ELT(result, 11))[at] =
                chunk.has_column_index || chunk.has_offset_index;
        }
    }

    qio_set_data_frame_attributes(result, names, (int32_t)rows);
    UNPROTECT(2);
    return result;
}

SEXP qio_parquet_column_statistics(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    const carquet_schema_t *schema = carquet_reader_schema(handle->reader);
    int32_t groups = carquet_reader_num_row_groups(handle->reader);
    int32_t columns = carquet_reader_num_columns(handle->reader);
    R_xlen_t rows = (R_xlen_t)groups * columns;

    const int ncol = 8;
    const char *column_names[] = {"row_group", "column",   "name",
                                  "num_values", "null_count", "distinct_count",
                                  "min",        "max"};
    SEXP result = PROTECT(Rf_allocVector(VECSXP, ncol));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, ncol));
    SET_VECTOR_ELT(result, 0, Rf_allocVector(INTSXP, rows));
    SET_VECTOR_ELT(result, 1, Rf_allocVector(INTSXP, rows));
    SET_VECTOR_ELT(result, 2, Rf_allocVector(STRSXP, rows));
    SET_VECTOR_ELT(result, 3, Rf_allocVector(REALSXP, rows));
    SET_VECTOR_ELT(result, 4, Rf_allocVector(REALSXP, rows));
    SET_VECTOR_ELT(result, 5, Rf_allocVector(REALSXP, rows));
    /* Bounds are list columns: one row's type is its column's type, and the
     * frame spans every column in the file. */
    SET_VECTOR_ELT(result, 6, Rf_allocVector(VECSXP, rows));
    SET_VECTOR_ELT(result, 7, Rf_allocVector(VECSXP, rows));
    for (int i = 0; i < ncol; i++)
        SET_STRING_ELT(names, i, Rf_mkChar(column_names[i]));

    const carquet_schema_node_t **leaves =
        (const carquet_schema_node_t **)R_alloc(
            (size_t)(columns > 0 ? columns : 1), sizeof(*leaves));
    if (qio_leaf_nodes(schema, leaves, columns) != columns) {
        Rf_error("qio: parquet schema does not describe all %d columns",
                 columns);
    }

    R_xlen_t at = 0;
    for (int32_t g = 0; g < groups; g++) {
        for (int32_t c = 0; c < columns; c++, at++) {
            INTEGER(VECTOR_ELT(result, 0))[at] = g + 1;
            INTEGER(VECTOR_ELT(result, 1))[at] = c + 1;
            SET_STRING_ELT(VECTOR_ELT(result, 2), at,
                           qio_column_path_string(schema, c));

            carquet_column_statistics_t stats;
            memset(&stats, 0, sizeof(stats));
            carquet_status_t status = carquet_reader_column_statistics(
                handle->reader, g, c, &stats);
            if (status != CARQUET_OK) {
                /* A column with no statistics is normal, not an error. */
                REAL(VECTOR_ELT(result, 3))[at] = NA_REAL;
                REAL(VECTOR_ELT(result, 4))[at] = NA_REAL;
                REAL(VECTOR_ELT(result, 5))[at] = NA_REAL;
                continue;
            }

            REAL(VECTOR_ELT(result, 3))[at] = (double)stats.num_values;
            REAL(VECTOR_ELT(result, 4))[at] =
                stats.has_null_count ? (double)stats.null_count : NA_REAL;
            REAL(VECTOR_ELT(result, 5))[at] =
                stats.has_distinct_count ? (double)stats.distinct_count
                                         : NA_REAL;
            if (!stats.has_min_max) continue;

            carquet_physical_type_t type = carquet_schema_column_type(schema, c);
            const carquet_logical_type_t *logical =
                carquet_schema_node_logical_type(leaves[c]);
            int is_text = logical && (logical->id == CARQUET_LOGICAL_STRING ||
                                      logical->id == CARQUET_LOGICAL_ENUM ||
                                      logical->id == CARQUET_LOGICAL_JSON);
            int32_t type_length = carquet_schema_node_type_length(leaves[c]);

            SEXP low = PROTECT(qio_statistic_value(stats.min_value,
                                                   stats.min_value_size, type,
                                                   type_length, is_text));
            SEXP high = PROTECT(qio_statistic_value(stats.max_value,
                                                    stats.max_value_size, type,
                                                    type_length, is_text));
            if (low != R_NilValue) SET_VECTOR_ELT(VECTOR_ELT(result, 6), at, low);
            if (high != R_NilValue)
                SET_VECTOR_ELT(VECTOR_ELT(result, 7), at, high);
            UNPROTECT(2);
        }
    }

    qio_set_data_frame_attributes(result, names, (int32_t)rows);
    UNPROTECT(2);
    return result;
}

/* Per-page statistics and locations.
 *
 * A column index and an offset index describe the same pages from two sides:
 * one holds bounds and null counts, the other file offsets and first rows.
 * They are reported as one frame because a page is the row, and either side
 * may be missing.
 *
 * Both handles are owned by the caller and must be freed. The extraction below
 * copies everything it needs into R's vmax storage and frees both before
 * building any R object, so the only call that can longjmp while a handle is
 * held is the single R_alloc, and nothing is left behind on the normal paths.
 */
typedef struct {
    int64_t null_count;
    int64_t first_row;
    int64_t offset;
    int32_t compressed_size;
    int32_t min_size;
    int32_t max_size;
    const uint8_t *min_value;
    const uint8_t *max_value;
    int is_null_page;
    int has_stats;
    int has_location;
} qio_page_row_t;

SEXP qio_parquet_page_index(SEXP file) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    const carquet_schema_t *schema = carquet_reader_schema(handle->reader);
    int32_t groups = carquet_reader_num_row_groups(handle->reader);
    int32_t columns = carquet_reader_num_columns(handle->reader);

    const carquet_schema_node_t **leaves =
        (const carquet_schema_node_t **)R_alloc(
            (size_t)(columns > 0 ? columns : 1), sizeof(*leaves));
    if (qio_leaf_nodes(schema, leaves, columns) != columns) {
        Rf_error("qio: parquet schema does not describe all %d columns",
                 columns);
    }

    /* Count first, so every output vector is allocated once and the fill pass
     * never has to grow anything while holding a native handle. */
    R_xlen_t total = 0;
    for (int32_t g = 0; g < groups; g++) {
        for (int32_t c = 0; c < columns; c++) {
            carquet_error_t err = CARQUET_ERROR_INIT;
            carquet_column_index_t *stats =
                carquet_reader_get_column_index(handle->reader, g, c, &err);
            int32_t pages = stats ? carquet_column_index_num_pages(stats) : 0;
            if (stats) carquet_column_index_free(stats);
            if (pages == 0) {
                carquet_error_t offset_err = CARQUET_ERROR_INIT;
                carquet_offset_index_t *locations =
                    carquet_reader_get_offset_index(handle->reader, g, c,
                                                    &offset_err);
                if (locations) {
                    pages = carquet_offset_index_num_pages(locations);
                    carquet_offset_index_free(locations);
                }
            }
            if (pages > 0) total += pages;
        }
    }

    const int ncol = 11;
    const char *column_names[] = {
        "row_group", "column",     "name",        "page",
        "first_row", "offset",     "compressed_bytes", "null_count",
        "null_page", "min",        "max"};
    SEXP result = PROTECT(Rf_allocVector(VECSXP, ncol));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, ncol));
    SET_VECTOR_ELT(result, 0, Rf_allocVector(INTSXP, total));
    SET_VECTOR_ELT(result, 1, Rf_allocVector(INTSXP, total));
    SET_VECTOR_ELT(result, 2, Rf_allocVector(STRSXP, total));
    SET_VECTOR_ELT(result, 3, Rf_allocVector(INTSXP, total));
    SET_VECTOR_ELT(result, 4, Rf_allocVector(REALSXP, total));
    SET_VECTOR_ELT(result, 5, Rf_allocVector(REALSXP, total));
    SET_VECTOR_ELT(result, 6, Rf_allocVector(REALSXP, total));
    SET_VECTOR_ELT(result, 7, Rf_allocVector(REALSXP, total));
    SET_VECTOR_ELT(result, 8, Rf_allocVector(LGLSXP, total));
    SET_VECTOR_ELT(result, 9, Rf_allocVector(VECSXP, total));
    SET_VECTOR_ELT(result, 10, Rf_allocVector(VECSXP, total));
    for (int i = 0; i < ncol; i++)
        SET_STRING_ELT(names, i, Rf_mkChar(column_names[i]));

    R_xlen_t at = 0;
    for (int32_t g = 0; g < groups && at < total; g++) {
        for (int32_t c = 0; c < columns && at < total; c++) {
            void *vmax_chunk = vmaxget();
            carquet_error_t stats_err = CARQUET_ERROR_INIT;
            carquet_error_t offset_err = CARQUET_ERROR_INIT;
            carquet_column_index_t *stats =
                carquet_reader_get_column_index(handle->reader, g, c,
                                                &stats_err);
            carquet_offset_index_t *locations =
                carquet_reader_get_offset_index(handle->reader, g, c,
                                                &offset_err);

            int32_t pages = stats ? carquet_column_index_num_pages(stats) : 0;
            int32_t located =
                locations ? carquet_offset_index_num_pages(locations) : 0;
            if (located > pages) pages = located;
            if (pages <= 0) {
                if (stats) carquet_column_index_free(stats);
                if (locations) carquet_offset_index_free(locations);
                vmaxset(vmax_chunk);
                continue;
            }

            /* The one allocation made while the handles are held. */
            qio_page_row_t *rows = (qio_page_row_t *)R_alloc(
                (size_t)pages, sizeof(qio_page_row_t));
            memset(rows, 0, (size_t)pages * sizeof(qio_page_row_t));

            for (int32_t p = 0; p < pages; p++) {
                if (stats && p < carquet_column_index_num_pages(stats)) {
                    carquet_page_stats_t page;
                    memset(&page, 0, sizeof(page));
                    if (carquet_column_index_get_page_stats(stats, p, &page) ==
                        CARQUET_OK) {
                        rows[p].has_stats = 1;
                        rows[p].null_count = page.null_count;
                        rows[p].is_null_page = page.is_null_page;
                        rows[p].min_value = (const uint8_t *)page.min_value;
                        rows[p].min_size = page.min_value_size;
                        rows[p].max_value = (const uint8_t *)page.max_value;
                        rows[p].max_size = page.max_value_size;
                    }
                }
                if (locations && p < located) {
                    carquet_page_location_t where;
                    memset(&where, 0, sizeof(where));
                    if (carquet_offset_index_get_page_location(
                            locations, p, &where) == CARQUET_OK) {
                        rows[p].has_location = 1;
                        rows[p].offset = where.offset;
                        rows[p].compressed_size = where.compressed_size;
                        rows[p].first_row = where.first_row_index;
                    }
                }
            }

            /* Bounds point into index storage, so copy them before freeing. */
            for (int32_t p = 0; p < pages; p++) {
                if (rows[p].min_value && rows[p].min_size > 0) {
                    uint8_t *copy = (uint8_t *)R_alloc((size_t)rows[p].min_size, 1);
                    memcpy(copy, rows[p].min_value, (size_t)rows[p].min_size);
                    rows[p].min_value = copy;
                }
                if (rows[p].max_value && rows[p].max_size > 0) {
                    uint8_t *copy = (uint8_t *)R_alloc((size_t)rows[p].max_size, 1);
                    memcpy(copy, rows[p].max_value, (size_t)rows[p].max_size);
                    rows[p].max_value = copy;
                }
            }

            if (stats) carquet_column_index_free(stats);
            if (locations) carquet_offset_index_free(locations);

            carquet_physical_type_t type = carquet_schema_column_type(schema, c);
            const carquet_logical_type_t *logical =
                carquet_schema_node_logical_type(leaves[c]);
            int is_text = logical && (logical->id == CARQUET_LOGICAL_STRING ||
                                      logical->id == CARQUET_LOGICAL_ENUM ||
                                      logical->id == CARQUET_LOGICAL_JSON);
            int32_t type_length = carquet_schema_node_type_length(leaves[c]);

            for (int32_t p = 0; p < pages && at < total; p++, at++) {
                INTEGER(VECTOR_ELT(result, 0))[at] = g + 1;
                INTEGER(VECTOR_ELT(result, 1))[at] = c + 1;
                SET_STRING_ELT(VECTOR_ELT(result, 2), at,
                               qio_column_path_string(schema, c));
                INTEGER(VECTOR_ELT(result, 3))[at] = p + 1;
                REAL(VECTOR_ELT(result, 4))[at] =
                    rows[p].has_location ? (double)rows[p].first_row : NA_REAL;
                REAL(VECTOR_ELT(result, 5))[at] =
                    rows[p].has_location ? (double)rows[p].offset : NA_REAL;
                REAL(VECTOR_ELT(result, 6))[at] =
                    rows[p].has_location ? (double)rows[p].compressed_size
                                         : NA_REAL;
                REAL(VECTOR_ELT(result, 7))[at] =
                    rows[p].has_stats ? (double)rows[p].null_count : NA_REAL;
                LOGICAL(VECTOR_ELT(result, 8))[at] =
                    rows[p].has_stats ? rows[p].is_null_page : NA_LOGICAL;

                SEXP low = PROTECT(qio_statistic_value(
                    rows[p].min_value, rows[p].min_size, type, type_length,
                    is_text));
                SEXP high = PROTECT(qio_statistic_value(
                    rows[p].max_value, rows[p].max_size, type, type_length,
                    is_text));
                if (low != R_NilValue)
                    SET_VECTOR_ELT(VECTOR_ELT(result, 9), at, low);
                if (high != R_NilValue)
                    SET_VECTOR_ELT(VECTOR_ELT(result, 10), at, high);
                UNPROTECT(2);
            }
            vmaxset(vmax_chunk);
        }
    }

    qio_set_data_frame_attributes(result, names, (int32_t)at);
    UNPROTECT(2);
    return result;
}

/* Bloom-filter membership.
 *
 * A bloom filter answers only "definitely absent" or "possibly present", so
 * the result is deliberately named for what it can promise. Values are matched
 * against the column's physical type: carquet hashes the physical
 * representation, so an R value has to be reduced to the same thing the writer
 * hashed, and anything qio cannot reduce is an error rather than a silent
 * FALSE, which would read as "definitely absent".
 */
SEXP qio_parquet_bloom_check(SEXP file, SEXP column_sexp, SEXP values,
                             SEXP row_group_sexp) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    const carquet_schema_t *schema = carquet_reader_schema(handle->reader);
    int32_t columns = carquet_reader_num_columns(handle->reader);
    int32_t groups = carquet_reader_num_row_groups(handle->reader);

    int32_t column = Rf_asInteger(column_sexp) - 1;
    if (column < 0 || column >= columns) {
        Rf_error("qio: column index out of range");
    }
    int32_t group = Rf_asInteger(row_group_sexp) - 1;
    if (group < 0 || group >= groups) {
        Rf_error("qio: row group index out of range");
    }

    carquet_physical_type_t type = carquet_schema_column_type(schema, column);
    R_xlen_t n = XLENGTH(values);

    /* Reject an unusable request before opening anything, so no handle is held
     * across an error. */
    switch (type) {
    case CARQUET_PHYSICAL_INT32:
    case CARQUET_PHYSICAL_INT64:
    case CARQUET_PHYSICAL_FLOAT:
    case CARQUET_PHYSICAL_DOUBLE:
        if (TYPEOF(values) != INTSXP && TYPEOF(values) != REALSXP) {
            Rf_error("qio: `values` must be numeric for this column");
        }
        break;
    case CARQUET_PHYSICAL_BYTE_ARRAY:
    case CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY:
        if (TYPEOF(values) != STRSXP) {
            Rf_error("qio: `values` must be character for this column");
        }
        break;
    default:
        Rf_error("qio: bloom filters are not defined for %s columns",
                 carquet_physical_type_name(type));
    }

    carquet_error_t err = CARQUET_ERROR_INIT;
    carquet_bloom_filter_t *filter =
        carquet_reader_get_bloom_filter(handle->reader, group, column, &err);
    if (!filter) {
        Rf_error("qio: column '%s' has no bloom filter in row group %d",
                 carquet_schema_column_name(schema, column), group + 1);
    }

    SEXP result = PROTECT(Rf_allocVector(LGLSXP, n));
    int *out = LOGICAL(result);
    for (R_xlen_t i = 0; i < n; i++) {
        switch (type) {
        case CARQUET_PHYSICAL_INT32: {
            double value = TYPEOF(values) == INTSXP
                               ? (INTEGER(values)[i] == NA_INTEGER
                                      ? NA_REAL
                                      : (double)INTEGER(values)[i])
                               : REAL(values)[i];
            out[i] = ISNA(value) ? NA_LOGICAL
                                 : carquet_bloom_filter_check_i32(
                                       filter, (int32_t)value);
            break;
        }
        case CARQUET_PHYSICAL_INT64: {
            double value = TYPEOF(values) == INTSXP
                               ? (INTEGER(values)[i] == NA_INTEGER
                                      ? NA_REAL
                                      : (double)INTEGER(values)[i])
                               : REAL(values)[i];
            out[i] = ISNA(value) ? NA_LOGICAL
                                 : carquet_bloom_filter_check_i64(
                                       filter, (int64_t)value);
            break;
        }
        case CARQUET_PHYSICAL_FLOAT: {
            double value = TYPEOF(values) == INTSXP
                               ? (INTEGER(values)[i] == NA_INTEGER
                                      ? NA_REAL
                                      : (double)INTEGER(values)[i])
                               : REAL(values)[i];
            out[i] = ISNA(value) ? NA_LOGICAL
                                 : carquet_bloom_filter_check_float(
                                       filter, (float)value);
            break;
        }
        case CARQUET_PHYSICAL_DOUBLE: {
            double value = TYPEOF(values) == INTSXP
                               ? (INTEGER(values)[i] == NA_INTEGER
                                      ? NA_REAL
                                      : (double)INTEGER(values)[i])
                               : REAL(values)[i];
            out[i] = ISNA(value)
                         ? NA_LOGICAL
                         : carquet_bloom_filter_check_double(filter, value);
            break;
        }
        default: {
            SEXP element = STRING_ELT(values, i);
            if (element == NA_STRING) {
                out[i] = NA_LOGICAL;
                break;
            }
            const char *text = Rf_translateCharUTF8(element);
            out[i] = carquet_bloom_filter_check_bytes(
                filter, (const uint8_t *)text, strlen(text));
            break;
        }
        }
    }

    carquet_bloom_filter_destroy(filter);
    UNPROTECT(1);
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
                         SEXP batch_size, SEXP int64_mode,
                         SEXP column_kinds) {
    qio_parquet_handle_t *handle = qio_get_handle(file, 0);
    if (handle->busy) {
        Rf_error("qio: parquet file already has an active read");
    }

    qio_batch_context_t context;
    memset(&context, 0, sizeof(context));
    context.handle = handle;
    context.file = file;
    context.batch_size = qio_batch_size(batch_size);
    context.int64_mode = qio_int64_mode(int64_mode);
    qio_prepare_selection(handle, columns, row_groups, column_kinds,
                          &context.selection);

    handle->busy = 1;
    SEXP continuation = PROTECT(R_MakeUnwindCont());
    SEXP result = PROTECT(R_UnwindProtect(qio_collect_body, &context,
                                          qio_batch_cleanup, &context,
                                          continuation));
    qio_warn_int32_sentinel(&context);
    qio_warn_int64_coerced(&context);
    UNPROTECT(2);
    return result;
}

SEXP qio_parquet_walk(SEXP file, SEXP columns, SEXP row_groups,
                      SEXP batch_size, SEXP callback, SEXP int64_mode,
                      SEXP column_kinds) {
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
    context.int64_mode = qio_int64_mode(int64_mode);
    qio_prepare_selection(handle, columns, row_groups, column_kinds,
                          &context.selection);

    handle->busy = 1;
    SEXP continuation = PROTECT(R_MakeUnwindCont());
    SEXP result = PROTECT(R_UnwindProtect(qio_walk_body, &context,
                                          qio_batch_cleanup, &context,
                                          continuation));
    qio_warn_int32_sentinel(&context);
    qio_warn_int64_coerced(&context);
    UNPROTECT(2);
    return result;
}
