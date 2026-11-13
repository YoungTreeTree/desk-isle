#include "widget_paint.h"
#include "frosted.h"
#include <stdlib.h>
#include <string.h>

enum {
    FONT_EM = 32,
    FONT_HEIGHT = 38,
    FONT_TOP_PADDING = 3,
    GLYPH_WIDTH = FONT_EM / 2,
    GLYPH_HEIGHT = FONT_HEIGHT / 2,
    GLYPH_BYTES = 3 + GLYPH_WIDTH * GLYPH_HEIGHT / 4,
    ASCII_GLYPH_BYTES = FONT_EM * FONT_HEIGHT / 2,
    ASCII_COUNT = 95,
    EXACT_GLYPH_BYTES = 13,
};
static const uint8_t *glyphs;
static const uint8_t *ascii;
static unsigned glyph_count;
static widget_font fixed_font;

static int min_int(int a, int b) { return a < b ? a : b; }
static int max_int(int a, int b) { return a > b ? a : b; }

static unsigned read_u16(const uint8_t *p)
{
    return p[0] | (unsigned)p[1] << 8;
}

static uint32_t read_u32(const uint8_t *p)
{
    return read_u16(p) | (uint32_t)read_u16(p + 2) << 16;
}

bool widget_font_open(widget_font *font, const uint8_t *data, size_t size)
{
    if (size < 2) return false;
    unsigned count = read_u16(data);
    size_t directory = 2u + count * EXACT_GLYPH_BYTES;
    if (directory > size) return false;
    size_t used = 0, mask_bytes = size - directory;
    uint32_t previous = 0;
    for (unsigned i = 0; i < count; ++i) {
        const uint8_t *record = data + 2 + i * EXACT_GLYPH_BYTES;
        uint32_t key = read_u32(record), code = key & 0x1fffff;
        unsigned advance = record[8], width = record[11], height = record[12];
        int left = (int8_t)record[9], top = (int8_t)record[10];
        size_t bytes = (width * height + 1u) / 2u;
        if (key <= previous || key >> 21 < 8 || key >> 21 > 64 ||
            code < 32 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ||
            !advance || advance > 96 || left < 0 || left + width > advance ||
            height > 96 || top < -96 || top + (int)height > 96 ||
            read_u32(record + 4) != used || bytes > mask_bytes - used) return false;
        used += bytes;
        previous = key;
    }
    if (used != mask_bytes) return false;
    *font = (widget_font){data + 2, data + directory, count};
    return true;
}

bool desk_widget_load_font(const uint8_t *data, size_t size)
{
    if (size < 2) return false;
    unsigned count = read_u16(data);
    size_t legacy = 2u + count * GLYPH_BYTES + ASCII_COUNT * ASCII_GLYPH_BYTES;
    if (!count || legacy > size || !widget_font_open(&fixed_font, data + legacy, size - legacy)) return false;
    glyphs = data + 2;
    glyph_count = count;
    ascii = glyphs + count * GLYPH_BYTES;
    return true;
}

static uint16_t mix(uint16_t foreground, uint16_t background, unsigned alpha)
{
    unsigned inverse = 255 - alpha;
    unsigned r = ((foreground >> 11) * alpha + (background >> 11) * inverse + 127) / 255;
    unsigned g = (((foreground >> 5) & 63) * alpha + ((background >> 5) & 63) * inverse + 127) / 255;
    unsigned b = ((foreground & 31) * alpha + (background & 31) * inverse + 127) / 255;
    return (r << 11) | (g << 5) | b;
}

static inline void put(widget_canvas *c, size_t at, uint16_t color, unsigned alpha)
{
    if (alpha == 255) {
        c->pixels[at] = color;
        c->alpha[at] = 255;
        return;
    }
    if (!alpha) return;
    c->pixels[at] = mix(color, c->alpha[at] ? c->pixels[at] : 0, alpha);
    c->alpha[at] = alpha + (c->alpha[at] * (255 - alpha) + 127) / 255;
}

static inline void span(widget_canvas *c, int x, int y, int end, uint16_t color, uint8_t opacity, bool replace)
{
    if (y < c->clip.y || y >= c->clip.y + c->clip.height) return;
    x = max_int(x, c->clip.x);
    end = min_int(end, c->clip.x + c->clip.width);
    if (end <= x) return;
    size_t offset = (size_t)y * c->stride + x;
    if (replace) {
        for (int i = 0; i < end - x; ++i) c->pixels[offset + i] = color;
        memset(c->alpha + offset, opacity, end - x);
    } else {
        for (int i = 0; i < end - x; ++i) put(c, offset + i, color, opacity);
    }
}

