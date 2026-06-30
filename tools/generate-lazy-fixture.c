/* Regenerate tests/testthat/parquet/qio-multigroup.parquet.
 *
 * Compile this file against qio's vendored carquet objects, then pass the
 * output path as its only argument. It deliberately creates four row groups,
 * nullable values, all currently supported physical types, and duplicate
 * footer metadata keys.
 */

#include <carquet/carquet.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(carquet_writer_t *writer, carquet_schema_t *schema,
                 const char *message) {
    if (writer) carquet_writer_abort(writer);
    if (schema) carquet_schema_free(schema);
    fprintf(stderr, "%s\n", message);
    exit(EXIT_FAILURE);
}

static void check(carquet_status_t status, carquet_writer_t *writer,
                  carquet_schema_t *schema, const char *message) {
    if (status != CARQUET_OK) fail(writer, schema, message);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s OUTPUT.parquet\n", argv[0]);
        return EXIT_FAILURE;
    }

    carquet_error_t error = CARQUET_ERROR_INIT;
    carquet_schema_t *schema = carquet_schema_create(&error);
    if (!schema) fail(NULL, NULL, "cannot create schema");

    carquet_logical_type_t string_type;
    memset(&string_type, 0, sizeof(string_type));
    string_type.id = CARQUET_LOGICAL_STRING;

    check(carquet_schema_add_column(
              schema, "id", CARQUET_PHYSICAL_INT32, NULL,
              CARQUET_REPETITION_REQUIRED, 0, 0),
          NULL, schema, "cannot add id");
    check(carquet_schema_add_column(
              schema, "count", CARQUET_PHYSICAL_INT64, NULL,
              CARQUET_REPETITION_REQUIRED, 0, 0),
          NULL, schema, "cannot add count");
    check(carquet_schema_add_column(
              schema, "ratio", CARQUET_PHYSICAL_FLOAT, NULL,
              CARQUET_REPETITION_REQUIRED, 0, 0),
          NULL, schema, "cannot add ratio");
    check(carquet_schema_add_column(
              schema, "price", CARQUET_PHYSICAL_DOUBLE, NULL,
              CARQUET_REPETITION_OPTIONAL, 0, 0),
          NULL, schema, "cannot add price");
    check(carquet_schema_add_column(
              schema, "label", CARQUET_PHYSICAL_BYTE_ARRAY, &string_type,
              CARQUET_REPETITION_OPTIONAL, 0, 0),
          NULL, schema, "cannot add label");
    check(carquet_schema_add_column(
              schema, "active", CARQUET_PHYSICAL_BOOLEAN, NULL,
              CARQUET_REPETITION_REQUIRED, 0, 0),
          NULL, schema, "cannot add active");

    carquet_writer_options_t options;
    carquet_writer_options_init(&options);
    options.compression = CARQUET_COMPRESSION_UNCOMPRESSED;
    options.created_by = "qio fixture generator";

    carquet_writer_t *writer = carquet_writer_create(
        argv[1], schema, &options, &error);
    if (!writer) fail(NULL, schema, "cannot create fixture");

    check(carquet_writer_add_metadata(writer, "qio.note", "first"),
          writer, schema, "cannot add first metadata entry");
    check(carquet_writer_add_metadata(writer, "qio.note", "second"),
          writer, schema, "cannot add second metadata entry");
    check(carquet_writer_add_metadata(writer, "qio.fixture", "multigroup"),
          writer, schema, "cannot add fixture metadata");

    const char *labels[] = {
        "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve"};

    for (int32_t group = 0; group < 4; group++) {
        int32_t id[3];
        int64_t count[3];
        float ratio[3];
        double price[3];
        int16_t price_def[3];
        carquet_byte_array_t label[3];
        int16_t label_def[3];
        uint8_t active[3];
        int32_t price_values = 0;
        int32_t label_values = 0;

        for (int32_t i = 0; i < 3; i++) {
            int32_t row = group * 3 + i;
            id[i] = row + 1;
            count[i] = 10000000000LL + row + 1;
            ratio[i] = (float)(row + 1) / 10.0f;
            active[i] = (uint8_t)(row % 2 == 0);

            if (row == 2 || row == 7) {
                price_def[i] = 0;
            } else {
                price_def[i] = 1;
                price[price_values++] = (double)(row + 1) * 1.25;
            }

            if (row == 4) {
                label_def[i] = 0;
            } else {
                label_def[i] = 1;
                label[label_values].data = (uint8_t *)labels[row];
                label[label_values].length = (int32_t)strlen(labels[row]);
                label_values++;
            }
        }

        check(carquet_writer_write_batch(writer, 0, id, 3, NULL, NULL),
              writer, schema, "cannot write id");
        check(carquet_writer_write_batch(writer, 1, count, 3, NULL, NULL),
              writer, schema, "cannot write count");
        check(carquet_writer_write_batch(writer, 2, ratio, 3, NULL, NULL),
              writer, schema, "cannot write ratio");
        check(carquet_writer_write_batch(
                  writer, 3, price, 3, price_def, NULL),
              writer, schema, "cannot write price");
        check(carquet_writer_write_batch(
                  writer, 4, label, 3, label_def, NULL),
              writer, schema, "cannot write label");
        check(carquet_writer_write_batch(writer, 5, active, 3, NULL, NULL),
              writer, schema, "cannot write active");

        if (group < 3) {
            check(carquet_writer_new_row_group(writer), writer, schema,
                  "cannot start row group");
        }
    }

    check(carquet_writer_close(writer), NULL, schema,
          "cannot finalize fixture");
    carquet_schema_free(schema);
    return EXIT_SUCCESS;
}
