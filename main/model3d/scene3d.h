#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Portable software renderer; the pack stays owned by the caller until scene destruction.
typedef struct scene3d scene3d;
typedef struct { unsigned x, y, width, height; } scene3d_rect;
scene3d_rect scene3d_changed_rect(const scene3d *scene);
typedef void *(*scene3d_alloc)(size_t);
typedef struct {
    uint64_t frames, animation_us, clear_us, vertex_us, raster_us;
} scene3d_profile;
void scene3d_set_clock(scene3d *scene, uint64_t (*clock_us)(void));
void scene3d_reset_profile(scene3d *scene);
scene3d_profile scene3d_get_profile(const scene3d *scene);
scene3d *scene3d_create(const uint8_t *pack, size_t length, scene3d_alloc allocate);
void scene3d_destroy(scene3d *scene);
bool scene3d_resize(scene3d *scene, unsigned width, unsigned height);
bool scene3d_render(scene3d *scene, uint16_t *rgb565, unsigned stride, double seconds,
                    bool greeting, void (*cooperate)(void));
// Copy actual geometry coverage for the changed region, including cleared pixels.
// The mask is full-size (optionally nearest-neighbor scaled), independent of model colors.
bool scene3d_copy_alpha(const scene3d *scene, uint8_t *alpha, unsigned stride, unsigned scale);
unsigned scene3d_triangles(const scene3d *scene);
unsigned scene3d_vertices(const scene3d *scene);
size_t scene3d_memory(const scene3d *scene);
