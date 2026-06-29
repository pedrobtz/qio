/**
 * @file arrow_schema.c
 * @brief Minimal backward FlatBuffer builder + Arrow IPC Schema message.
 *
 * Produces the base64-encoded encapsulated Arrow IPC Schema message stored
 * under the Parquet footer key "ARROW:schema". The FlatBuffer builder is a
 * faithful, compact port of the reference (Python) flatbuffers builder
 * algorithm: it writes back-to-front, references point forward, and tables
 * carry a soffset to a trailing vtable.
 */

#include "core/allocator.h"
#include "arrow_schema.h"
#include <stdlib.h>
#include <string.h>

/* ---- Arrow flatbuf constants (format/Message.fbs, Schema.fbs, Type.fbs) -- */
enum { ARROW_METADATA_V5 = 4 };
enum { MSG_HEADER_SCHEMA = 1 };
/* Type union tags */
enum {
    AT_NULL = 1, AT_INT = 2, AT_FLOAT = 3, AT_BINARY = 4, AT_UTF8 = 5,
    AT_BOOL = 6, AT_DECIMAL = 7, AT_DATE = 8, AT_TIME = 9, AT_TIMESTAMP = 10,
    AT_FIXEDSIZEBINARY = 15
};
/* TimeUnit: SEC=0 MILLI=1 MICRO=2 NANO=3 ; DateUnit DAY=0 ; Precision DOUBLE=2 SINGLE=1 */

/* ============================================================================
 * Backward FlatBuffer builder
 * ============================================================================
 */

typedef struct {
    uint8_t* buf;       /* buffer; live data is buf[head .. cap) */
    size_t cap;
    size_t head;        /* write cursor; prepending decreases head */
    size_t minalign;
    int32_t* vtable;    /* current object's field->Offset() slots */
    int vtable_len;
    size_t object_end;  /* Offset() at StartObject time */
    int oom;
} fbb;

static int fbb_init(fbb* b) {
    b->cap = 1024;
    b->buf = (uint8_t*)carquet_mem_malloc(b->cap);
    b->head = b->cap;
    b->minalign = 1;
    b->vtable = NULL;
    b->vtable_len = 0;
    b->object_end = 0;
    b->oom = (b->buf == NULL);
    return !b->oom;
}

static void fbb_free(fbb* b) {
    carquet_mem_free(b->buf);
    carquet_mem_free(b->vtable);
}

static size_t fbb_offset(const fbb* b) { return b->cap - b->head; }

/* Grow the buffer, keeping live bytes anchored at the high end. */
static int fbb_grow(fbb* b) {
    size_t old_cap = b->cap;
    size_t live = old_cap - b->head;
    size_t new_cap = old_cap * 2;
    uint8_t* nb = (uint8_t*)carquet_mem_malloc(new_cap);
    if (!nb) { b->oom = 1; return 0; }
    memcpy(nb + (new_cap - live), b->buf + b->head, live);
    carquet_mem_free(b->buf);
    b->buf = nb;
    b->cap = new_cap;
    b->head = new_cap - live;
    return 1;
}

static void fbb_pad(fbb* b, size_t n) {
    while (n--) {
        if (b->head == 0 && !fbb_grow(b)) return;
        b->buf[--b->head] = 0;
    }
}

static void fbb_prep(fbb* b, size_t size, size_t additional) {
    if (size > b->minalign) b->minalign = size;
    size_t buf_used = b->cap - b->head + additional;
    size_t align_size = ((~buf_used) + 1) & (size - 1);
    while (b->head < align_size + size + additional) {
        if (!fbb_grow(b)) return;
    }
    fbb_pad(b, align_size);
}

static void fbb_put(fbb* b, const void* data, size_t n) {
    while (b->head < n) { if (!fbb_grow(b)) return; }
    b->head -= n;
    memcpy(b->buf + b->head, data, n);
}