void widget_rect(widget_canvas *c, widget_box box, uint16_t color, uint8_t opacity)
{
    for (int y = max_int(box.y, c->clip.y); y < min_int(box.y + box.height, c->clip.y + c->clip.height); ++y)
        span(c, box.x, y, box.x + box.width, color, opacity, false);
}

static int round_inset(int y, int height, int radius)
{
    int dy = max_int(radius - y - 1, y - (height - radius));
    if (dy < 1) return 0;
    int dx = radius;
    while (dx * dx + dy * dy > radius * radius) --dx;
    return radius - dx;
}

static inline void round_shape(widget_canvas *c, widget_box box, int radius, uint16_t color, uint8_t opacity, bool replace)
{
    radius = min_int(radius, min_int(box.width, box.height) / 2);
    for (int y = max_int(box.y, c->clip.y); y < min_int(box.y + box.height, c->clip.y + c->clip.height); ++y) {
        int inset = round_inset(y - box.y, box.height, radius);
        span(c, box.x + inset, y, box.x + box.width - inset, color, opacity, replace);
    }
}

void widget_round(widget_canvas *c, widget_box box, int radius, uint16_t color, uint8_t opacity)
{
    round_shape(c, box, radius, color, opacity, false);
}

void widget_round_replace(widget_canvas *c, widget_box box, int radius, uint16_t color, uint8_t opacity)
{
    round_shape(c, box, radius, mix(color, 0, opacity), opacity, true);
}

void widget_line(widget_canvas *c, int x, int y, int to_x, int to_y, int width, uint16_t color, uint8_t opacity)
{
    int dx = abs(to_x - x), dy = -abs(to_y - y);
    int sx = x < to_x ? 1 : -1, sy = y < to_y ? 1 : -1;
    int error = dx + dy;
    for (;;) {
        widget_rect(c, (widget_box){x - width / 2, y - width / 2, width, width}, color, opacity);
        if (x == to_x && y == to_y) return;
        int step = error * 2;
        if (step >= dy) { error += dy; x += sx; }
        if (step <= dx) { error += dx; y += sy; }
    }
}

static uint32_t next_character(const char **cursor)
{
    const uint8_t *p = (const uint8_t *)*cursor;
    unsigned first = *p++;
    *cursor = (const char *)p;
    if (first < 128) return first >= 32 ? first : ' ';
    int length = first >= 0xf0 ? 3 : first >= 0xe0 ? 2 : first >= 0xc2 ? 1 : 0;
    if (!length || first >= 0xf5) return '?';
    uint32_t code = first & (0x7f >> (length + 1));
    for (int i = 0; i < length; ++i) {
        if ((p[i] & 0xc0) != 0x80) return '?';
        code = (code << 6) | (p[i] & 63);
    }
    *cursor = (const char *)(p + length);
    return code;
}

static const uint8_t *find_glyph(uint32_t code)
{
    unsigned low = 0, high = glyph_count;
    while (low < high) {
        unsigned mid = (low + high) / 2;
        const uint8_t *glyph = glyphs + mid * GLYPH_BYTES;
        unsigned value = read_u16(glyph);
        if (value == code) return glyph;
        if (value < code) low = mid + 1;
        else high = mid;
    }
    return NULL;
}

static int advance(const uint8_t *glyph, int size)
{
    if (!glyph) glyph = find_glyph('?');
    return max_int(1, ((glyph ? glyph[2] : 64) * size + 64) / 128);
}

typedef struct {
    const uint8_t *record, *mask;
} exact_glyph;

static exact_glyph exact_at(const widget_font *font, uint32_t key)
{
    unsigned low = 0, high = font->count;
    while (low < high) {
        unsigned mid = (low + high) / 2;
        const uint8_t *record = font->records + mid * EXACT_GLYPH_BYTES;
        uint32_t value = read_u32(record);
        if (value == key) return (exact_glyph){record, font->masks + read_u32(record + 4)};
        if (value < key) low = mid + 1;
        else high = mid;
    }
    return (exact_glyph){0};
}

