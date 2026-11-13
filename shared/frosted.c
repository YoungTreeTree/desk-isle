#include "frosted.h"

#define RGB565(r, g, b) (((r) & 248u) << 8 | ((g) & 252u) << 3 | (b) >> 3)

const desk_frost_style *desk_frost_style_for(bool dark)
{
    static const desk_frost_style styles[] = {
        {
            .ink = RGB565(18, 31, 51), .muted = RGB565(41, 56, 77),
            .accent = RGB565(15, 89, 82), .chart_amber = RGB565(158, 77, 38),
            .tile_opacity = 43, .badge_opacity = 71,
            .highlight = 33, .shadow = 10, .rim_top = 161, .rim_middle = 61, .rim_bottom = 41,
        },
        {
            .ink = RGB565(240, 247, 255), .muted = RGB565(204, 219, 237),
            .accent = RGB565(125, 232, 209), .chart_amber = RGB565(255, 173, 115),
            .tile_opacity = 20, .badge_opacity = 26,
            .highlight = 26, .shadow = 31, .rim_top = 94, .rim_middle = 36, .rim_bottom = 23,
        },
    };
    return &styles[dark];
}

static uint32_t rgb(unsigned r, unsigned g, unsigned b)
{
    return r << 16 | g << 8 | b;
}

static unsigned channel(uint32_t color, unsigned shift)
{
    return (color >> shift) & 255u;
}

static uint32_t blur_line(const uint32_t *line, int index, int length, int stride)
{
    // Two 7-tap box filters form a triangle with a 23 px standard deviation at this sample step.
    enum { RADIUS = 6, TOTAL = (RADIUS + 1) * (RADIUS + 1) };
    static const uint8_t weights[] = {1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1};
    unsigned r = 0, g = 0, b = 0;
    for (int i = 0; i <= 2 * RADIUS; ++i) {
        int at = index + i - RADIUS;
        if (at < 0) at = 0;
        if (at >= length) at = length - 1;
        uint32_t color = line[at * stride];
        unsigned weight = weights[i];
        r += channel(color, 16) * weight;
        g += channel(color, 8) * weight;
        b += channel(color, 0) * weight;
    }
    return rgb((r + TOTAL / 2) / TOTAL, (g + TOTAL / 2) / TOTAL, (b + TOTAL / 2) / TOTAL);
}

static unsigned tone_channel(unsigned color, int chroma, int bias)
{
    int value = ((int)color * chroma + bias + 50) / 100;
    if (value < 0) return 0;
    return value > 255 ? 255 : value;
}

static uint32_t tint(uint32_t color, int luma, bool dark)
{
    // Keep wallpaper hues while rolling highlights off in the dark palette.
    int chroma = dark ? 90 : 63;
    int brightness = dark ? 1500 + (10500 * luma) / (luma + 91) : 16400 + 29 * luma;
    int bias = brightness - chroma * luma;
    return rgb(tone_channel(channel(color, 16), chroma, bias),
               tone_channel(channel(color, 8), chroma, bias),
               tone_channel(channel(color, 0), chroma, bias));
}

void desk_frost_prepare(uint32_t *grid, const uint16_t *wallpaper, uint8_t rotation)
{
    const int columns = (rotation % 2 ? DESK_LCD_HEIGHT : DESK_LCD_WIDTH) / DESK_FROST_STEP;
    const int rows = DESK_FROST_CELLS / columns;
    const unsigned pixels = DESK_FROST_STEP * DESK_FROST_STEP;
    uint32_t *dark = grid + DESK_FROST_CELLS;
    for (int y = 0; y < rows; ++y) {
        for (int x = 0; x < columns; ++x) {
            desk_rect tile = {x * DESK_FROST_STEP, y * DESK_FROST_STEP, DESK_FROST_STEP, DESK_FROST_STEP};
            desk_rect native = desk_layout_native_rect(tile, rotation);
            const uint16_t *source = wallpaper + native.y * DESK_LCD_WIDTH + native.x;
            unsigned r = 0, g = 0, b = 0;
            for (unsigned row = 0; row < DESK_FROST_STEP; ++row) {
                for (unsigned col = 0; col < DESK_FROST_STEP; ++col) {
                    uint16_t pixel = source[row * DESK_LCD_WIDTH + col];
                    r += pixel >> 11;
                    g += (pixel >> 5) & 63;
                    b += pixel & 31;
                }
            }
            grid[y * columns + x] = rgb((r * 255 + 31 * pixels / 2) / (31 * pixels),
                                       (g * 255 + 63 * pixels / 2) / (63 * pixels),
                                       (b * 255 + 31 * pixels / 2) / (31 * pixels));
        }
    }
    for (int y = 0; y < rows; ++y)
        for (int x = 0; x < columns; ++x)
            dark[y * columns + x] = blur_line(grid + y * columns, x, columns, 1);
    for (int y = 0; y < rows; ++y)
        for (int x = 0; x < columns; ++x)
            grid[y * columns + x] = blur_line(dark + x, y, rows, columns);

    for (unsigned i = 0; i < DESK_FROST_CELLS; ++i) {
        uint32_t color = grid[i];
        unsigned luma = (54 * channel(color, 16) + 183 * channel(color, 8) + 19 * channel(color, 0) + 128) / 256;
        // Store the original brightness above RGB in the light grid for palette selection.
        grid[i] = (luma << 24) | tint(color, luma, false);
        dark[i] = tint(color, luma, true);
    }
}

