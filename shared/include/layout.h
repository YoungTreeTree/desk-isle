#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DESK_LCD_WIDTH 720u
#define DESK_LCD_HEIGHT 1280u
#define DESK_GRID_PX 40u
#define DESK_PET_ID 1u
#define DESK_PET_WIDTH 512u
#define DESK_PET_HEIGHT 288u
#define DESK_PET_FOOTPRINT_WIDTH (14u * DESK_GRID_PX)
#define DESK_PET_FOOTPRINT_HEIGHT (8u * DESK_GRID_PX)
#define DESK_PET_INSET_X ((DESK_PET_FOOTPRINT_WIDTH - DESK_PET_WIDTH) / 2u)
#define DESK_PET_INSET_Y ((DESK_PET_FOOTPRINT_HEIGHT - DESK_PET_HEIGHT) / 2u)
#define DESK_PET_LARGE_WIDTH 704u
#define DESK_PET_LARGE_HEIGHT 400u
#define DESK_PET_LARGE_FOOTPRINT_WIDTH (18u * DESK_GRID_PX)
#define DESK_PET_LARGE_FOOTPRINT_HEIGHT (10u * DESK_GRID_PX)
#define DESK_MAX_COMPONENTS 10u
#define DESK_MAX_COMPONENT_PIXELS (2u * DESK_LCD_WIDTH * DESK_LCD_HEIGHT)
#define DESK_LAYOUT_WIRE_MAX (2u + 10u * DESK_MAX_COMPONENTS)

typedef struct {
    uint16_t x, y, width, height;
} desk_rect;

typedef struct {
    uint16_t id;
    desk_rect rect;
} desk_component;

typedef struct {
    // Clockwise quarter turns of the panel from its native portrait position.
    uint8_t rotation, count;
    // Back-to-front stacking order.
    desk_component components[DESK_MAX_COMPONENTS];
} desk_layout;

desk_layout desk_layout_default(void);
bool desk_layout_valid(desk_layout layout);
bool desk_layout_equal(desk_layout a, desk_layout b);
const desk_component *desk_layout_component(const desk_layout *layout, uint16_t id);
size_t desk_layout_encode(const desk_layout *layout, uint8_t *bytes);
bool desk_layout_decode(desk_layout *layout, const uint8_t *bytes, size_t length);
bool desk_layout_decode_saved(desk_layout *layout, const uint8_t *bytes, size_t length, bool *migrated);
unsigned desk_jpeg_dimension(unsigned pixels);
desk_rect desk_rect_union(desk_rect a, desk_rect b);
desk_rect desk_layout_native_rect(desk_rect logical, uint8_t rotation);
void desk_layout_draw_component(uint16_t *frame, const uint16_t *pixels, const uint8_t *alpha,
                                desk_rect logical, uint8_t rotation, desk_rect dirty);
void desk_layout_draw_wallpaper(uint16_t *frame, const uint16_t *wallpaper, uint8_t rotation, bool source_landscape);
