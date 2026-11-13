#include "widget_internal.h"

static widget_state widgets[DESK_WIDGET_COUNT];

typedef struct {
    uint16_t id;
    desk_rect sizes[3];
    void (*paint)(widget_canvas *, const cJSON *, const desk_frost_style *);
} widget_definition;

// Wire IDs and accepted legacy dimensions are part of the device compatibility contract.
static const widget_definition definitions[] = {
    {DESK_WIDGET_GARMIN, {{0, 0, 400, 320}}, widget_garmin_paint},
    {DESK_WIDGET_CODEX, {{0, 0, 400, 320}, {0, 0, 320, 320}, {0, 0, 320, 400}}, widget_codex_paint},
    {DESK_WIDGET_NOTICE, {{0, 0, 920, 280}, {0, 0, 480, 160}}, NULL},
    {DESK_WIDGET_BLUETOOTH, {{0, 0, 320, 160}, {0, 0, 200, 200}, {0, 0, 280, 200}}, widget_bluetooth_paint},
    {DESK_WIDGET_MAC_LOAD, {{0, 0, 320, 160}, {0, 0, 400, 240}}, widget_mac_load_paint},
};
_Static_assert(sizeof(definitions) / sizeof(definitions[0]) == DESK_WIDGET_COUNT, "Widget registry size mismatch");

int desk_widget_index(uint16_t id)
{
    for (unsigned i = 0; i < DESK_WIDGET_COUNT; ++i) {
        if (definitions[i].id == id) return (int)i;
    }
    return -1;
}

bool desk_widget_supported(const desk_component *component)
{
    if (!component) return false;
    int index = desk_widget_index(component->id);
    if (index < 0) return false;
    const widget_definition *definition = &definitions[index];
    for (unsigned i = 0; i < 3; ++i) {
        desk_rect size = definition->sizes[i];
        if (size.width && component->rect.width == size.width && component->rect.height == size.height) return true;
    }
    return false;
}

// Bound nesting before entering cJSON's recursive parser on the USB task stack.
static bool bounded_json(const uint8_t *data, size_t size)
{
    unsigned depth = 0;
    bool quoted = false, escaped = false;
    for (size_t i = 0; i < size; ++i) {
        uint8_t byte = data[i];
        if (quoted) {
            if (escaped) escaped = false;
            else if (byte == '\\') escaped = true;
            else if (byte == '"') quoted = false;
        } else if (byte == '"') {
            quoted = true;
        } else if (byte == '{' || byte == '[') {
            if (++depth > 8) return false;
        } else if (byte == '}' || byte == ']') {
            if (!depth) return false;
            --depth;
        }
        if (!byte) return false;
    }
    return !quoted && !depth;
}

