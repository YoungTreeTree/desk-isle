#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Output capacity must be index_count. Zero means invalid input or allocation failure.
size_t desk_mesh_simplify(uint32_t *output, const uint32_t *indices, size_t index_count,
                          const float *positions, size_t vertex_count,
                          const float *attributes, const float *weights, size_t attribute_count,
                          size_t target_index_count, float maximum_error);
#ifdef __cplusplus
}
#endif
