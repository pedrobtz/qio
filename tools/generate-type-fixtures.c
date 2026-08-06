/* Regenerate the two fixtures no other writer available here can produce.
 *
 *   tests/testthat/parquet/uuid.parquet
 *     A UUID-annotated FIXED_LEN_BYTE_ARRAY(16) column. Apache Arrow's R
 *     bindings have no UUID type, and qio's writer cannot emit the annotation.
 *
 *   tests/testthat/parquet/invalid_utf8.parquet
 *     A STRING-annotated BYTE_ARRAY column holding bytes that are not valid
 *     UTF-8. Arrow refuses to build such an array, correctly; carquet performs
 *     no write-side validation, which is what makes this fixture possible.
 *
 * Both exercise read paths that would otherwise have no end-to-end coverage.
 * Provenance is recorded in tests/testthat/parquet/SOURCE.md.
 *
 * Compile against qio's vendored carquet objects and run from the repository
 * root with no arguments; see the header comment in generate-lazy-fixture.c
 * for the build line.
 */

#include <carquet/carquet.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(carquet_writer_t *writer, carquet_schema_t *schema,
                const char *message) {
    if (writer) carquet_writer_abort(writer);
    if (schema) carquet_schema_free(schema);
    fprintf(stderr, "%s\n", message);
    return 1;
}

/* Four UUIDs plus one null, so the reader's null handling is covered too. */
static int write_uuid(const char *path) {
    static const uint8_t values[4][16] = {
        {0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
         0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88},
        {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
        {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
         0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
        {0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1,
         0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8},
    };

    carquet_error_t err = CARQUET_ERROR_INIT;
    carquet_schema_t *schema = carquet_schema_create(&err);
    if (!schema) return fail(NULL, NULL, "cannot create schema");

    carquet_logical_type_t uuid;
    memset(&uuid, 0, sizeof(uuid));
    uuid.id = CARQUET_LOGICAL_UUID;

    if (carquet_schema_add_column(schema, "id",
                                  CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY, &uuid,
                                  CARQUET_REPETITION_OPTIONAL, 16, 0) !=
        CARQUET_OK) {
        return fail(NULL, schema, "cannot add uuid column");
    }

    carquet_writer_options_t options;
    carquet_writer_options_init(&options);
    options.compression = CARQUET_COMPRESSION_SNAPPY;

    carquet_writer_t *writer = carquet_writer_create(path, schema, &options,
                                                     &err);
    if (!writer) return fail(NULL, schema, "cannot create uuid file");

    /* Values are dense; definition levels place the null at row 2. */
    uint8_t dense[4 * 16];
    memcpy(dense, values[0], 16);
    memcpy(dense + 16, values[1], 16);
    memcpy(dense + 32, values[2], 16);
    memcpy(dense + 48, values[3], 16);
    int16_t defs[5] = {1, 0, 1, 1, 1};

    if (carquet_writer_write_batch(writer, 0, dense, 5, defs, NULL) !=
        CARQUET_OK) {
        return fail(writer, schema, "cannot write uuid batch");
    }
    if (carquet_writer_close(writer) != CARQUET_OK) {
        return fail(NULL, schema, "cannot finalize uuid file");
    }
    carquet_schema_free(schema);
    printf("wrote %s\n", path);
    return 0;
}

static int write_invalid_utf8(const char *path) {
    carquet_error_t err = CARQUET_ERROR_INIT;
    carquet_schema_t *schema = carquet_schema_create(&err);
    if (!schema) return fail(NULL, NULL, "cannot create schema");

    carquet_logical_type_t string_type;
    memset(&string_type, 0, sizeof(string_type));
    string_type.id = CARQUET_LOGICAL_STRING;

    if (carquet_schema_add_column(schema, "s", CARQUET_PHYSICAL_BYTE_ARRAY,
                                  &string_type, CARQUET_REPETITION_REQUIRED, 0,
                                  0) != CARQUET_OK) {
        return fail(NULL, schema, "cannot add string column");
    }

    carquet_writer_options_t options;
    carquet_writer_options_init(&options);
    options.compression = CARQUET_COMPRESSION_SNAPPY;

    carquet_writer_t *writer = carquet_writer_create(path, schema, &options,
                                                     &err);
    if (!writer) return fail(NULL, schema, "cannot create utf8 file");

    /* Row 1 is valid; row 2 is a truncated two-byte sequence (0xC3 with a
     * continuation byte that is not one), which no correct reader may accept
     * as UTF-8. */
    static const uint8_t ok[] = {'o', 'k'};
    static const uint8_t bad[] = {0xC3, 0x28};
    carquet_byte_array_t values[2];
    values[0].data = (uint8_t *)ok;
    values[0].length = 2;
    values[1].data = (uint8_t *)bad;
    values[1].length = 2;

    if (carquet_writer_write_batch(writer, 0, values, 2, NULL, NULL) !=
        CARQUET_OK) {
        return fail(writer, schema, "cannot write utf8 batch");
    }
    if (carquet_writer_close(writer) != CARQUET_OK) {
        return fail(NULL, schema, "cannot finalize utf8 file");
    }
    carquet_schema_free(schema);
    printf("wrote %s\n", path);
    return 0;
}

int main(void) {
    if (write_uuid("tests/testthat/parquet/uuid.parquet") != 0) return 1;
    if (write_invalid_utf8("tests/testthat/parquet/invalid_utf8.parquet") != 0) {
        return 1;
    }
    return 0;
}
