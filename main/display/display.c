/* Panel timing and initialization adapted from OSPTEK's CC-BY-4.0 examples.
 * https://github.com/osptek/display-tft-5inch-720x1280
 * Board: OSPTEK ESP32-P4C5 V1.3 + YDP500BT004-V1.
 */
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/jpeg_decode.h"
#include "driver/ledc.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_ldo_regulator.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_jd9365.h"
#include "esp_timer.h"
#include "miniz.h"
#include "jd9365_init_cmds.h"
#include "display.h"
#include "layout.h"
#include "widget.h"
#include "frosted.h"

#define LCD_RESET GPIO_NUM_5
#define BACKLIGHT GPIO_NUM_20
#define BACKLIGHT_MODE LEDC_LOW_SPEED_MODE
#define BACKLIGHT_TIMER LEDC_TIMER_0
#define BACKLIGHT_CHANNEL LEDC_CHANNEL_0
#define BACKLIGHT_FREQ_HZ 25000u
#define BACKLIGHT_RESOLUTION LEDC_TIMER_10_BIT
#define FRAME_BYTES (DESK_LCD_WIDTH * DESK_LCD_HEIGHT * sizeof(uint16_t))

extern const uint8_t widget_font_start[] asm("_binary_widget_font_bin_start");
extern const uint8_t widget_font_end[] asm("_binary_widget_font_bin_end");

static const char *TAG = "DESK_DISPLAY";
static esp_lcd_panel_handle_t panel;
static uint16_t *frames[2];
static unsigned back = 1;
static unsigned pending_completions;
static SemaphoreHandle_t frame_done;
static _Atomic(TaskHandle_t) frame_waiter;
static jpeg_decoder_handle_t decoder;
static uint16_t *wallpaper;
static bool wallpaper_landscape;
static uint16_t *oriented_wallpaper;
static uint32_t *wallpaper_frost;
static uint16_t *decoded_pixels;
static uint8_t *decoded_alpha;
static size_t decoded_capacity;
static size_t decoded_alpha_capacity;
static desk_layout layout;

typedef struct {
    desk_rect rects[DESK_MAX_COMPONENTS];
    unsigned count;
} dirty_regions;

static dirty_regions dirty[2];
static bool render_requested;
static uint64_t model_present_count;
static uint64_t model_composition_us;
static bool model_frame_pending;

typedef struct {
    uint16_t id, width, height;
    uint16_t *pixels;
    uint8_t *alpha;
    size_t capacity, alpha_capacity;
} component_pixels;

static component_pixels surfaces[DESK_MAX_COMPONENTS];

typedef struct {
    component_pixels surface;
    desk_rect rect, ink;
    uint8_t rotation;
    bool needs_paint;
} widget_layer;

static widget_layer widgets[DESK_WIDGET_COUNT];

static bool on_frame_done(esp_lcd_panel_handle_t panel_handle,
                          esp_lcd_dpi_panel_event_data_t *event, void *context)
{
    BaseType_t wake = pdFALSE;
    xSemaphoreGiveFromISR(frame_done, &wake);
    TaskHandle_t waiter = atomic_exchange_explicit(&frame_waiter, NULL, memory_order_relaxed);
    if (waiter) vTaskNotifyGiveFromISR(waiter, &wake);
    return wake == pdTRUE;
}

static bool back_buffer_ready(TickType_t timeout)
{
    while (pending_completions) {
        if (xSemaphoreTake(frame_done, timeout) != pdTRUE) return false;
        --pending_completions;
    }
    return true;
}

static esp_err_t present(desk_rect rect)
{
    // With a panel-owned buffer the DPI driver swaps the whole frame and flushes these rows.
    esp_err_t result = esp_lcd_panel_draw_bitmap(panel, 0, rect.y, DESK_LCD_WIDTH,
                                                rect.y + rect.height, frames[back]);
    if (result != ESP_OK) return result;
    if(model_frame_pending && desk_layout_component(&layout,DESK_MODEL3D_ID)) ++model_present_count;
    model_frame_pending = false;
    back ^= 1u;
    while (xSemaphoreTake(frame_done, 0) == pdTRUE) {}
#if CONFIG_ESP_MAIN_TASK_AFFINITY == DESK_DISPLAY_CORE
    // The DMA interrupt is installed by app_main and shares the display task's
    // core. The next interrupt starts DMA on the newly selected frame buffer.
    pending_completions = 1;
#else
    // On separate cores an interrupt may already be reading the old index.
    pending_completions = 2;
#endif
    return ESP_OK;
}

