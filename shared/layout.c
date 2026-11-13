#include <stddef.h>
#include <string.h>
#include "layout.h"

static const uint16_t retired_music_id = 0x8006;

typedef struct {
    uint16_t width, height, footprint_width, footprint_height;
} pet_preset;

static const pet_preset *find_pet_preset(desk_rect rect)
{
    static const pet_preset presets[] = {
        {DESK_PET_WIDTH, DESK_PET_HEIGHT, DESK_PET_FOOTPRINT_WIDTH, DESK_PET_FOOTPRINT_HEIGHT},
        {DESK_PET_LARGE_WIDTH, DESK_PET_LARGE_HEIGHT, DESK_PET_LARGE_FOOTPRINT_WIDTH, DESK_PET_LARGE_FOOTPRINT_HEIGHT},
    };
    for (size_t i = 0; i < sizeof(presets) / sizeof(presets[0]); ++i) {
        if (presets[i].width == rect.width && presets[i].height == rect.height) return &presets[i];
    }
    return NULL;
}

desk_layout desk_layout_default(void)
{
    return (desk_layout){
        .count = 1,
        .components = {{
            .id = DESK_PET_ID,
            .rect = {(DESK_LCD_WIDTH - DESK_PET_FOOTPRINT_WIDTH) / 2 + DESK_PET_INSET_X,
                     DESK_LCD_HEIGHT - DESK_PET_FOOTPRINT_HEIGHT + DESK_PET_INSET_Y,
                     DESK_PET_WIDTH, DESK_PET_HEIGHT},
        }},
    };
}

unsigned desk_jpeg_dimension(unsigned pixels)
{
    return (pixels + 15u) & ~15u;
}

static unsigned layout_width(const desk_layout *layout)
{
    return layout->rotation % 2 ? DESK_LCD_HEIGHT : DESK_LCD_WIDTH;
}

static unsigned layout_height(const desk_layout *layout)
{
    return layout->rotation % 2 ? DESK_LCD_WIDTH : DESK_LCD_HEIGHT;
}

static unsigned component_pixels(desk_rect rect)
{
    return desk_jpeg_dimension(rect.width) * desk_jpeg_dimension(rect.height);
}

static bool layout_pixels_valid(const desk_layout *layout)
{
    if (layout->rotation >= 4 || layout->count > DESK_MAX_COMPONENTS) return false;
    unsigned width = layout_width(layout), height = layout_height(layout);
    unsigned pixels = 0;
    for (unsigned i = 0; i < layout->count; ++i) {
        const desk_component component = layout->components[i];
        const desk_rect rect = component.rect;
        if (!component.id || !rect.width || !rect.height ||
            rect.x + rect.width > width || rect.y + rect.height > height) return false;
        if (component.id == DESK_PET_ID && !find_pet_preset(rect)) return false;
        if (component.id == 0x8007 && !(rect.width == 320 && rect.height == 480) &&
            (rect.x || rect.y || rect.width != width || rect.height != height)) return false;
        for (unsigned j = 0; j < i; ++j) {
            if (layout->components[j].id == component.id) return false;
        }
        pixels += component_pixels(rect);
    }
    return pixels <= DESK_MAX_COMPONENT_PIXELS;
}

static bool layout_on_grid(const desk_layout *layout)
{
    unsigned width = layout_width(layout), height = layout_height(layout);
    for (unsigned i = 0; i < layout->count; ++i) {
        const desk_component component = layout->components[i];
        desk_rect footprint = component.rect;
        if (component.id == DESK_PET_ID) {
            const pet_preset *preset = find_pet_preset(component.rect);
            if (!preset) return false;
            unsigned inset_x = (preset->footprint_width - preset->width) / 2u;
            unsigned inset_y = (preset->footprint_height - preset->height) / 2u;
            if (footprint.x < inset_x || footprint.y < inset_y) return false;
            footprint.x -= inset_x;
            footprint.y -= inset_y;
            footprint.width = preset->footprint_width;
            footprint.height = preset->footprint_height;
        }
        if (footprint.x % DESK_GRID_PX || footprint.y % DESK_GRID_PX ||
            footprint.width % DESK_GRID_PX || footprint.height % DESK_GRID_PX ||
            footprint.x + footprint.width > width || footprint.y + footprint.height > height) return false;
    }
    return true;
}

bool desk_layout_valid(desk_layout layout)
{
    return layout_pixels_valid(&layout) && layout_on_grid(&layout) &&
           !desk_layout_component(&layout, retired_music_id);
}

