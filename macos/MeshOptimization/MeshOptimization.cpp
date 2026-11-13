#include "DeskIsleMesh.h"
#include "Vendor/meshoptimizer.h"
#include <cmath>
#include <new>

size_t desk_mesh_simplify(uint32_t *output, const uint32_t *indices, size_t index_count,
                          const float *positions, size_t vertex_count,
                          const float *attributes, const float *weights, size_t attribute_count,
                          size_t target_index_count, float maximum_error)
{
    if (!output || !indices || !positions || !attributes || !weights ||
        !vertex_count || vertex_count > 150000 || index_count < 3 || index_count > 300000 ||
        index_count % 3 || !attribute_count || attribute_count > 32 ||
        target_index_count < 3 || target_index_count > index_count || target_index_count % 3 ||
        !std::isfinite(maximum_error) || maximum_error < 0 || maximum_error > 0.05f) return 0;
    for (size_t i = 0; i < index_count; ++i) if (indices[i] >= vertex_count) return 0;
    for (size_t i = 0; i < vertex_count * 3; ++i) if (!std::isfinite(positions[i])) return 0;
    for (size_t i = 0; i < vertex_count * attribute_count; ++i) if (!std::isfinite(attributes[i])) return 0;
    for (size_t i = 0; i < attribute_count; ++i) if (!std::isfinite(weights[i]) || weights[i] < 0) return 0;
    try {
        return meshopt_simplifyWithAttributes(output, indices, index_count, positions, vertex_count, 12,
            attributes, attribute_count * sizeof(float), weights, attribute_count, nullptr,
            target_index_count, maximum_error, meshopt_SimplifyLockBorder, nullptr);
    } catch (const std::bad_alloc &) {
        return 0;
    }
}
