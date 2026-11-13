#pragma once

#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "protocol.h"
#include "widget.h"

#define DESK_DISPLAY_CORE 0

esp_err_t desk_display_init(desk_layout initial, uint8_t brightness);
esp_err_t desk_display_set_backlight(uint8_t brightness);
esp_err_t desk_display_flush(void);
esp_err_t desk_display_frame(uint16_t id, const desk_frame_data *frame);
esp_err_t desk_display_widget_update(uint16_t id, const uint8_t *data, size_t size, bool has_glyphs);
bool desk_display_frame_ready(void);
void desk_display_tick(void);
void desk_display_hide_component(uint16_t id);
esp_err_t desk_display_set_layout(desk_layout next);
esp_err_t desk_display_set_wallpaper(const uint8_t *jpeg, size_t length, unsigned width, unsigned height);
esp_err_t desk_display_paint_pet(widget_box (*paint)(widget_canvas *, void *), void *context);
