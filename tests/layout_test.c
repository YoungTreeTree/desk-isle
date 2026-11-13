#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "layout.h"

static uint16_t frame[DESK_LCD_WIDTH * DESK_LCD_HEIGHT];
static uint16_t pixels[160 * 96];
static uint16_t wallpaper[DESK_LCD_WIDTH * DESK_LCD_HEIGHT];

static size_t native_index(unsigned x, unsigned y, uint8_t rotation)
{
    switch (rotation) {
        case 1: return (DESK_LCD_HEIGHT - 1 - x) * DESK_LCD_WIDTH + y;
        case 2: return (DESK_LCD_HEIGHT - 1 - y) * DESK_LCD_WIDTH + DESK_LCD_WIDTH - 1 - x;
        case 3: return x * DESK_LCD_WIDTH + DESK_LCD_WIDTH - 1 - y;
        default: return y * DESK_LCD_WIDTH + x;
    }
}

static void check_saved_layout_migration(void)
{
    desk_layout legacy = {
        .rotation = 3,
        .count = 2,
        .components = {
            {DESK_PET_ID, {400, 401, DESK_PET_WIDTH, DESK_PET_HEIGHT}},
            {2, {30, 43, 153, 81}},
        },
    };
    uint8_t payload[DESK_LAYOUT_WIRE_MAX];
    size_t length = desk_layout_encode(&legacy, payload);
    desk_layout restored;
    bool migrated;
    assert(!desk_layout_decode(&restored, payload, length));
    assert(desk_layout_decode_saved(&restored, payload, length, &migrated) && migrated);
    assert(restored.rotation == legacy.rotation && restored.count == legacy.count);
    assert(restored.components[0].rect.x == 384 && restored.components[0].rect.y == 416);
    const desk_rect widget = restored.components[1].rect;
    assert(widget.x == 40 && widget.y == 40 && widget.width == 160 && widget.height == 80);
    assert(desk_layout_valid(restored));

    length = desk_layout_encode(&restored, payload);
    assert(desk_layout_decode_saved(&restored, payload, length, &migrated) && !migrated);

    legacy.rotation = 0;
    legacy.count = 3;
    legacy.components[0] = (desk_component){2, {0, 0, 720, 1263}};
    legacy.components[1] = (desk_component){3, {0, 0, 720, 1263}};
    legacy.components[2] = (desk_component){4, {719, 0, 1, 1280}};
    length = desk_layout_encode(&legacy, payload);
    assert(desk_layout_decode_saved(&restored, payload, length, &migrated) && migrated);
    assert(restored.count == 3 && desk_layout_valid(restored));
    assert(restored.components[2].id == 4 && restored.components[2].rect.x == 680);
}

static void check_retired_music_migration(void)
{
    const desk_layout expected = {
        .rotation = 3,
        .count = 2,
        .components = {
            {0x8005, {960, 0, 320, 160}},
            {2, {400, 440, 160, 80}},
        },
    };
    desk_layout old = expected;
    old.components[2] = expected.components[1];
    old.components[1] = (desk_component){0x8006, {440, 280, 400, 120}};
    old.count = 3;

    uint8_t payload[DESK_LAYOUT_WIRE_MAX];
    size_t length = desk_layout_encode(&old, payload);
    desk_layout restored;
    bool migrated;
    assert(!desk_layout_valid(old));
    assert(!desk_layout_decode(&restored, payload, length));
    assert(desk_layout_decode_saved(&restored, payload, length, &migrated) && migrated);
    assert(desk_layout_equal(restored, expected));

    length = desk_layout_encode(&restored, payload);
    assert(desk_layout_decode_saved(&restored, payload, length, &migrated) && !migrated);
    assert(desk_layout_equal(restored, expected));
}

static void check_pet_presets(void)
{
    desk_layout large = desk_layout_default();
    large.components[0].rect = (desk_rect){8, 880, DESK_PET_LARGE_WIDTH, DESK_PET_LARGE_HEIGHT};
    assert(desk_layout_valid(large));
    uint8_t payload[DESK_LAYOUT_WIRE_MAX];
    desk_layout restored;
    bool migrated;
    size_t length = desk_layout_encode(&large, payload);
    assert(desk_layout_decode_saved(&restored, payload, length, &migrated) && !migrated);
    assert(desk_layout_equal(large, restored));

    ++large.components[0].rect.x;
    length = desk_layout_encode(&large, payload);
    assert(!desk_layout_decode(&restored, payload, length));
    assert(desk_layout_decode_saved(&restored, payload, length, &migrated) && migrated);
    assert(restored.components[0].rect.x == 8);

    large.rotation = 3;
    large.components[0].rect = (desk_rect){288, 320, DESK_PET_LARGE_WIDTH, DESK_PET_LARGE_HEIGHT};
    length = desk_layout_encode(&large, payload);
    assert(desk_layout_decode(&restored, payload, length) && desk_layout_equal(large, restored));
    large.components[0].rect.width -= 16;
    assert(!desk_layout_valid(large));
}

