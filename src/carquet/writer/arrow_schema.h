/**
 * @file arrow_schema.h
 * @brief Generate the Arrow IPC "ARROW:schema" footer metadata value.
 *
 * PyArrow / Arrow C++ store the original Arrow schema in the Parquet footer
 * under the key "ARROW:schema" as a base64-encoded, encapsulated Arrow IPC
 * Schema message. Emitting it lets Arrow round-trip Arrow-specific type
 * information losslessly. This is opt-in (writer option) and only produced
 * for flat (non-nested) schemas; nested schemas return NULL so we never write
 * a schema that disagrees with the Parquet schema.
 */
#ifndef CARQUET_ARROW_SCHEMA_H
#define CARQUET_ARROW_SCHEMA_H

#include "core/allocator.h"
#include "thrift/parquet_types.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Build the base64-encoded "ARROW:schema" value for a flat schema.
 *
 * @param schema       Schema elements (element 0 is the root group).
 * @param num_elements Number of schema elements.
 * @return Heap-allocated NUL-terminated base64 string (caller frees with
 *         carquet_mem_free()), or NULL if the schema is nested/unsupported or on OOM.
 */
char* carquet_build_arrow_schema_b64(
    const parquet_schema_element_t* schema,
    int32_t num_elements);

#ifdef __cplusplus
}
#endif

#endif /* CARQUET_ARROW_SCHEMA_H */