static esp_err_t decode_jpeg(const uint8_t *jpeg, size_t length, uint16_t *output,
                             size_t capacity, unsigned width, unsigned height)
{
    jpeg_decode_picture_info_t info;
    esp_err_t result = jpeg_decoder_get_info(jpeg, length, &info);
    if (result != ESP_OK) return result;
    if (info.width != width || info.height != height) return ESP_ERR_INVALID_SIZE;
    size_t output_size = (size_t)width * height * sizeof(uint16_t);
    if (output_size > capacity) return ESP_ERR_INVALID_SIZE;

    // This byte order matches the panel's native little-endian RGB565 framebuffer.
    const jpeg_decode_cfg_t config = {
        .output_format = JPEG_DECODE_OUT_FORMAT_RGB565,
        .rgb_order = JPEG_DEC_RGB_ELEMENT_ORDER_BGR,
        .conv_std = JPEG_YUV_RGB_CONV_STD_BT601,
    };
    uint32_t bytes = 0;
    result = jpeg_decoder_process(decoder, &config, jpeg, length, (uint8_t *)output, output_size, &bytes);
    if (result != ESP_OK) return result;
    return bytes == output_size ? ESP_OK : ESP_ERR_INVALID_SIZE;
}

static esp_err_t load_widget_font(void)
{
    size_t compressed = widget_font_end - widget_font_start;
    if (compressed < 5) return ESP_ERR_INVALID_SIZE;
    const uint8_t *p = widget_font_start;
    size_t size = (size_t)p[0] | (size_t)p[1] << 8 | (size_t)p[2] << 16 | (size_t)p[3] << 24;
    if (!size || size > 1024u * 1024u) return ESP_ERR_INVALID_SIZE;
    uint8_t *font = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    tinfl_decompressor *decoder = heap_caps_malloc(sizeof(*decoder), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!font || !decoder) {
        free(decoder);
        free(font);
        return ESP_ERR_NO_MEM;
    }
    size_t input = compressed - 4, output = size;
    tinfl_init(decoder);
    tinfl_status result = tinfl_decompress(decoder, p + 4, &input, font, font, &output,
                                           TINFL_FLAG_PARSE_ZLIB_HEADER | TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
    free(decoder);
    if (result != TINFL_STATUS_DONE || output != size || !desk_widget_load_font(font, size)) {
        free(font);
        return ESP_ERR_INVALID_CRC;
    }
    ESP_LOGI(TAG, "Widget font: MiSans by Xiaomi");
    return ESP_OK;
}

#define DISPLAY_TRY(expr) ESP_RETURN_ON_ERROR((expr), TAG, "%s", #expr)

static const uint16_t *display_wallpaper(void)
{
    return wallpaper && (layout.rotation || wallpaper_landscape) ? oriented_wallpaper : wallpaper;
}

static void orient_wallpaper(uint8_t rotation)
{
    if (wallpaper && (rotation || wallpaper_landscape))
        desk_layout_draw_wallpaper(oriented_wallpaper, wallpaper, rotation, wallpaper_landscape);
}

static void refresh_wallpaper_frost(void)
{
    if (!wallpaper) return;
    if (!wallpaper_frost) {
        wallpaper_frost = heap_caps_malloc(DESK_FROST_SAMPLES * sizeof(*wallpaper_frost),
                                           MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    if (wallpaper_frost)
        desk_frost_prepare(wallpaper_frost, display_wallpaper(), layout.rotation);
}

static void mark_all_dirty(void)
{
    dirty[0] = dirty[1] = (dirty_regions){
        .rects = {{0, 0, DESK_LCD_WIDTH, DESK_LCD_HEIGHT}}, .count = 1,
    };
    render_requested = true;
}

static void install_layout(desk_layout next)
{
    bool rotated = next.rotation != layout.rotation;
    if (rotated) orient_wallpaper(next.rotation);
    layout = next;
    if (rotated) refresh_wallpaper_frost();
    mark_all_dirty();
}

static component_pixels *find_surface(uint16_t id)
{
    for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) {
        if (surfaces[i].id == id) return &surfaces[i];
    }
    return NULL;
}

static bool surface_matches(const component_pixels *surface, const desk_component *component)
{
    return surface && component && surface->width == component->rect.width && surface->height == component->rect.height;
}

static const component_pixels *image_surface_for(const desk_component *component)
{
    const component_pixels *surface = find_surface(component->id);
    return surface_matches(surface, component) ? surface : NULL;
}

static const component_pixels *surface_for(const desk_component *component)
{
    const component_pixels *image = image_surface_for(component);
    if (image) return image;
    int index = desk_widget_index(component->id);
    if (index < 0) return NULL;
    const component_pixels *surface = &widgets[index].surface;
    return surface_matches(surface, component) ? surface : NULL;
}

static void release_surface(component_pixels *surface)
{
    free(surface->pixels);
    free(surface->alpha);
    *surface = (component_pixels){0};
}

static bool covers(desk_rect outer, desk_rect inner)
{
    return outer.x <= inner.x && outer.y <= inner.y &&
           outer.x + outer.width >= inner.x + inner.width && outer.y + outer.height >= inner.y + inner.height;
}

static bool overlaps(desk_rect a, desk_rect b)
{
    return a.x < b.x + b.width && b.x < a.x + a.width &&
           a.y < b.y + b.height && b.y < a.y + a.height;
}

static void add_dirty(dirty_regions *regions, desk_rect rect)
{
    for (unsigned i = 0; i < regions->count;) {
        if (overlaps(rect, regions->rects[i])) {
            rect = desk_rect_union(rect, regions->rects[i]);
            regions->rects[i] = regions->rects[--regions->count];
            i = 0;
        } else {
            ++i;
        }
    }
    if (regions->count == DESK_MAX_COMPONENTS) {
        while (regions->count) rect = desk_rect_union(rect, regions->rects[--regions->count]);
    }
    regions->rects[regions->count++] = rect;
}

static void mark_dirty(desk_rect logical)
{
    if (!logical.width || !logical.height) return;
    desk_rect native = desk_layout_native_rect(logical, layout.rotation);
    add_dirty(&dirty[0], native);
    add_dirty(&dirty[1], native);
    render_requested = true;
}

static esp_err_t paint_widget(const desk_component *component, int64_t now)
{
    widget_layer *layer = &widgets[desk_widget_index(component->id)];
    const desk_rect rect = component->rect;
    const unsigned stride = desk_jpeg_dimension(rect.width);
    const size_t count = (size_t)stride * rect.height;
    component_pixels *surface = &layer->surface;
    if (surface->capacity < count * sizeof(uint16_t)) {
        uint16_t *pixels = heap_caps_malloc(count * sizeof(*pixels), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        uint8_t *alpha = heap_caps_malloc(count, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!pixels || !alpha) {
            free(pixels);
            free(alpha);
            return ESP_ERR_NO_MEM;
        }
        release_surface(surface);
        *surface = (component_pixels){.id = component->id, .pixels = pixels, .alpha = alpha,
                                      .capacity = count * sizeof(*pixels), .alpha_capacity = count};
    }
    surface->width = rect.width;
    surface->height = rect.height;
    widget_canvas canvas = {
        .pixels = surface->pixels, .alpha = surface->alpha, .stride = stride,
        .width = rect.width, .height = rect.height,
    };
    widget_box ink = desk_widget_paint(component, &canvas, wallpaper ? wallpaper_frost : NULL, layout.rotation, now);
    desk_rect current = {rect.x + ink.x, rect.y + ink.y, ink.width, ink.height};
    if (layer->rotation == layout.rotation) mark_dirty(desk_rect_union(layer->ink, current));
    else mark_dirty(current);
    layer->ink = current;
    layer->rect = rect;
    layer->rotation = layout.rotation;
    layer->needs_paint = false;
    return ESP_OK;
}

static esp_err_t prepare_widgets(void)
{
    int64_t now = esp_timer_get_time() / 1000;
    for (unsigned i = 0; i < layout.count; ++i) {
        const desk_component *component = &layout.components[i];
        if (!desk_widget_supported(component) || image_surface_for(component)) continue;
        const widget_layer *layer = &widgets[desk_widget_index(component->id)];
        if (layer->needs_paint || !surface_matches(&layer->surface, component) || layer->rect.x != component->rect.x ||
            layer->rect.y != component->rect.y || layer->rotation != layout.rotation || desk_widget_due(component->id, now)) {
            DISPLAY_TRY(paint_widget(component, now));
        }
    }
    return ESP_OK;
}

static void compose(uint16_t *frame, desk_rect rect)
{
    bool draw_wallpaper = true;
    unsigned first = 0;
    for (unsigned i = layout.count; i > 0; --i) {
        const desk_component *component = &layout.components[i - 1];
        const component_pixels *surface = surface_for(component);
        if ((!surface && (component->id == DESK_PET_ID || component->id == DESK_MODEL3D_ID)) || (surface && surface->alpha)) continue;
        if (covers(desk_layout_native_rect(component->rect, layout.rotation), rect)) {
            draw_wallpaper = false;
            first = i - 1;
            break;
        }
    }
    if (draw_wallpaper) {
        const uint16_t *background = display_wallpaper();
        size_t offset = rect.y * DESK_LCD_WIDTH + rect.x;
        for (unsigned row = 0; row < rect.height; ++row, offset += DESK_LCD_WIDTH) {
            if (background) memcpy(frame + offset, background + offset, rect.width * sizeof(uint16_t));
            else for (unsigned x = 0; x < rect.width; ++x) frame[offset + x] = 0x1949;
        }
    }
    for (unsigned i = first; i < layout.count; ++i) {
        const desk_component *component = &layout.components[i];
        const component_pixels *surface = surface_for(component);
        if (!surface && (component->id == DESK_PET_ID || component->id == DESK_MODEL3D_ID)) continue;
        desk_layout_draw_component(frame, surface ? surface->pixels : NULL, surface ? surface->alpha : NULL,
                                   component->rect, layout.rotation, rect);
    }
}

static esp_err_t render(void)
{
    DISPLAY_TRY(prepare_widgets());
    dirty_regions *regions = &dirty[back];
    if (!render_requested || !regions->count) return ESP_OK;
    const bool model_frame=model_frame_pending;
    const int64_t composition_started=esp_timer_get_time();
    desk_rect flush = {0};
    for (unsigned i = 0; i < regions->count; ++i) {
        desk_rect rect = regions->rects[i];
        compose(frames[back], rect);
        flush = desk_rect_union(flush, rect);
    }
    DISPLAY_TRY(present(flush));
    if(model_frame) model_composition_us+=esp_timer_get_time()-composition_started;
    regions->count = 0;
    render_requested = false;
    return ESP_OK;
}

esp_err_t desk_display_flush(void)
{
    const TickType_t timeout = pdMS_TO_TICKS(150);
    if (!back_buffer_ready(timeout)) return ESP_ERR_TIMEOUT;
    DISPLAY_TRY(render());
    return back_buffer_ready(timeout) ? ESP_OK : ESP_ERR_TIMEOUT;
}

esp_err_t desk_display_set_backlight(uint8_t brightness)
{
    if (brightness == 0 || brightness == DESK_BACKLIGHT_MAX) {
        return ledc_stop(BACKLIGHT_MODE, BACKLIGHT_CHANNEL, brightness > 0);
    }
    const uint32_t duty = ((1u << BACKLIGHT_RESOLUTION) * brightness + DESK_BACKLIGHT_MAX / 2u) / DESK_BACKLIGHT_MAX;
    // Initialization and the scene task are the only writers to this channel.
    DISPLAY_TRY(ledc_set_duty(BACKLIGHT_MODE, BACKLIGHT_CHANNEL, duty));
    return ledc_update_duty(BACKLIGHT_MODE, BACKLIGHT_CHANNEL);
}

static esp_err_t start_backlight(uint8_t brightness)
{
    const ledc_timer_config_t timer = {
        .speed_mode = BACKLIGHT_MODE, .timer_num = BACKLIGHT_TIMER, .duty_resolution = BACKLIGHT_RESOLUTION,
        .freq_hz = BACKLIGHT_FREQ_HZ, .clk_cfg = LEDC_AUTO_CLK,
    };
    const ledc_channel_config_t channel = {
        .gpio_num = BACKLIGHT, .speed_mode = BACKLIGHT_MODE, .channel = BACKLIGHT_CHANNEL,
        .timer_sel = BACKLIGHT_TIMER, .duty = 0, .hpoint = 0,
    };
    DISPLAY_TRY(ledc_timer_config(&timer));
    DISPLAY_TRY(ledc_channel_config(&channel));
    return desk_display_set_backlight(brightness);
}

esp_err_t desk_display_init(desk_layout initial, uint8_t brightness)
{
    gpio_config_t bl = {.pin_bit_mask = 1ULL << BACKLIGHT, .mode = GPIO_MODE_OUTPUT};
    DISPLAY_TRY(gpio_config(&bl));
    DISPLAY_TRY(gpio_set_level(BACKLIGHT, 0));
    frame_done = xSemaphoreCreateCounting(2, 0);
    if (!frame_done) return ESP_ERR_NO_MEM;
    esp_ldo_channel_handle_t phy_power;
    esp_ldo_channel_config_t ldo_cfg = {.chan_id = 3, .voltage_mv = 2500};
    DISPLAY_TRY(esp_ldo_acquire_channel(&ldo_cfg, &phy_power));
    esp_lcd_dsi_bus_handle_t bus;
    esp_lcd_dsi_bus_config_t bus_cfg = {
        .bus_id = 0, .num_data_lanes = 2,
        .phy_clk_src = 0, .lane_bit_rate_mbps = 870,
    };
    DISPLAY_TRY(esp_lcd_new_dsi_bus(&bus_cfg, &bus));
    esp_lcd_panel_io_handle_t io;
    esp_lcd_dbi_io_config_t io_cfg = {.virtual_channel = 0, .lcd_cmd_bits = 8, .lcd_param_bits = 8};
    DISPLAY_TRY(esp_lcd_new_panel_io_dbi(bus, &io_cfg, &io));
    esp_lcd_dpi_panel_config_t dpi_cfg = {
        .dpi_clk_src = MIPI_DSI_DPI_CLK_SRC_DEFAULT, .dpi_clock_freq_mhz = 63,
        .virtual_channel = 0, .pixel_format = LCD_COLOR_PIXEL_FORMAT_RGB565, .num_fbs = 2,
        .video_timing = {
            .h_size = DESK_LCD_WIDTH, .v_size = DESK_LCD_HEIGHT,
            .hsync_back_porch = 42, .hsync_pulse_width = 8, .hsync_front_porch = 42,
            .vsync_back_porch = 12, .vsync_pulse_width = 4, .vsync_front_porch = 24,
        },
        .flags.use_dma2d = false,
    };
    jd9365_vendor_config_t vendor = {
        .init_cmds = lcd_init_cmds, .init_cmds_size = lcd_init_cmds_size,
        .mipi_config = {.dsi_bus = bus, .dpi_config = &dpi_cfg, .lane_num = 2},
    };
    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = LCD_RESET, .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16, .vendor_config = &vendor,
    };
    DISPLAY_TRY(esp_lcd_new_panel_jd9365(io, &panel_cfg, &panel));
    DISPLAY_TRY(esp_lcd_panel_reset(panel));
    DISPLAY_TRY(esp_lcd_panel_init(panel));
    DISPLAY_TRY(esp_lcd_dpi_panel_get_frame_buffer(panel, 2, (void **)&frames[0], (void **)&frames[1]));

    const esp_lcd_dpi_panel_event_callbacks_t callbacks = {.on_frame_buf_complete = on_frame_done};
    DISPLAY_TRY(esp_lcd_dpi_panel_register_event_callbacks(panel, &callbacks, NULL));
    DISPLAY_TRY(esp_lcd_panel_disp_on_off(panel, true));

    oriented_wallpaper = heap_caps_malloc(FRAME_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!oriented_wallpaper) return ESP_ERR_NO_MEM;

    const jpeg_decode_engine_cfg_t engine = {.timeout_ms = 1000};
    DISPLAY_TRY(jpeg_new_decoder_engine(&engine, &decoder));
    DISPLAY_TRY(load_widget_font());
    install_layout(initial);
    DISPLAY_TRY(desk_display_flush());
    DISPLAY_TRY(start_backlight(brightness));
    ESP_LOGI(TAG, "DESK_DISPLAY_READY %ux%u rotation=%u components=%u",
             DESK_LCD_WIDTH, DESK_LCD_HEIGHT, initial.rotation, initial.count);
    return ESP_OK;
}

static void wallpaper_changed(void)
{
    orient_wallpaper(layout.rotation);
    refresh_wallpaper_frost();
    for (unsigned i = 0; i < DESK_WIDGET_COUNT; ++i) widgets[i].needs_paint = true;
    mark_all_dirty();
}

esp_err_t desk_display_set_wallpaper(const uint8_t *jpeg, size_t length, unsigned width, unsigned height)
{
    const jpeg_decode_memory_alloc_cfg_t output = {.buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER};
    size_t capacity;
    uint16_t *next = jpeg_alloc_decoder_mem(FRAME_BYTES, &output, &capacity);
    if (!next) return ESP_ERR_NO_MEM;
    esp_err_t result = decode_jpeg(jpeg, length, next, capacity, width, height);
    if (result != ESP_OK) {
        free(next);
        return result;
    }

    uint16_t *previous = wallpaper;
    bool previous_landscape = wallpaper_landscape;
    wallpaper = next;
    wallpaper_landscape = width == DESK_LCD_HEIGHT;
    wallpaper_changed();
    result = desk_display_flush();
    if (result == ESP_OK) {
        free(previous);
    } else {
        wallpaper = previous;
        wallpaper_landscape = previous_landscape;
        wallpaper_changed();
        esp_err_t restore = desk_display_flush();
        if (restore != ESP_OK) ESP_LOGW(TAG, "Wallpaper restore pending: %s", esp_err_to_name(restore));
        free(next);
    }
    return result;
}

esp_err_t desk_display_set_layout(desk_layout next)
{
    if (!desk_layout_valid(next)) return ESP_ERR_INVALID_ARG;
    if (desk_layout_equal(layout, next)) return ESP_OK;
    desk_layout previous = layout;
    install_layout(next);
    esp_err_t result = desk_display_flush();
    if (result != ESP_OK) {
        install_layout(previous);
        esp_err_t restore = desk_display_flush();
        if (restore != ESP_OK) ESP_LOGW(TAG, "Layout restore pending: %s", esp_err_to_name(restore));
    } else {
        for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) {
            component_pixels *surface = &surfaces[i];
            if (surface->id && !surface_matches(surface, desk_layout_component(&layout, surface->id))) {
                release_surface(surface);
            }
        }
        for (unsigned i = 0; i < DESK_WIDGET_COUNT; ++i) {
            uint16_t id = DESK_WIDGET_GARMIN + i;
            if (!desk_widget_supported(desk_layout_component(&layout, id))) {
                release_surface(&widgets[i].surface);
                widgets[i] = (widget_layer){0};
                desk_widget_forget(id);
            }
        }
    }
    return result;
}

esp_err_t desk_display_frame(uint16_t id, const desk_frame_data *frame)
{
    const desk_component *component = desk_layout_component(&layout, id);
    if (!component) return ESP_ERR_NOT_FOUND;
    const desk_rect rect = component->rect;
    unsigned width = desk_jpeg_dimension(rect.width), height = desk_jpeg_dimension(rect.height);
    component_pixels *surface = find_surface(id);
    if (!surface) surface = find_surface(0);
    if (!surface) return ESP_ERR_NO_MEM;
    size_t bytes = (size_t)width * height * sizeof(uint16_t);
    if (decoded_capacity < bytes) {
        const jpeg_decode_memory_alloc_cfg_t output = {.buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER};
        size_t capacity;
        uint16_t *pixels = jpeg_alloc_decoder_mem(bytes, &output, &capacity);
        if (!pixels) return ESP_ERR_NO_MEM;
        free(decoded_pixels);
        decoded_pixels = pixels;
        decoded_capacity = capacity;
    }
    if (frame->mask) {
        size_t pixels = (size_t)width * height;
        size_t max_pixels = id == DESK_PET_ID ? DESK_MAX_PET_PIXELS : DESK_MAX_PICTURE_PIXELS;
        if (pixels > max_pixels) return ESP_ERR_INVALID_SIZE;
        if (decoded_alpha_capacity < pixels) {
            uint8_t *alpha = heap_caps_malloc(pixels, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (!alpha) return ESP_ERR_NO_MEM;
            free(decoded_alpha);
            decoded_alpha = alpha;
            decoded_alpha_capacity = pixels;
        }
        if (!desk_unpack_alpha(frame->mask, frame->mask_length, decoded_alpha, pixels)) return ESP_ERR_INVALID_ARG;
    }
    esp_err_t result = decode_jpeg(frame->jpeg, frame->jpeg_length, decoded_pixels, decoded_capacity, width, height);
    if (result != ESP_OK) return result;
    // Keep the displayed pixels intact until decoding succeeds, then exchange buffers.
    component_pixels previous = *surface;
    *surface = (component_pixels){
        .id = id, .width = rect.width, .height = rect.height,
        .pixels = decoded_pixels, .capacity = decoded_capacity,
        .alpha = frame->mask ? decoded_alpha : NULL, .alpha_capacity = frame->mask ? decoded_alpha_capacity : 0,
    };
    decoded_pixels = previous.pixels;
    decoded_capacity = previous.capacity;
    if (frame->mask) {
        decoded_alpha = previous.alpha;
        decoded_alpha_capacity = previous.alpha_capacity;
    } else {
        free(previous.alpha);
    }
    mark_dirty(rect);
    return ESP_OK;
}

esp_err_t desk_display_widget_update(uint16_t id, const uint8_t *data, size_t size, bool has_glyphs)
{
    const desk_component *component = desk_layout_component(&layout, id);
    if (!desk_widget_supported(component)) return ESP_ERR_NOT_SUPPORTED;
    const uint8_t *glyphs = NULL;
    size_t glyphs_size = 0;
    if (has_glyphs) {
        if (size < 6) return ESP_ERR_INVALID_ARG;
        size_t json_size = data[0] | (size_t)data[1] << 8;
        if (json_size < 2 || json_size > size - 4) return ESP_ERR_INVALID_ARG;
        data += 2;
        glyphs = data + json_size;
        glyphs_size = size - 2 - json_size;
        size = json_size;
    }
    int64_t now = esp_timer_get_time() / 1000;
    if (!desk_widget_update(id, data, size, glyphs, glyphs_size, now)) return ESP_ERR_INVALID_ARG;
    component_pixels *legacy = find_surface(id);
    if (legacy) {
        DISPLAY_TRY(paint_widget(component, now));
        release_surface(legacy);
        mark_dirty(component->rect);
    } else {
        widgets[desk_widget_index(id)].needs_paint = true;
        render_requested = true;
    }
    return ESP_OK;
}

esp_err_t desk_display_paint_pet(widget_box (*paint)(widget_canvas *, void *), void *context)
{
    const desk_component *component = desk_layout_component(&layout, DESK_PET_ID);
    if (!component) return ESP_ERR_NOT_FOUND;
    const desk_rect rect = component->rect;
    component_pixels *surface = find_surface(DESK_PET_ID);
    if (!surface) surface = find_surface(0);
    if (!surface) return ESP_ERR_NO_MEM;

    unsigned stride = desk_jpeg_dimension(rect.width);
    size_t pixels_count = (size_t)stride * rect.height;
    size_t bytes = pixels_count * sizeof(uint16_t);
    if (surface->capacity < bytes || surface->alpha_capacity < pixels_count) {
        // This surface can later enter the JPEG scratch pool.
        const jpeg_decode_memory_alloc_cfg_t output = {.buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER};
        size_t capacity;
        uint16_t *pixels = jpeg_alloc_decoder_mem(bytes, &output, &capacity);
        uint8_t *alpha = heap_caps_malloc(pixels_count, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!pixels || !alpha) {
            free(pixels);
            free(alpha);
            return ESP_ERR_NO_MEM;
        }
        release_surface(surface);
        *surface = (component_pixels){.pixels = pixels, .capacity = capacity,
                                      .alpha = alpha, .alpha_capacity = pixels_count};
    }
    surface->id = DESK_PET_ID;
    surface->width = rect.width;
    surface->height = rect.height;
    widget_canvas canvas = {.pixels = surface->pixels, .alpha = surface->alpha,
                            .stride = stride, .width = rect.width, .height = rect.height,
                            .clip = {0, 0, rect.width, rect.height}};
    widget_box changed = paint(&canvas, context);
    if (!changed.width || !changed.height) return ESP_OK;
    mark_dirty((desk_rect){rect.x + changed.x, rect.y + changed.y, changed.width, changed.height});
    return ESP_OK;
}

uint64_t desk_display_present_count(void) { return model_present_count; }
uint64_t desk_display_model_composition_us(void) { return model_composition_us; }

esp_err_t desk_display_paint_model3d(widget_box (*paint)(widget_canvas *, void *), void *context)
{
    const desk_component *component = desk_layout_component(&layout, DESK_MODEL3D_ID);
    if (!component) return ESP_ERR_NOT_FOUND;
    component_pixels *surface = find_surface(DESK_MODEL3D_ID);
    if (!surface) surface = find_surface(0);
    if (!surface) return ESP_ERR_NO_MEM;
    const desk_rect rect = component->rect;
    unsigned stride = desk_jpeg_dimension(rect.width);
    size_t count = (size_t)stride * rect.height, bytes = count * 2;
    if (surface->capacity < bytes || surface->alpha_capacity < count) {
        const jpeg_decode_memory_alloc_cfg_t output = {.buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER};
        size_t capacity;
        uint16_t *pixels = jpeg_alloc_decoder_mem(bytes, &output, &capacity);
        uint8_t *alpha = heap_caps_calloc(count, 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!pixels || !alpha) { free(pixels); free(alpha); return ESP_ERR_NO_MEM; }
        release_surface(surface);
        *surface = (component_pixels){.pixels = pixels, .capacity = capacity, .alpha = alpha, .alpha_capacity = count};
    }
    surface->id = DESK_MODEL3D_ID; surface->width = rect.width; surface->height = rect.height;
    widget_canvas canvas = {.pixels=surface->pixels,.alpha=surface->alpha,.stride=stride,.width=rect.width,.height=rect.height,
                            .clip={0,0,rect.width,rect.height}};
    widget_box changed = paint(&canvas,context);
    if (!changed.width || !changed.height) return ESP_OK;
    model_frame_pending = true;
    mark_dirty((desk_rect){rect.x+changed.x,rect.y+changed.y,changed.width,changed.height});
    return ESP_OK;
}

static bool timed_widget_due(uint16_t id, int64_t now)
{
    const desk_component *component = desk_layout_component(&layout, id);
    return desk_widget_supported(component) && !image_surface_for(component) && desk_widget_due(id, now);
}

void desk_display_tick(void)
{
    int64_t now = esp_timer_get_time() / 1000;
    // Surfaces can keep receiving updates while the LCD still owns the other buffer.
    if ((render_requested || timed_widget_due(DESK_WIDGET_NOTICE, now)) && desk_display_frame_ready()) {
        esp_err_t result = render();
        if (result != ESP_OK) ESP_LOGW(TAG, "Frame submit pending: %s", esp_err_to_name(result));
    }
}

bool desk_display_frame_ready(void)
{
    if (back_buffer_ready(0)) return true;
    atomic_store_explicit(&frame_waiter, xTaskGetCurrentTaskHandle(), memory_order_relaxed);
    // Recheck after registering in case the interrupt arrived before the store.
    if (!back_buffer_ready(0)) return false;
    atomic_store_explicit(&frame_waiter, NULL, memory_order_relaxed);
    return true;
}

void desk_display_hide_component(uint16_t id)
{
    const desk_component *component = desk_layout_component(&layout, id);
    if (!component) return;
    component_pixels *surface = find_surface(id);
    if (surface) release_surface(surface);
    mark_dirty(component->rect);
}