static void fbb_place_u8(fbb* b, uint8_t v)  { fbb_put(b, &v, 1); }
static void fbb_place_u16(fbb* b, uint16_t v) {
    uint8_t t[2] = { (uint8_t)(v & 0xFF), (uint8_t)(v >> 8) };
    fbb_put(b, t, 2);
}
static void fbb_place_u32(fbb* b, uint32_t v) {
    uint8_t t[4] = { (uint8_t)v, (uint8_t)(v >> 8),
                     (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    fbb_put(b, t, 4);
}

/* Prepend a forward uoffset that refers to a previously built object. */
static void fbb_prepend_uoffset(fbb* b, size_t off) {
    fbb_prep(b, 4, 0);
    uint32_t v = (uint32_t)(fbb_offset(b) - off + 4);
    fbb_place_u32(b, v);
}

/* ---- strings & vectors ---- */
static size_t fbb_create_string(fbb* b, const char* s) {
    size_t len = strlen(s);
    fbb_prep(b, 4, len + 1);
    fbb_place_u8(b, 0);                 /* NUL terminator (not counted) */
    fbb_put(b, s, len);
    fbb_place_u32(b, (uint32_t)len);    /* vector length prefix */
    return fbb_offset(b);
}

static void fbb_start_vector(fbb* b, size_t elem_size, size_t n, size_t align) {
    fbb_prep(b, 4, elem_size * n);
    fbb_prep(b, align, elem_size * n);
}
static size_t fbb_end_vector(fbb* b, size_t n) {
    fbb_place_u32(b, (uint32_t)n);
    return fbb_offset(b);
}

/* ---- tables ---- */
static int fbb_start_table(fbb* b, int numfields) {
    carquet_mem_free(b->vtable);
    b->vtable = (int32_t*)carquet_mem_calloc((size_t)numfields, sizeof(int32_t));
    if (!b->vtable) { b->oom = 1; return 0; }
    b->vtable_len = numfields;
    b->object_end = fbb_offset(b);
    return 1;
}
static void fbb_slot(fbb* b, int slot) { b->vtable[slot] = (int32_t)fbb_offset(b); }

static void fbb_add_uoffset(fbb* b, int slot, size_t off) {
    fbb_prepend_uoffset(b, off);
    fbb_slot(b, slot);
}
static void fbb_add_u8(fbb* b, int slot, uint8_t v) {
    fbb_prep(b, 1, 0); fbb_place_u8(b, v); fbb_slot(b, slot);
}
static void fbb_add_i16(fbb* b, int slot, int16_t v) {
    fbb_prep(b, 2, 0); fbb_place_u16(b, (uint16_t)v); fbb_slot(b, slot);
}
static void fbb_add_i32(fbb* b, int slot, int32_t v) {
    fbb_prep(b, 4, 0); fbb_place_u32(b, (uint32_t)v); fbb_slot(b, slot);
}

static size_t fbb_end_table(fbb* b) {
    /* placeholder soffset (patched below) */
    fbb_prep(b, 4, 0);
    fbb_place_u32(b, 0);
    size_t object_offset = fbb_offset(b);

    int trimmed = b->vtable_len;
    while (trimmed > 0 && b->vtable[trimmed - 1] == 0) trimmed--;

    for (int i = trimmed - 1; i >= 0; i--) {
        uint16_t off = b->vtable[i]
            ? (uint16_t)(object_offset - (size_t)b->vtable[i]) : 0;
        fbb_prep(b, 2, 0); fbb_place_u16(b, off);
    }
    fbb_prep(b, 2, 0);
    fbb_place_u16(b, (uint16_t)(object_offset - b->object_end));   /* object size */
    fbb_prep(b, 2, 0);
    fbb_place_u16(b, (uint16_t)((trimmed + 2) * 2));               /* vtable size */

    /* patch soffset at the table start */
    int32_t soffset = (int32_t)(fbb_offset(b) - object_offset);
    size_t pos = b->cap - object_offset;
    b->buf[pos + 0] = (uint8_t)soffset;
    b->buf[pos + 1] = (uint8_t)(soffset >> 8);
    b->buf[pos + 2] = (uint8_t)(soffset >> 16);
    b->buf[pos + 3] = (uint8_t)(soffset >> 24);

    carquet_mem_free(b->vtable);
    b->vtable = NULL;
    b->vtable_len = 0;
    return object_offset;
}

static void fbb_finish(fbb* b, size_t root) {
    fbb_prep(b, b->minalign, 4);
    fbb_prepend_uoffset(b, root);
}

/* ============================================================================
 * Arrow type construction
 * ============================================================================
 */

/* Returns 0 on unsupported type (caller aborts ARROW:schema emission). */
static int build_arrow_type(fbb* b, const parquet_schema_element_t* e,
                            uint8_t* type_tag, size_t* type_off) {
    carquet_physical_type_t pt = e->type;
    int has_lt = e->has_logical_type;
    carquet_logical_type_id_t lt = has_lt ? e->logical_type.id : CARQUET_LOGICAL_UNKNOWN;
    carquet_converted_type_t ct = e->has_converted_type ? e->converted_type
                                                        : CARQUET_CONVERTED_NONE;

    switch (pt) {
    case CARQUET_PHYSICAL_BOOLEAN:
        fbb_start_table(b, 0); *type_off = fbb_end_table(b);
        *type_tag = AT_BOOL; return 1;

    case CARQUET_PHYSICAL_FLOAT:
        fbb_start_table(b, 1); fbb_add_i16(b, 0, 1 /*SINGLE*/);
        *type_off = fbb_end_table(b); *type_tag = AT_FLOAT; return 1;

    case CARQUET_PHYSICAL_DOUBLE:
        fbb_start_table(b, 1); fbb_add_i16(b, 0, 2 /*DOUBLE*/);
        *type_off = fbb_end_table(b); *type_tag = AT_FLOAT; return 1;

    case CARQUET_PHYSICAL_INT32:
    case CARQUET_PHYSICAL_INT64: {
        int is64 = (pt == CARQUET_PHYSICAL_INT64);
        if (has_lt && lt == CARQUET_LOGICAL_TIMESTAMP && is64) {
            int16_t unit = (e->logical_type.params.timestamp.unit ==
                            CARQUET_TIME_UNIT_MILLIS) ? 1 :
                           (e->logical_type.params.timestamp.unit ==
                            CARQUET_TIME_UNIT_MICROS) ? 2 : 3;
            size_t tz = 0;
            int adj = e->logical_type.params.timestamp.is_adjusted_to_utc;
            if (adj) tz = fbb_create_string(b, "UTC");
            fbb_start_table(b, 2);
            fbb_add_i16(b, 0, unit);
            if (adj) fbb_add_uoffset(b, 1, tz);
            *type_off = fbb_end_table(b); *type_tag = AT_TIMESTAMP; return 1;
        }
        if (has_lt && lt == CARQUET_LOGICAL_DATE && !is64) {
            fbb_start_table(b, 1); /* DateUnit DAY=0 default */
            *type_off = fbb_end_table(b); *type_tag = AT_DATE; return 1;
        }
        if (has_lt && lt == CARQUET_LOGICAL_TIME) {
            int16_t unit = (e->logical_type.params.time.unit ==
                            CARQUET_TIME_UNIT_MILLIS) ? 1 :
                           (e->logical_type.params.time.unit ==
                            CARQUET_TIME_UNIT_MICROS) ? 2 : 3;
            fbb_start_table(b, 2);
            fbb_add_i16(b, 0, unit);
            fbb_add_i32(b, 1, is64 ? 64 : 32);
            *type_off = fbb_end_table(b); *type_tag = AT_TIME; return 1;
        }
        if (has_lt && lt == CARQUET_LOGICAL_DECIMAL) {
            fbb_start_table(b, 3);
            fbb_add_i32(b, 0, e->precision);
            fbb_add_i32(b, 1, e->scale);
            fbb_add_i32(b, 2, 128);
            *type_off = fbb_end_table(b); *type_tag = AT_DECIMAL; return 1;
        }
        {
            int32_t bw = is64 ? 64 : 32;
            int is_signed = 1;
            if (has_lt && lt == CARQUET_LOGICAL_INTEGER) {
                bw = e->logical_type.params.integer.bit_width;
                is_signed = e->logical_type.params.integer.is_signed;
            } else if (ct >= CARQUET_CONVERTED_UINT_8 &&
                       ct <= CARQUET_CONVERTED_INT_64) {
                static const int8_t cbw[] = { 8, 16, 32, 64, 8, 16, 32, 64 };
                bw = cbw[ct - CARQUET_CONVERTED_UINT_8];
                is_signed = (ct >= CARQUET_CONVERTED_INT_8);
            }
            fbb_start_table(b, 2);
            fbb_add_i32(b, 0, bw);
            if (is_signed) fbb_add_u8(b, 1, 1);
            *type_off = fbb_end_table(b); *type_tag = AT_INT; return 1;
        }
    }

    case CARQUET_PHYSICAL_INT96:
        /* Arrow maps the deprecated INT96 to timestamp[ns] (no tz). */
        fbb_start_table(b, 2);
        fbb_add_i16(b, 0, 3 /*NANO*/);
        *type_off = fbb_end_table(b); *type_tag = AT_TIMESTAMP; return 1;

    case CARQUET_PHYSICAL_BYTE_ARRAY:
        if ((has_lt && (lt == CARQUET_LOGICAL_STRING ||
                        lt == CARQUET_LOGICAL_JSON ||
                        lt == CARQUET_LOGICAL_ENUM)) ||
            ct == CARQUET_CONVERTED_UTF8 || ct == CARQUET_CONVERTED_JSON ||
            ct == CARQUET_CONVERTED_ENUM) {
            fbb_start_table(b, 0); *type_off = fbb_end_table(b);
            *type_tag = AT_UTF8; return 1;
        }
        if (has_lt && lt == CARQUET_LOGICAL_DECIMAL) return 0; /* not Arrow-representable */
        fbb_start_table(b, 0); *type_off = fbb_end_table(b);
        *type_tag = AT_BINARY; return 1;

    case CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY:
        if (has_lt && lt == CARQUET_LOGICAL_DECIMAL) {
            fbb_start_table(b, 3);
            fbb_add_i32(b, 0, e->precision);
            fbb_add_i32(b, 1, e->scale);
            fbb_add_i32(b, 2, 128);
            *type_off = fbb_end_table(b); *type_tag = AT_DECIMAL; return 1;
        }
        fbb_start_table(b, 1);
        fbb_add_i32(b, 0, e->type_length);
        *type_off = fbb_end_table(b); *type_tag = AT_FIXEDSIZEBINARY; return 1;

    default:
        return 0;
    }
}

/* ============================================================================
 * base64
 * ============================================================================
 */

static char* base64(const uint8_t* in, size_t n) {
    static const char T[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t out_len = ((n + 2) / 3) * 4;
    char* out = (char*)carquet_mem_malloc(out_len + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < n) v |= (uint32_t)in[i + 1] << 8;
        if (i + 2 < n) v |= in[i + 2];
        out[o++] = T[(v >> 18) & 0x3F];
        out[o++] = T[(v >> 12) & 0x3F];
        out[o++] = (i + 1 < n) ? T[(v >> 6) & 0x3F] : '=';
        out[o++] = (i + 2 < n) ? T[v & 0x3F] : '=';
    }
    out[o] = '\0';
    return out;
}

/* ============================================================================
 * Public entry
 * ============================================================================
 */

char* carquet_build_arrow_schema_b64(
    const parquet_schema_element_t* schema,
    int32_t num_elements) {

    if (!schema || num_elements < 2) return NULL;

    /* Flat-only: every element after the root must be a primitive leaf with
     * REQUIRED/OPTIONAL repetition. Anything nested aborts (return NULL) so we
     * never emit a schema that disagrees with the Parquet schema. */
    int32_t nfields = num_elements - 1;
    for (int32_t i = 1; i < num_elements; i++) {
        const parquet_schema_element_t* e = &schema[i];
        if (!e->has_type || e->num_children != 0 || !e->name) return NULL;
        if (e->has_repetition &&
            e->repetition_type == CARQUET_REPETITION_REPEATED) return NULL;
    }

    fbb b;
    if (!fbb_init(&b)) return NULL;

    /* Build each Field (leaves first is automatic: type, name, then table). */
    size_t* field_offs = (size_t*)carquet_mem_malloc((size_t)nfields * sizeof(size_t));
    if (!field_offs) { fbb_free(&b); return NULL; }

    int ok = 1;
    for (int32_t i = 0; i < nfields && ok; i++) {
        const parquet_schema_element_t* e = &schema[i + 1];
        uint8_t type_tag = 0;
        size_t type_off = 0;
        if (!build_arrow_type(&b, e, &type_tag, &type_off)) { ok = 0; break; }
        size_t name_off = fbb_create_string(&b, e->name);
        int nullable = !(e->has_repetition &&
                         e->repetition_type == CARQUET_REPETITION_REQUIRED);

        fbb_start_table(&b, 7);
        fbb_add_uoffset(&b, 0, name_off);
        if (nullable) fbb_add_u8(&b, 1, 1);
        fbb_add_u8(&b, 2, type_tag);
        fbb_add_uoffset(&b, 3, type_off);
        field_offs[i] = fbb_end_table(&b);
    }
    if (!ok || b.oom) { carquet_mem_free(field_offs); fbb_free(&b); return NULL; }

    /* fields vector */
    fbb_start_vector(&b, 4, (size_t)nfields, 4);
    for (int32_t i = nfields - 1; i >= 0; i--) fbb_prepend_uoffset(&b, field_offs[i]);
    size_t fields_vec = fbb_end_vector(&b, (size_t)nfields);
    carquet_mem_free(field_offs);

    /* Schema table: only set fields (endianness Little=0 is the default). */
    fbb_start_table(&b, 4);
    fbb_add_uoffset(&b, 1, fields_vec);
    size_t schema_off = fbb_end_table(&b);

    /* Message table */
    fbb_start_table(&b, 5);
    fbb_add_i16(&b, 0, ARROW_METADATA_V5);
    fbb_add_u8(&b, 1, MSG_HEADER_SCHEMA);
    fbb_add_uoffset(&b, 2, schema_off);
    size_t msg_off = fbb_end_table(&b);

    fbb_finish(&b, msg_off);
    if (b.oom) { fbb_free(&b); return NULL; }

    size_t fb_len = fbb_offset(&b);
    const uint8_t* fb = b.buf + b.head;

    /* Encapsulated IPC message: 0xFFFFFFFF | int32 metadata_len | flatbuffer,
     * with the flatbuffer padded so metadata_len is a multiple of 8. */
    size_t padded = (fb_len + 7) & ~(size_t)7;
    size_t enc_len = 8 + padded;
    uint8_t* enc = (uint8_t*)carquet_mem_malloc(enc_len);
    if (!enc) { fbb_free(&b); return NULL; }
    enc[0] = enc[1] = enc[2] = enc[3] = 0xFF;
    uint32_t m = (uint32_t)padded;
    enc[4] = (uint8_t)m; enc[5] = (uint8_t)(m >> 8);
    enc[6] = (uint8_t)(m >> 16); enc[7] = (uint8_t)(m >> 24);
    memcpy(enc + 8, fb, fb_len);
    memset(enc + 8 + fb_len, 0, padded - fb_len);
    fbb_free(&b);

    char* b64 = base64(enc, enc_len);
    carquet_mem_free(enc);
    return b64;
}