static widget_glyph_bank *copy_glyphs(const uint8_t *data, size_t size)
{
    widget_font font;
    if (!widget_font_open(&font, data, size)) return NULL;
#ifdef ESP_PLATFORM
    widget_glyph_bank *bank = heap_caps_malloc(sizeof(*bank) + size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#else
    widget_glyph_bank *bank = malloc(sizeof(*bank) + size);
#endif
    if (!bank) return NULL;
    bank->references = 1;
    bank->font = (widget_font){bank->bytes + (font.records - data), bank->bytes + (font.masks - data), font.count};
    memcpy(bank->bytes, data, size);
    return bank;
}

void widget_release_snapshot(widget_snapshot *snapshot)
{
    cJSON_Delete(snapshot->json);
    if (snapshot->glyphs && --snapshot->glyphs->references == 0) free(snapshot->glyphs);
    *snapshot = (widget_snapshot){0};
}

const widget_font *widget_snapshot_font(const widget_snapshot *snapshot)
{
    return snapshot->glyphs ? &snapshot->glyphs->font : NULL;
}

void widget_set_data(widget_state *state, widget_snapshot data, bool notice, int64_t now)
{
    if (notice && expanded(state->data.json) != expanded(data.json)) {
        widget_release_snapshot(&state->previous);
        state->previous = state->data;
        state->transition = now;
        state->motion_frames = 0;
        state->animating = true;
    } else {
        widget_release_snapshot(&state->data);
    }
    state->data = data;
    state->next_paint = now;
}

bool desk_widget_update(uint16_t id, const uint8_t *data, size_t size,
                        const uint8_t *glyphs, size_t glyphs_size, int64_t now)
{
    int index = desk_widget_index(id);
    if (index < 0 || size < 2 || size > DESK_MAX_WIDGET_DATA || !bounded_json(data, size)) return false;
    const char *end = NULL;
    const char *limit = (const char *)data + size;
    cJSON *root = cJSON_ParseWithLengthOpts((const char *)data, size, &end, false);
    while (root && end < limit && (*end == ' ' || *end == '\r' || *end == '\n' || *end == '\t')) ++end;
    const cJSON *version = field(root, "v");
    const cJSON *ttl = field(root, "expiresInMs");
    const cJSON *after = field(root, "after");
    bool notice = id == DESK_WIDGET_NOTICE;
    bool valid_expiry = !ttl || (notice && cJSON_IsNumber(ttl) && ttl->valuedouble >= 0 &&
                                ttl->valuedouble <= 60000 && (!after || cJSON_IsObject(after)));
    if (!cJSON_IsObject(root) || end != limit || !cJSON_IsNumber(version) || version->valuedouble != 1 ||
        !cJSON_IsObject(field(root, "data")) || !valid_expiry) {
        cJSON_Delete(root);
        return false;
    }
    widget_glyph_bank *bank = glyphs_size ? copy_glyphs(glyphs, glyphs_size) : NULL;
    if (glyphs_size && !bank) {
        cJSON_Delete(root);
        return false;
    }
    widget_state *state = &widgets[index];
    int remaining = ttl ? ttl->valueint : -1;
    cJSON *current = cJSON_DetachItemFromObjectCaseSensitive(root, "data");
    cJSON *fallback = cJSON_DetachItemFromObjectCaseSensitive(root, "after");
    cJSON_Delete(root);
    widget_release_snapshot(&state->after);
    state->expires = 0;
    if (remaining == 0) {
        cJSON_Delete(current);
        current = fallback;
    } else if (remaining > 0) {
        if (fallback && bank) ++bank->references;
        state->after = (widget_snapshot){.json = fallback, .glyphs = fallback ? bank : NULL};
        state->expires = now + remaining;
    } else {
        cJSON_Delete(fallback);
    }
    widget_set_data(state, (widget_snapshot){.json = current, .glyphs = bank}, notice, now);
    return true;
}

void desk_widget_forget(uint16_t id)
{
    int index = desk_widget_index(id);
    if (index < 0) return;
    widget_state *state = &widgets[index];
    widget_release_snapshot(&state->data);
    widget_release_snapshot(&state->previous);
    widget_release_snapshot(&state->after);
    *state = (widget_state){0};
}

bool desk_widget_due(uint16_t id, int64_t now)
{
    int index = desk_widget_index(id);
    if (index < 0) return false;
    const widget_state *state = &widgets[index];
    return state->next_paint <= now || (state->expires && state->expires <= now);
}

widget_box desk_widget_paint(const desk_component *component, widget_canvas *canvas,
                            const uint32_t *frost, uint8_t rotation, int64_t now)
{
    widget_box full = {0, 0, canvas->width, canvas->height};
    canvas->clip = full;
    memset(canvas->alpha, 0, (size_t)canvas->stride * canvas->height);
    int index = desk_widget_index(component->id);
    if (index < 0) return full;
    widget_state *state = &widgets[index];
    if (component->id == DESK_WIDGET_NOTICE) return widget_notice_paint(canvas, state, now);
    canvas->font = widget_snapshot_font(&state->data);
    bool dark = desk_frost_is_dark(frost, component->rect, rotation);
    const desk_frost_style *style = desk_frost_style_for(dark);
    widget_frost(canvas, component->rect, frost, rotation, dark);
    state->next_paint = INT64_MAX;
    if (definitions[index].paint) definitions[index].paint(canvas, state->data.json, style);
    return full;
}