static void check_landscape_wallpaper(void)
{
    for (size_t i = 0; i < sizeof(wallpaper) / sizeof(*wallpaper); ++i) {
        wallpaper[i] = (uint16_t)i;
    }
    for (uint8_t rotation = 1; rotation < 4; rotation += 2) {
        desk_layout_draw_wallpaper(frame, wallpaper, rotation, true);
        for (unsigned y = 0; y < DESK_LCD_WIDTH; ++y) {
            for (unsigned x = 0; x < DESK_LCD_HEIGHT; ++x) {
                assert(frame[native_index(x, y, rotation)] == wallpaper[y * DESK_LCD_HEIGHT + x]);
            }
        }
    }

    // The landscape wallpaper also covers the portrait view while it waits for a new upload.
    for (uint8_t rotation = 0; rotation < 4; rotation += 2) {
        desk_layout_draw_wallpaper(frame, wallpaper, rotation, true);
        assert(frame[native_index(0, 0, rotation)] == wallpaper[437]);
        assert(frame[native_index(719, 1279, rotation)] == wallpaper[719 * DESK_LCD_HEIGHT + 841]);
    }
}

int main(void)
{
    check_saved_layout_migration();
    check_retired_music_migration();
    check_pet_presets();
    check_landscape_wallpaper();
    const desk_rect widget = {30, 43, 153, 81};
    const desk_rect overlay = {60, 60, 71, 33};
    const desk_rect translucent = {85, 67, 19, 18};
    const uint16_t colors[32 * 32] = {[0] = 0xffff, [8 * 32 + 9] = 0x8000, [17 * 32 + 16] = 0xffff};
    const uint8_t alpha[32 * 32] = {[8 * 32 + 9] = 128, [17 * 32 + 16] = 255};
    const unsigned stride = desk_jpeg_dimension(widget.width);
    memset(pixels, 0xff, sizeof(pixels));
    for (unsigned y = 0; y < widget.height; ++y) {
        for (unsigned x = 0; x < widget.width; ++x) pixels[y * stride + x] = 1 + y * widget.width + x;
    }
    for (uint8_t rotation = 0; rotation < 4; ++rotation) {
        desk_layout layout = desk_layout_default();
        layout.rotation = rotation;
        layout.components[0].rect.y = 320 + DESK_PET_INSET_Y;
        layout.components[1] = (desk_component){2, {40, 40, 160, 80}};
        layout.components[2] = (desk_component){3, {80, 40, 80, 120}};
        layout.count = 3;
        assert(desk_layout_valid(layout));
        layout.components[1].rect.x++;
        assert(!desk_layout_valid(layout));
        layout.components[1].rect.x--;

        uint8_t payload[DESK_LAYOUT_WIRE_MAX];
        size_t length = desk_layout_encode(&layout, payload);
        desk_layout restored = {0};
        assert(desk_layout_decode(&restored, payload, length));
        assert(desk_layout_equal(layout, restored));
        assert(!desk_layout_decode(&restored, payload, length - 1));
        payload[12] = 1; // Duplicate the first component's ID.
        assert(!desk_layout_decode(&restored, payload, length));
        layout.components[1].rect.x = DESK_LCD_HEIGHT;
        assert(!desk_layout_valid(layout));

        memset(frame, 0, sizeof(frame));
        const desk_rect area = desk_layout_native_rect(widget, rotation);
        desk_layout_draw_component(frame, pixels, NULL, widget, rotation, area);
        // Redraw only a slice of the upper layer, leaving the rest of the lower layer intact.
        const desk_rect slice = {overlay.x, overlay.y, 17, 13};
        desk_layout_draw_component(frame, NULL, NULL, overlay, rotation, desk_layout_native_rect(slice, rotation));
        for (unsigned y = 0; y < widget.height; ++y) {
            for (unsigned x = 0; x < widget.width; ++x) {
                unsigned screen_x = widget.x + x, screen_y = widget.y + y;
                bool covered = screen_x >= slice.x && screen_x < slice.x + slice.width &&
                               screen_y >= slice.y && screen_y < slice.y + slice.height;
                assert(frame[native_index(screen_x, screen_y, rotation)] == (covered ? 0x39e9 : pixels[y * stride + x]));
            }
        }
        assert(frame[native_index(widget.x - 1, widget.y, rotation)] == 0);
        assert(frame[native_index(widget.x + widget.width, widget.y, rotation)] == 0);

        for (unsigned y = 0; y < translucent.height; ++y) {
            for (unsigned x = 0; x < translucent.width; ++x) {
                frame[native_index(translucent.x + x, translucent.y + y, rotation)] = 0x001f;
            }
        }
        desk_layout_draw_component(frame, colors, alpha, translucent, rotation,
                                   desk_layout_native_rect(translucent, rotation));
        assert(frame[native_index(translucent.x, translucent.y, rotation)] == 0x001f);
        assert(frame[native_index(translucent.x + 9, translucent.y + 8, rotation)] == 0x800f);
        assert(frame[native_index(translucent.x + 16, translucent.y + 17, rotation)] == 0xffff);
    }
    puts("PASS grid validation, saved layout migration, clipped stacking, alpha blending and native wallpaper rotation");
}
