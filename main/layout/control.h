#pragma once

#include "esp_err.h"
#include "layout.h"
#include "tinyusb.h"

enum desk_layout_status {
    DESK_LAYOUT_OK = 0,
    DESK_LAYOUT_INVALID = 1,
    DESK_LAYOUT_DISPLAY_FAILED = 2,
    DESK_LAYOUT_NOT_SAVED = 3,
};

typedef struct {
    uint8_t brightness;
    bool blanked;
} desk_backlight;

desk_layout desk_control_init(void);
void desk_control_tick(void);
void desk_control_usb_config(tinyusb_desc_config_t *descriptor);
const desk_layout *desk_control_layout(void);
enum desk_layout_status desk_control_status(void);
enum desk_layout_status desk_control_apply(const uint8_t *bytes, size_t length);
desk_backlight desk_control_backlight(void);
esp_err_t desk_control_set_backlight(desk_backlight next);
