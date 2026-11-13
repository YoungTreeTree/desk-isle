#pragma once

#include "layout.h"

enum {
    DESK_FROST_STEP = 8,
    DESK_FROST_CELLS = (DESK_LCD_WIDTH / DESK_FROST_STEP) * (DESK_LCD_HEIGHT / DESK_FROST_STEP),
    DESK_FROST_SAMPLES = 2 * DESK_FROST_CELLS,
    DESK_FROST_RADIUS = 18,
    DESK_FROST_FALLBACK = 202,
    DESK_FROST_HIGHLIGHT_MID = 61,
    DESK_FROST_HIGHLIGHT_END = 138,
    DESK_FROST_HIGHLIGHT_MID_OPACITY = 5,
};

typedef struct {
    uint16_t ink, muted, accent, chart_amber;
    uint8_t tile_opacity, badge_opacity;
    uint8_t highlight, shadow, rim_top, rim_middle, rim_bottom;
} desk_frost_style;

const desk_frost_style *desk_frost_style_for(bool dark);

// The grid holds DESK_FROST_SAMPLES entries. Both palettes are in logical
// screen order and the input wallpaper is in native framebuffer order.
void desk_frost_prepare(uint32_t *grid, const uint16_t *wallpaper, uint8_t rotation);
bool desk_frost_is_dark(const uint32_t *grid, desk_rect rect, uint8_t rotation);
const uint32_t *desk_frost_colors(const uint32_t *grid, bool dark);
void desk_frost_sample_row(uint32_t *pixels, const uint32_t *colors, unsigned columns, unsigned rows,
                           unsigned x, unsigned y, unsigned width);