bool desk_layout_equal(desk_layout a, desk_layout b)
{
    if (a.rotation != b.rotation || a.count != b.count) return false;
    for (unsigned i = 0; i < a.count; ++i) {
        const desk_component first = a.components[i], second = b.components[i];
        if (first.id != second.id || first.rect.x != second.rect.x || first.rect.y != second.rect.y ||
            first.rect.width != second.rect.width || first.rect.height != second.rect.height) return false;
    }
    return true;
}

const desk_component *desk_layout_component(const desk_layout *layout, uint16_t id)
{
    for (unsigned i = 0; i < layout->count; ++i) {
        if (layout->components[i].id == id) return &layout->components[i];
    }
    return NULL;
}

size_t desk_layout_encode(const desk_layout *layout, uint8_t *bytes)
{
    bytes[0] = layout->rotation;
    bytes[1] = layout->count;
    size_t offset = 2;
    for (unsigned i = 0; i < layout->count; ++i) {
        const desk_component component = layout->components[i];
        const desk_rect rect = component.rect;
        const uint16_t fields[] = {component.id, rect.x, rect.y, rect.width, rect.height};
        for (unsigned field = 0; field < 5; ++field) {
            bytes[offset++] = fields[field];
            bytes[offset++] = fields[field] >> 8;
        }
    }
    return offset;
}

static uint16_t read_u16(const uint8_t *bytes)
{
    return bytes[0] | (uint16_t)bytes[1] << 8;
}

static bool decode_pixels(desk_layout *layout, const uint8_t *bytes, size_t length)
{
    if (length < 2 || bytes[1] > DESK_MAX_COMPONENTS || length != 2u + 10u * bytes[1]) return false;
    desk_layout decoded = {.rotation = bytes[0], .count = bytes[1]};
    for (unsigned i = 0; i < decoded.count; ++i) {
        const uint8_t *record = bytes + 2 + 10 * i;
        decoded.components[i] = (desk_component){
            .id = read_u16(record),
            .rect = {read_u16(record + 2), read_u16(record + 4), read_u16(record + 6), read_u16(record + 8)},
        };
    }
    if (!layout_pixels_valid(&decoded)) return false;
    *layout = decoded;
    return true;
}

bool desk_layout_decode(desk_layout *layout, const uint8_t *bytes, size_t length)
{
    desk_layout decoded;
    if (!decode_pixels(&decoded, bytes, length) || !layout_on_grid(&decoded) ||
        desk_layout_component(&decoded, retired_music_id)) return false;
    *layout = decoded;
    return true;
}

static unsigned snap_size(unsigned pixels)
{
    unsigned cells = (pixels + DESK_GRID_PX / 2u) / DESK_GRID_PX;
    return (cells ? cells : 1u) * DESK_GRID_PX;
}

static unsigned snap_center(unsigned origin, unsigned old_size, unsigned new_size, unsigned panel_size)
{
    // Twice the coordinate keeps half-pixel centers exact when rounding to cells.
    int twice_origin = 2 * (int)origin + (int)old_size - (int)new_size;
    unsigned cell = twice_origin > 0 ? ((unsigned)twice_origin + DESK_GRID_PX) / (2u * DESK_GRID_PX) : 0;
    unsigned last_cell = (panel_size - new_size) / DESK_GRID_PX;
    return (cell < last_cell ? cell : last_cell) * DESK_GRID_PX;
}

static void snap_saved_layout(desk_layout *layout)
{
    const desk_layout original = *layout;
    unsigned pixels = 0;
    for (unsigned i = 0; i < layout->count; ++i) {
        desk_component *component = &layout->components[i];
        if (component->id != DESK_PET_ID) {
            component->rect.width = snap_size(component->rect.width);
            component->rect.height = snap_size(component->rect.height);
        }
        pixels += component_pixels(component->rect);
    }

    // Rounding old sizes up can exceed the pixel budget. Reduce the largest
    // adjustable footprint first and keep every component in the layout.
    while (pixels > DESK_MAX_COMPONENT_PIXELS) {
        desk_rect *largest = NULL;
        unsigned largest_pixels = 0;
        for (unsigned i = 0; i < layout->count; ++i) {
            desk_component *component = &layout->components[i];
            desk_rect *rect = &component->rect;
            if (component->id == DESK_PET_ID || (rect->width == DESK_GRID_PX && rect->height == DESK_GRID_PX)) continue;
            unsigned area = component_pixels(*rect);
            if (area > largest_pixels) {
                largest = rect;
                largest_pixels = area;
            }
        }
        if (!largest) break;
        if (largest->width >= largest->height) {
            largest->width -= DESK_GRID_PX;
        } else {
            largest->height -= DESK_GRID_PX;
        }
        pixels -= largest_pixels - component_pixels(*largest);
    }

    unsigned width = layout_width(layout), height = layout_height(layout);
    for (unsigned i = 0; i < layout->count; ++i) {
        desk_component *component = &layout->components[i];
        desk_rect old = original.components[i].rect;
        const pet_preset *pet = component->id == DESK_PET_ID ? find_pet_preset(old) : NULL;
        unsigned footprint_width = pet ? pet->footprint_width : component->rect.width;
        unsigned footprint_height = pet ? pet->footprint_height : component->rect.height;
        unsigned inset_x = pet ? (footprint_width - pet->width) / 2u : 0;
        unsigned inset_y = pet ? (footprint_height - pet->height) / 2u : 0;
        component->rect.x = snap_center(old.x, old.width, footprint_width, width) + inset_x;
        component->rect.y = snap_center(old.y, old.height, footprint_height, height) + inset_y;
    }
}

