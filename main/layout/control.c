#include "esp_log.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "control.h"
#include "display.h"

#define LAYOUT_KEY "layout_v1"
#define BRIGHTNESS_KEY "brightness"
#define BRIGHTNESS_SAVE_DELAY_US 700000

static const char *TAG = "DESK_LAYOUT";
static desk_layout applied;
static nvs_handle_t storage;
static bool storage_open;
static bool needs_save;
static esp_err_t save_layout(void);
static desk_backlight backlight = {.brightness = DESK_BACKLIGHT_MAX};
static uint8_t saved_brightness = DESK_BACKLIGHT_MAX;
static int64_t brightness_save_at;

#define CONFIG_LENGTH (TUD_CONFIG_DESC_LEN + 2 * TUD_CDC_DESC_LEN)
#define CONFIG_DESCRIPTOR(packet_size) \
    TUD_CONFIG_DESCRIPTOR(1, 4, 0, CONFIG_LENGTH, 0, 100), \
    TUD_CDC_DESCRIPTOR(0, 4, 0x81, 8, 0x02, 0x82, packet_size), \
    TUD_CDC_DESCRIPTOR(2, 5, 0x83, 8, 0x04, 0x84, packet_size)

static const uint8_t full_speed_config[] = { CONFIG_DESCRIPTOR(64) };
static const uint8_t high_speed_config[] = { CONFIG_DESCRIPTOR(512) };
static const char *usb_strings[] = {
    (const char[]){0x09, 0x04},
    CONFIG_TINYUSB_DESC_MANUFACTURER_STRING,
    CONFIG_TINYUSB_DESC_PRODUCT_STRING,
    CONFIG_TINYUSB_DESC_SERIAL_STRING,
    "DeskIsle Animation",
    "DeskIsle Layout",
};

void desk_control_usb_config(tinyusb_desc_config_t *descriptor)
{
    descriptor->full_speed_config = full_speed_config;
    descriptor->high_speed_config = high_speed_config;
    descriptor->string = usb_strings;
    descriptor->string_count = sizeof(usb_strings) / sizeof(usb_strings[0]);
}

desk_layout desk_control_init(void)
{
    applied = desk_layout_default();
    esp_err_t error = nvs_flash_init();
    if (error == ESP_OK) error = nvs_open("desk_isle", NVS_READWRITE, &storage);
    storage_open = error == ESP_OK;
    if (!storage_open) {
        ESP_LOGW(TAG, "Layout storage unavailable: %s", esp_err_to_name(error));
        return applied;
    }

    uint8_t brightness;
    if (nvs_get_u8(storage, BRIGHTNESS_KEY, &brightness) == ESP_OK && brightness <= DESK_BACKLIGHT_MAX) {
        backlight.brightness = saved_brightness = brightness;
    }
    uint8_t bytes[DESK_LAYOUT_WIRE_MAX];
    size_t length = sizeof(bytes);
    if (nvs_get_blob(storage, LAYOUT_KEY, bytes, &length) == ESP_OK) {
        bool migrated;
        if (!desk_layout_decode_saved(&applied, bytes, length, &migrated)) {
            ESP_LOGW(TAG, "Saved layout is invalid");
        } else if (migrated) {
            error = save_layout();
            needs_save = error != ESP_OK;
            if (needs_save) ESP_LOGW(TAG, "Migrated layout save failed: %s", esp_err_to_name(error));
        }
    }
    return applied;
}

desk_backlight desk_control_backlight(void)
{
    return backlight;
}

esp_err_t desk_control_set_backlight(desk_backlight next)
{
    const uint8_t old_level = backlight.blanked ? 0 : backlight.brightness;
    const uint8_t new_level = next.blanked ? 0 : next.brightness;
    if (old_level != new_level) {
        const esp_err_t error = desk_display_set_backlight(new_level);
        if (error != ESP_OK) return error;
    }
    if (next.brightness != backlight.brightness && storage_open) {
        brightness_save_at = next.brightness == saved_brightness ? 0 : esp_timer_get_time() + BRIGHTNESS_SAVE_DELAY_US;
    }
    backlight = next;
    return ESP_OK;
}

void desk_control_tick(void)
{
    if (!brightness_save_at || esp_timer_get_time() < brightness_save_at) return;
    brightness_save_at = 0;
    esp_err_t error = nvs_set_u8(storage, BRIGHTNESS_KEY, backlight.brightness);
    if (error == ESP_OK) error = nvs_commit(storage);
    if (error == ESP_OK) saved_brightness = backlight.brightness;
    else ESP_LOGW(TAG, "Brightness save failed: %s", esp_err_to_name(error));
}

const desk_layout *desk_control_layout(void)
{
    return &applied;
}

enum desk_layout_status desk_control_status(void)
{
    return needs_save ? DESK_LAYOUT_NOT_SAVED : DESK_LAYOUT_OK;
}

static esp_err_t save_layout(void)
{
    if (!storage_open) return ESP_ERR_INVALID_STATE;
    uint8_t bytes[DESK_LAYOUT_WIRE_MAX];
    size_t length = desk_layout_encode(&applied, bytes);
    esp_err_t error = nvs_set_blob(storage, LAYOUT_KEY, bytes, length);
    return error == ESP_OK ? nvs_commit(storage) : error;
}

enum desk_layout_status desk_control_apply(const uint8_t *bytes, size_t length)
{
    desk_layout next;
    if (!desk_layout_decode(&next, bytes, length)) return DESK_LAYOUT_INVALID;
    if (!desk_layout_equal(applied, next)) {
        esp_err_t error = desk_display_set_layout(next);
        if (error != ESP_OK) {
            ESP_LOGW(TAG, "Layout apply failed: %s", esp_err_to_name(error));
            return DESK_LAYOUT_DISPLAY_FAILED;
        }
        applied = next;
        needs_save = true;
    }
    if (needs_save) {
        esp_err_t error = save_layout();
        if (error != ESP_OK) {
            ESP_LOGW(TAG, "Layout save failed: %s", esp_err_to_name(error));
            return DESK_LAYOUT_NOT_SAVED;
        }
        needs_save = false;
        ESP_LOGI(TAG, "LAYOUT_SAVED rotation=%u components=%u", applied.rotation, applied.count);
    }
    return DESK_LAYOUT_OK;
}
