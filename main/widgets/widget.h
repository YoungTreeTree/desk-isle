#pragma once

#include "layout.h"

enum {
    DESK_WIDGET_GARMIN = 0x8001,
    DESK_WIDGET_CODEX = 0x8002,
    DESK_WIDGET_NOTICE = 0x8003,
    DESK_WIDGET_BLUETOOTH = 0x8004,
    DESK_WIDGET_MAC_LOAD = 0x8005,
    DESK_WIDGET_COUNT = 5,
};

typedef struct {
    int x, y, width, height;
} widget_box;

typedef struct {
    const uint8_t *records, *masks;
    unsigned count;
} widget_font;

typedef struct {
    uint16_t *pixels;
    uint8_t *alpha;
    int stride, width, height;
    widget_box clip;
    const widget_font *font;
} widget_canvas;

int desk_widget_index(uint16_t id);
bool desk_widget_supported(const desk_component *component);
bool desk_widget_load_font(const uint8_t *data, size_t size);
bool desk_widget_update(uint16_t id, const uint8_t *data, size_t size,
                        const uint8_t *glyphs, size_t glyphs_size, int64_t now);
void desk_widget_forget(uint16_t id);
bool desk_widget_due(uint16_t id, int64_t now);
widget_box desk_widget_paint(const desk_component *component, widget_canvas *canvas,
                            const uint32_t *frost, uint8_t rotation, int64_t now);