bool desk_layout_decode_saved(desk_layout *layout, const uint8_t *bytes, size_t length, bool *migrated)
{
    desk_layout decoded;
    if (!decode_pixels(&decoded, bytes, length)) return false;
    const desk_component *retired = desk_layout_component(&decoded, retired_music_id);
    if (retired) {
        size_t index = retired - decoded.components;
        --decoded.count;
        memmove(&decoded.components[index], &decoded.components[index + 1],
                (decoded.count - index) * sizeof(decoded.components[0]));
    }
    bool needs_grid = !layout_on_grid(&decoded);
    if (needs_grid) {
        snap_saved_layout(&decoded);
        if (!desk_layout_valid(decoded)) return false;
    }
    *layout = decoded;
    *migrated = retired || needs_grid;
    return true;
}

desk_rect desk_layout_native_rect(desk_rect logical, uint8_t rotation)
{
    unsigned x = logical.x, y = logical.y, w = logical.width, h = logical.height;
    switch (rotation) {
        case 1: return (desk_rect){y, DESK_LCD_HEIGHT - x - w, h, w};
        case 2: return (desk_rect){DESK_LCD_WIDTH - x - w, DESK_LCD_HEIGHT - y - h, w, h};
        case 3: return (desk_rect){DESK_LCD_WIDTH - y - h, x, h, w};
        default: return logical;
    }
}

static unsigned minimum(unsigned a, unsigned b) { return a < b ? a : b; }
static unsigned maximum(unsigned a, unsigned b) { return a > b ? a : b; }

desk_rect desk_rect_union(desk_rect a, desk_rect b)
{
    if (!a.width) return b;
    if (!b.width) return a;
    unsigned x = minimum(a.x, b.x), y = minimum(a.y, b.y);
    return (desk_rect){x, y, maximum(a.x + a.width, b.x + b.width) - x,
                       maximum(a.y + a.height, b.y + b.height) - y};
}

static unsigned blend_channel(unsigned source, unsigned background, unsigned limit, unsigned alpha)
{
    // JPEG can push a premultiplied channel slightly beyond its alpha.
    unsigned cap = (limit * alpha + 127) / 255;
    unsigned sum = minimum(source, cap) + (background * (255 - alpha) + 127) / 255;
    return minimum(sum, limit);
}

static uint16_t blend_pixel(uint16_t source, uint16_t background, unsigned alpha)
{
    unsigned red = blend_channel(source >> 11, background >> 11, 31, alpha);
    unsigned green = blend_channel((source >> 5) & 63, (background >> 5) & 63, 63, alpha);
    unsigned blue = blend_channel(source & 31, background & 31, 31, alpha);
    return (red << 11) | (green << 5) | blue;
}