bool desk_frost_is_dark(const uint32_t *grid, desk_rect rect, uint8_t rotation)
{
    if (!grid || !rect.width || !rect.height) return false;
    const unsigned step = DESK_FROST_STEP;
    unsigned columns = (rotation % 2 ? DESK_LCD_HEIGHT : DESK_LCD_WIDTH) / step;
    unsigned rows = DESK_FROST_CELLS / columns;
    unsigned left = rect.x / step, top = rect.y / step;
    unsigned right = (rect.x + rect.width + step - 1) / step;
    unsigned bottom = (rect.y + rect.height + step - 1) / step;
    if (right > columns) right = columns;
    if (bottom > rows) bottom = rows;
    if (left >= right || top >= bottom) return false;

    unsigned sum = 0;
    for (unsigned y = top; y < bottom; ++y)
        for (unsigned x = left; x < right; ++x)
            sum += grid[y * columns + x] >> 24;
    return sum < 130u * (right - left) * (bottom - top);
}

const uint32_t *desk_frost_colors(const uint32_t *grid, bool dark)
{
    return grid && dark ? grid + DESK_FROST_CELLS : grid;
}

void desk_frost_sample_row(uint32_t *pixels, const uint32_t *colors, unsigned columns, unsigned rows,
                          unsigned x, unsigned y, unsigned width)
{
    // Grid samples represent the centers of the 8 px blocks, not their edges.
    enum { SCALE = 2 * DESK_FROST_STEP };
    _Static_assert(SCALE * SCALE == 256, "Packed RGB interpolation uses 8-bit weights");
    const unsigned center = DESK_FROST_STEP - 1;
    unsigned v = 2 * y > center ? 2 * y - center : 0;
    unsigned top = v / SCALE, bottom = top + (top + 1 < rows), fy = v % SCALE;
    const uint32_t *upper = colors + top * columns, *lower = colors + bottom * columns;
    const uint32_t rb_mask = 0x00ff00ff;
    unsigned last_column = columns;
    uint32_t left_rb = 0, right_rb = 0, left_g = 0, right_g = 0;
    for (unsigned i = 0; i < width; ++i, ++x) {
        unsigned u = 2 * x > center ? 2 * x - center : 0;
        unsigned left = u / SCALE, fx = u % SCALE;
        if (left != last_column) {
            unsigned right = left + (left + 1 < columns);
            // Reuse the vertical interpolation for all pixels between these sample centers.
            left_rb = (upper[left] & rb_mask) * (SCALE - fy) + (lower[left] & rb_mask) * fy;
            right_rb = (upper[right] & rb_mask) * (SCALE - fy) + (lower[right] & rb_mask) * fy;
            left_g = channel(upper[left], 8) * (SCALE - fy) + channel(lower[left], 8) * fy;
            right_g = channel(upper[right], 8) * (SCALE - fy) + channel(lower[right], 8) * fy;
            last_column = left;
        }
        // The weights sum to 256, so red and blue fit in separate halves of one word.
        uint32_t rb = left_rb * (SCALE - fx) + right_rb * fx + 0x00800080;
        unsigned g = left_g * (SCALE - fx) + right_g * fx + 128;
        pixels[i] = ((rb >> 8) & rb_mask) | (g & 0x0000ff00);
    }
}