static exact_glyph exact_for(const widget_canvas *c, uint32_t code, int size)
{
    uint32_t key = (uint32_t)size << 21 | code;
    exact_glyph glyph = exact_at(&fixed_font, key);
    if (!glyph.record && c && c->font) glyph = exact_at(c->font, key);
    return glyph;
}

static int text_advance(const widget_canvas *c, uint32_t code, int size)
{
    exact_glyph exact = exact_for(c, code, size);
    if (exact.record) return exact.record[8];
    const uint8_t *legacy = find_glyph(code);
    if (!legacy) {
        exact = exact_for(c, '?', size);
        if (exact.record) return exact.record[8];
    }
    return advance(legacy, size);
}

int widget_text_width(const widget_canvas *c, const char *text, int size)
{
    int width = 0;
    while (*text) width += text_advance(c, next_character(&text), size);
    return width;
}

static unsigned coverage(const uint8_t *bits, int width, int x, int y)
{
    int index = y * width + x;
    return width == FONT_EM ? ((bits[index / 2] >> (index % 2 * 4)) & 15) * 17 :
                              ((bits[index / 4] >> (index % 4 * 2)) & 3) * 85;
}

static unsigned scaled_coverage(const uint8_t *bits, int width, int height,
                                int scaled_width, int size, int x, int y)
{
    if (size == width && scaled_width == width) return coverage(bits, width, x, y);
    if (size < width) {
        // Average the source area covered by this pixel so thin strokes survive reduction.
        int left = x * width, right = left + width;
        int top = y * width, bottom = min_int(top + width, height * size);
        unsigned sum = 0;
        for (int row = top / size; row * size < bottom; ++row) {
            int dy = min_int(bottom, (row + 1) * size) - max_int(top, row * size);
            for (int col = left / scaled_width; col * scaled_width < right; ++col) {
                int dx = min_int(right, (col + 1) * scaled_width) - max_int(left, col * scaled_width);
                sum += coverage(bits, width, col, row) * dx * dy;
            }
        }
        return (sum + width * width / 2) / (width * width);
    }
    int sx = min_int((width - 1) * 256, max_int(0, (x * 256 + 128) * width / scaled_width - 128));
    int sy = min_int((height - 1) * 256, max_int(0, (y * 256 + 128) * width / size - 128));
    int x0 = sx / 256, x1 = min_int(width - 1, x0 + 1), fx = sx % 256;
    int y0 = sy / 256, y1 = min_int(height - 1, y0 + 1), fy = sy % 256;
    unsigned a = coverage(bits, width, x0, y0) * (256 - fx) + coverage(bits, width, x1, y0) * fx;
    unsigned b = coverage(bits, width, x0, y1) * (256 - fx) + coverage(bits, width, x1, y1) * fx;
    return (a * (256 - fy) + b * fy + 32768) >> 16;
}

static void draw_exact(widget_canvas *c, exact_glyph glyph, int x, int y, int size, uint16_t color, uint8_t opacity)
{
    int width = glyph.record[11], height = glyph.record[12];
    x += (int8_t)glyph.record[9];
    y += (27 * size + FONT_EM / 2) / FONT_EM + (int8_t)glyph.record[10];
    int left = max_int(x, c->clip.x), right = min_int(x + width, c->clip.x + c->clip.width);
    int top = max_int(y, c->clip.y), bottom = min_int(y + height, c->clip.y + c->clip.height);
    for (int row = top; row < bottom; ++row) {
        for (int col = left; col < right; ++col) {
            int index = (row - y) * width + col - x;
            unsigned level = (glyph.mask[index / 2] >> (index % 2 * 4)) & 15;
            put(c, (size_t)row * c->stride + col, color, (level * opacity + 7) / 15);
        }
    }
}