void desk_layout_draw_component(uint16_t *frame, const uint16_t *pixels, const uint8_t *alpha,
                                desk_rect logical, uint8_t rotation, desk_rect dirty)
{
    const desk_rect rect = desk_layout_native_rect(logical, rotation);
    unsigned left = maximum(rect.x, dirty.x), top = maximum(rect.y, dirty.y);
    unsigned right = minimum(rect.x + rect.width, dirty.x + dirty.width);
    unsigned bottom = minimum(rect.y + rect.height, dirty.y + dirty.height);
    if (left >= right || top >= bottom) return;
    if (!pixels) {
        for (unsigned y = top; y < bottom; ++y) {
            uint16_t *dest = frame + y * DESK_LCD_WIDTH;
            for (unsigned x = left; x < right; ++x) dest[x] = 0x39e9;
        }
        return;
    }

    const ptrdiff_t stride = desk_jpeg_dimension(logical.width);
    const ptrdiff_t width = logical.width, height = logical.height;
    ptrdiff_t start = 0, row_step = stride, column_step = 1;
    switch (rotation) {
        case 1: start = width - 1; row_step = -1; column_step = stride; break;
        case 2: start = stride * (height - 1) + width - 1; row_step = -stride; column_step = -1; break;
        case 3: start = (height - 1) * stride; row_step = 1; column_step = -stride; break;
    }
    // Transpose in tiles so adjacent output rows reuse the same PSRAM cache lines.
    const unsigned tile_width = rotation % 2 ? 16 : right - left;
    const unsigned tile_height = rotation % 2 ? 16 : bottom - top;
    for (unsigned tile_y = top; tile_y < bottom; tile_y += tile_height) {
        unsigned end_y = minimum(tile_y + tile_height, bottom);
        for (unsigned tile_x = left; tile_x < right; tile_x += tile_width) {
            unsigned count = minimum(tile_width, right - tile_x);
            ptrdiff_t col_offset = (ptrdiff_t)(tile_x - rect.x) * column_step;
            for (unsigned y = tile_y; y < end_y; ++y) {
                uint16_t *dest = frame + y * DESK_LCD_WIDTH + tile_x;
                ptrdiff_t offset = start + (ptrdiff_t)(y - rect.y) * row_step + col_offset;
                const uint16_t *source = pixels + offset;
                if (alpha) {
                    const uint8_t *coverage = alpha + offset;
                    for (ptrdiff_t x = 0; x < count; ++x) {
                        ptrdiff_t pixel = x * column_step;
                        unsigned opacity = coverage[pixel];
                        if (opacity == 255) dest[x] = source[pixel];
                        else if (opacity) dest[x] = blend_pixel(source[pixel], dest[x], opacity);
                    }
                } else if (column_step == 1) {
                    memcpy(dest, source, count * sizeof(uint16_t));
                } else {
                    for (ptrdiff_t x = 0; x < count; ++x) dest[x] = source[x * column_step];
                }
            }
        }
    }
}

void desk_layout_draw_wallpaper(uint16_t *frame, const uint16_t *wallpaper, uint8_t rotation, bool source_landscape)
{
    const bool landscape = rotation % 2 != 0;
    if (source_landscape == landscape) {
        const desk_rect logical = landscape ? (desk_rect){0, 0, DESK_LCD_HEIGHT, DESK_LCD_WIDTH}
                                            : (desk_rect){0, 0, DESK_LCD_WIDTH, DESK_LCD_HEIGHT};
        desk_layout_draw_component(frame, wallpaper, NULL, logical, rotation,
                                   (desk_rect){0, 0, DESK_LCD_WIDTH, DESK_LCD_HEIGHT});
        return;
    }

    // Cover the viewport when the available wallpaper is for the other orientation.
    const unsigned crop = DESK_LCD_WIDTH * DESK_LCD_WIDTH / DESK_LCD_HEIGHT;
    const unsigned crop_start = (DESK_LCD_HEIGHT - crop) / 2;
    if (landscape) {
        const bool clockwise = rotation == 1;
        for (unsigned y = 0; y < DESK_LCD_HEIGHT; ++y) {
            unsigned logical_x = clockwise ? DESK_LCD_HEIGHT - 1 - y : y;
            unsigned source_x = logical_x * DESK_LCD_WIDTH / DESK_LCD_HEIGHT;
            for (unsigned x = 0; x < DESK_LCD_WIDTH; ++x) {
                unsigned logical_y = clockwise ? x : DESK_LCD_WIDTH - 1 - x;
                unsigned source_y = crop_start + logical_y * crop / DESK_LCD_WIDTH;
                frame[y * DESK_LCD_WIDTH + x] = wallpaper[source_y * DESK_LCD_WIDTH + source_x];
            }
        }
    } else {
        const bool inverted = rotation == 2;
        for (unsigned y = 0; y < DESK_LCD_HEIGHT; ++y) {
            unsigned logical_y = inverted ? DESK_LCD_HEIGHT - 1 - y : y;
            unsigned source_y = logical_y * DESK_LCD_WIDTH / DESK_LCD_HEIGHT;
            const uint16_t *row = wallpaper + source_y * DESK_LCD_HEIGHT;
            for (unsigned x = 0; x < DESK_LCD_WIDTH; ++x) {
                unsigned logical_x = inverted ? DESK_LCD_WIDTH - 1 - x : x;
                unsigned source_x = crop_start + logical_x * crop / DESK_LCD_WIDTH;
                frame[y * DESK_LCD_WIDTH + x] = row[source_x];
            }
        }
    }
}
