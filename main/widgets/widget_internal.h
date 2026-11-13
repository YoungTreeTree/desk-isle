#pragma once

#include "widget_paint.h"
#include "frosted.h"
#include "cJSON.h"
#include "protocol.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
#include "esp_log.h"
#endif

#define WHITE WIDGET_RGB(255, 255, 255)

enum { TRANSITION_MS = 360, WAVE_FRAME_MS = 60 };

typedef struct {
    unsigned references;
    widget_font font;
    uint8_t bytes[];
} widget_glyph_bank;

typedef struct {
    cJSON *json;
    widget_glyph_bank *glyphs;
    widget_box notice_bounds;
    uint16_t measured_width, measured_height;
} widget_snapshot;

typedef struct {
    widget_snapshot data, previous, after;
    int64_t expires, transition, next_paint;
    unsigned motion_frames;
    bool animating;
} widget_state;

static inline int smaller(int a, int b) { return a < b ? a : b; }
static inline int larger(int a, int b) { return a > b ? a : b; }
static inline const cJSON *field(const cJSON *json, const char *key) { return cJSON_GetObjectItemCaseSensitive(json, key); }

static inline const char *string(const cJSON *json, const char *key)
{
    const char *text = cJSON_GetStringValue(field(json, key));
    return text ? text : "";
}

static inline int integer(const cJSON *json, const char *key, int fallback)
{
    const cJSON *value = field(json, key);
    return cJSON_IsNumber(value) ? value->valueint : fallback;
}

static inline int percent(const cJSON *json, const char *key)
{
    int value = integer(json, key, -1);
    return value >= 0 && value <= 100 ? value : -1;
}

static inline bool flag(const cJSON *json, const char *key) { return cJSON_IsTrue(field(json, key)); }

static inline bool running(const cJSON *data)
{
    return strcmp(string(field(data, "item"), "style"), "running") == 0;
}

static inline bool expanded(const cJSON *data) { return cJSON_IsObject(field(data, "item")) && !running(data); }

static inline void text(widget_canvas *c, int x, int y, int width, int size, const char *label, uint16_t color)
{
    widget_text(c, x, y, width, size, 1, label, color, 255);
}

static inline void right(widget_canvas *c, int x, int y, int width, int size, const char *label, uint16_t color)
{
    widget_text_right(c, x, y, width, size, label, color, 255);
}

static inline void center(widget_canvas *c, int y, int size, const char *label, uint16_t color)
{
    int x = larger(10, (c->width - widget_text_width(c, label, size)) / 2);
    text(c, x, y, c->width - x - 10, size, label, color);
}

static inline void bar(widget_canvas *c, int x, int y, int width, int value, const desk_frost_style *style)
{
    widget_round(c, (widget_box){x, y, width, 5}, 2, style->ink, 42);
    int fill = width * smaller(100, larger(0, value)) / 100;
    if (fill) widget_round(c, (widget_box){x, y, fill, 5}, 2, style->accent, 255);
}

static inline void format_int(char *out, size_t size, int value)
{
    if (value < 0) snprintf(out, size, "—");
    else snprintf(out, size, "%d", value);
}

static inline void format_steps(char *out, size_t size, int value)
{
    if (value >= 1000 && value < 1000000) snprintf(out, size, "%d,%03d", value / 1000, value % 1000);
    else format_int(out, size, value);
}

static inline void format_percent(char *out, size_t size, int value)
{
    if (value < 0) snprintf(out, size, "—");
    else snprintf(out, size, "%d%%", value);
}

static inline void format_tenths_percent(char *out, size_t size, int value)
{
    if (value < 0) snprintf(out, size, "—");
    else snprintf(out, size, "%d.%d%%", value / 10, value % 10);
}


void widget_release_snapshot(widget_snapshot *snapshot);
const widget_font *widget_snapshot_font(const widget_snapshot *snapshot);
void widget_set_data(widget_state *state, widget_snapshot data, bool notice, int64_t now);
widget_box widget_notice_paint(widget_canvas *c, widget_state *state, int64_t now);
void widget_mac_load_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style);
void widget_codex_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style);
void widget_garmin_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style);
void widget_bluetooth_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style);