static void character(widget_canvas *c, int x, int y, int size, uint32_t code, uint16_t color, uint8_t opacity)
{
    if (!c || !c->pixels || !opacity || code == ' ') return;
    exact_glyph exact = exact_for(c, code, size);
    const uint8_t *glyph = NULL;
    if (!exact.record) glyph = find_glyph(code);
    if (!exact.record && !glyph) {
        code = '?';
        exact = exact_for(c, code, size);
        if (!exact.record) glyph = find_glyph(code);
    }
    if (exact.record) {
        draw_exact(c, exact, x, y, size, color, opacity);
        return;
    }
    if (!glyph) return;
    const bool high = code >= 32 && code <= 126 && size > 17;
    const uint8_t *bits = high ? ascii + (code - 32) * ASCII_GLYPH_BYTES : glyph + 3;
    const int width = high ? FONT_EM : GLYPH_WIDTH, height = high ? FONT_HEIGHT : GLYPH_HEIGHT;
    const int amount = advance(glyph, size), scaled_width = max_int(size, amount);
    // The extra rows keep accents and descenders while retaining the card's baseline.
    const int glyph_top = y - (FONT_TOP_PADDING * size + FONT_EM / 2) / FONT_EM;
    const int scaled_height = (height * size + width - 1) / width;
    int left = max_int(x, c->clip.x), right = min_int(x + amount, c->clip.x + c->clip.width);
    int top = max_int(glyph_top, c->clip.y);
    int bottom = min_int(glyph_top + scaled_height, c->clip.y + c->clip.height);
    for (int row = top; row < bottom; ++row) {
        for (int col = left; col < right; ++col) {
            unsigned alpha = scaled_coverage(bits, width, height, scaled_width, size, col - x, row - glyph_top);
            put(c, (size_t)row * c->stride + col, color, (alpha * opacity + 127) / 255);
        }
    }
}

int widget_text(widget_canvas *c, int x, int y, int width, int size, int max_lines,
                const char *text, uint16_t color, uint8_t opacity)
{
    if (width <= 0 || size <= 0) return 0;
    int line = 0;
    int step = size + 3;
    int ellipsis = text_advance(c, 0x2026, size);
    while (*text && line < max_lines) {
        while (*text == ' ') ++text;
        if (!*text) break;
        const char *end = text;
        const char *space = NULL;
        int used = 0;
        while (*end) {
            const char *next = end;
            uint32_t code = next_character(&next);
            int amount = text_advance(c, code, size);
            if (used + amount > width) break;
            if (code == ' ') space = end;
            used += amount;
            end = next;
        }
        bool cut = *end && line + 1 == max_lines;
        if (*end && !cut && space && space > text) end = space;
        int offset = 0;
        const char *cursor = text;
        while (cursor < end) {
            uint32_t code = next_character(&cursor);
            int amount = text_advance(c, code, size);
            if (cut && offset + amount + ellipsis > width) break;
            character(c, x + offset, y + line * step, size, code, color, opacity);
            offset += amount;
        }
        if (cut && offset + ellipsis <= width) character(c, x + offset, y + line * step, size, 0x2026, color, opacity);
        if (end == text) next_character(&end);
        text = end;
        ++line;
    }
    return line;
}

void widget_text_right(widget_canvas *c, int x, int y, int width, int size,
                       const char *text, uint16_t color, uint8_t opacity)
{
    int padding = max_int(0, width - widget_text_width(c, text, size));
    widget_text(c, x + padding, y, width - padding, size, 1, text, color, opacity);
}

static unsigned corner_coverage(int x, int y, int width, int height, int radius)
{
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    int inset_x = min_int(x, width - 1 - x), inset_y = min_int(y, height - 1 - y);
    if (inset_x >= radius || inset_y >= radius) return 255;
    // Four samples soften the rounded edge without changing the interior.
    int dx = (radius - inset_x) * 4 - 3, dy = (radius - inset_y) * 4 - 3;
    int rr = 16 * radius * radius;
    unsigned hits = 0;
    for (int sy = dy; sy <= dy + 2; sy += 2)
        for (int sx = dx; sx <= dx + 2; sx += 2)
            hits += sx * sx + sy * sy <= rr;
    return (hits * 255 + 2) / 4;
}

typedef struct {
    uint8_t keep, highlight, rim;
} frost_shading;

static unsigned interpolate(unsigned first, unsigned last, unsigned at, unsigned length)
{
    return (first * (length - at) + last * at + length / 2) / length;
}

static void frost_shading_table(frost_shading *table, const desk_frost_style *style)
{
    for (unsigned i = 0; i < 256; ++i) {
        unsigned highlight = 0, shadow = 0;
        if (i <= DESK_FROST_HIGHLIGHT_MID)
            highlight = interpolate(style->highlight, DESK_FROST_HIGHLIGHT_MID_OPACITY,
                                    i, DESK_FROST_HIGHLIGHT_MID);
        else if (i <= DESK_FROST_HIGHLIGHT_END)
            highlight = interpolate(DESK_FROST_HIGHLIGHT_MID_OPACITY, 0, i - DESK_FROST_HIGHLIGHT_MID,
                                    DESK_FROST_HIGHLIGHT_END - DESK_FROST_HIGHLIGHT_MID);
        else
            shadow = interpolate(0, style->shadow, i - DESK_FROST_HIGHLIGHT_END, 255 - DESK_FROST_HIGHLIGHT_END);
        unsigned rim = i <= 128 ? interpolate(style->rim_top, style->rim_middle, i, 128) :
                                  interpolate(style->rim_middle, style->rim_bottom, i - 128, 127);
        table[i] = (frost_shading){255 - highlight - shadow, highlight, rim};
    }
}

static inline uint32_t shade_rgb(uint32_t color, unsigned keep, unsigned highlight)
{
    unsigned lift = 255 * highlight + 127;
    unsigned r = (((color >> 16) & 255) * keep + lift) / 255;
    unsigned g = (((color >> 8) & 255) * keep + lift) / 255;
    unsigned b = ((color & 255) * keep + lift) / 255;
    return r << 16 | g << 8 | b;
}

static inline uint16_t dither_rgb565(uint32_t color, unsigned x, unsigned y)
{
    // A screen-aligned Bayer matrix preserves smooth gradients on the 16-bit panel.
    static const uint8_t order[4][4] = {{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};
    unsigned bias = order[y & 3][x & 3] * 16 + 8;
    unsigned r = (((color >> 16) & 255) * 31 + bias) / 255;
    unsigned g = (((color >> 8) & 255) * 63 + bias) / 255;
    unsigned b = ((color & 255) * 31 + bias) / 255;
    return (uint16_t)(r << 11 | g << 5 | b);
}

void widget_frost(widget_canvas *c, desk_rect rect, const uint32_t *grid, uint8_t rotation, bool dark)
{
    unsigned columns = (rotation % 2 ? DESK_LCD_HEIGHT : DESK_LCD_WIDTH) / DESK_FROST_STEP;
    unsigned rows = DESK_FROST_CELLS / columns;
    const uint32_t *colors = desk_frost_colors(grid, dark);
    const uint32_t fallback = DESK_FROST_FALLBACK * 0x010101u;
    frost_shading lighting[256];
    frost_shading_table(lighting, desk_frost_style_for(dark));
    // Step along the same diagonal as the preview gradient using 8 fractional bits.
    unsigned dx = c->width - 1, dy = c->height - 1;
    unsigned diagonal = dx * dx + dy * dy;
    unsigned step_x = dx * 255 * 256 / (diagonal ? diagonal : 1);
    unsigned step_y = dy * 255 * 256 / (diagonal ? diagonal : 1);
    // The supported frosted cards are at most 400 pixels wide.
    uint32_t samples[c->width];
    for (int y = 0; y < c->height; ++y) {
        unsigned phase = y * step_y, screen_y = rect.y + y;
        bool curved_row = y < DESK_FROST_RADIUS || y >= c->height - DESK_FROST_RADIUS;
        if (colors) desk_frost_sample_row(samples, colors, columns, rows, rect.x, screen_y, c->width);
        for (int x = 0; x < c->width; ++x, phase += step_x) {
            bool curved = curved_row && (x < DESK_FROST_RADIUS || x >= c->width - DESK_FROST_RADIUS);
            unsigned coverage = curved ? corner_coverage(x, y, c->width, c->height, DESK_FROST_RADIUS) : 255;
            if (!coverage) continue;
            unsigned screen_x = rect.x + x;
            uint32_t color = colors ? samples[x] : fallback;
            frost_shading shade = lighting[phase >> 8];
            color = shade_rgb(color, shade.keep, shade.highlight);
            if (curved || y == 0 || y == c->height - 1 || x == 0 || x == c->width - 1) {
                unsigned inside = corner_coverage(x - 1, y - 1, c->width - 2, c->height - 2, DESK_FROST_RADIUS - 1);
                if (inside < coverage) {
                    unsigned rim = shade.rim * (coverage - inside) / coverage;
                    color = shade_rgb(color, 255 - rim, rim);
                }
            }
            put(c, (size_t)y * c->stride + x, dither_rgb565(color, screen_x, screen_y), coverage);
        }
    }
}
