#include "widget_internal.h"

typedef struct {
    const char *style, *label;
    uint16_t color;
} notice_style;

static const notice_style *style_for(const cJSON *item)
{
    static const notice_style styles[] = {
        {"info", "提醒", WIDGET_RGB(153, 210, 255)},
        {"running", "运行中", WIDGET_RGB(153, 210, 255)},
        {"approval", "待审批", WIDGET_RGB(255, 199, 102)},
        {"question", "待回复", WIDGET_RGB(199, 189, 255)},
        {"success", "已完成", WIDGET_RGB(145, 237, 183)},
        {"warning", "提醒", WIDGET_RGB(255, 199, 102)},
        {"error", "失败", WIDGET_RGB(255, 155, 160)},
        {"interrupted", "已中断", WIDGET_RGB(189, 199, 212)},
    };
    const char *value = string(item, "style");
    for (unsigned i = 0; i < sizeof(styles) / sizeof(*styles); ++i)
        if (strcmp(value, styles[i].style) == 0) return &styles[i];
    return &styles[0];
}

static void notice_counts(char *text, size_t size, const cJSON *data)
{
    int waiting = integer(data, "waiting", 0), count = integer(data, "running", 0);
    if (waiting > 0 && count > 0) snprintf(text, size, "%d 待处理 · %d 运行中", waiting, count);
    else if (waiting > 0) snprintf(text, size, "%d 待处理", waiting);
    else if (count > 0) snprintf(text, size, "%d 运行中", count);
    else *text = 0;
}

static void compact_title(char *title, size_t size, const cJSON *item)
{
    if (!item) {
        snprintf(title, size, "通知岛");
        return;
    }
    const char *project = string(item, "project");
    snprintf(title, size, "%s · %s", string(item, "source"), *project ? project : string(item, "title"));
}

static const char *compact_body(const cJSON *item)
{
    const char *body = string(item, "body");
    const char *project = string(item, "project");
    if (*body) return body;
    const char *title = string(item, "title");
    return *project && strcmp(title, project) != 0 ? title : "";
}

static widget_box notice_box(const widget_canvas *c, widget_snapshot *snapshot)
{
    if (snapshot->measured_width == c->width && snapshot->measured_height == c->height)
        return snapshot->notice_bounds;
    const cJSON *data = snapshot->json;
    const cJSON *item = field(data, "item");
    widget_canvas metrics = {.font = widget_snapshot_font(snapshot)};
    int width, height;
    if (!expanded(data)) {
        char title[220], counts[80];
        compact_title(title, sizeof(title), item);
        notice_counts(counts, sizeof(counts), data);
        int main = larger(widget_text_width(&metrics, title, item ? 24 : 28),
                          smaller(340, widget_text_width(&metrics, compact_body(item), 17)));
        int meta = *counts ? widget_text_width(&metrics, counts, 17) + 14 : 0;
        width = smaller(c->width - 24, larger(184, 56 + 25 + 14 + main + meta));
        height = 76;
    } else {
        bool wide = c->width >= 800;
        int sessions = wide ? smaller(3, cJSON_GetArraySize(field(data, "others"))) : 0;
        width = c->width - (wide ? 36 : 20);
        int line_width = width - (wide ? 52 : 32) - (sessions ? 240 : 0);
        int titles = widget_text(&metrics, 0, 0, line_width, 24, wide ? 2 : 1, string(item, "title"), 0, 0);
        int lines = widget_text(&metrics, 0, 0, line_width, 17, wide ? 4 : 2, string(item, "body"), 0, 0);
        int content = 34 + titles * 27 + lines * 20;
        int sidebar = sessions ? 35 + sessions * 36 : 0;
        height = smaller(c->height - 20, larger(wide ? 108 : 90, larger(content, sidebar) + (wide ? 36 : 22)));
    }
    snapshot->measured_width = c->width;
    snapshot->measured_height = c->height;
    snapshot->notice_bounds = (widget_box){(c->width - width) / 2, 10, width, height};
    return snapshot->notice_bounds;
}

static void notice_icon(widget_canvas *c, int x, int y, const notice_style *style, uint8_t opacity)
{
    uint16_t color = style->color;
    if (strcmp(style->style, "success") == 0) {
        widget_line(c, x + 3, y + 10, x + 8, y + 15, 3, color, opacity);
        widget_line(c, x + 8, y + 15, x + 16, y + 3, 3, color, opacity);
    } else if (strcmp(style->style, "error") == 0) {
        widget_line(c, x + 4, y + 4, x + 15, y + 15, 3, color, opacity);
        widget_line(c, x + 15, y + 4, x + 4, y + 15, 3, color, opacity);
    } else if (strcmp(style->style, "interrupted") == 0) {
        widget_rect(c, (widget_box){x + 5, y + 4, 3, 12}, color, opacity);
        widget_rect(c, (widget_box){x + 12, y + 4, 3, 12}, color, opacity);
    } else if (strcmp(style->style, "info") == 0) {
        widget_round(c, (widget_box){x + 3, y + 2, 14, 14}, 7, color, opacity);
        widget_round(c, (widget_box){x, y + 12, 20, 5}, 2, color, opacity);
        widget_round(c, (widget_box){x + 8, y + 18, 4, 3}, 1, color, opacity);
    } else {
        widget_round(c, (widget_box){x + 8, y + 2, 4, 11}, 2, color, opacity);
        widget_round(c, (widget_box){x + 8, y + 16, 4, 4}, 2, color, opacity);
    }
}

static void notice_compact(widget_canvas *c, widget_box box, const cJSON *data, int64_t now, uint8_t opacity)
{
    const cJSON *item = field(data, "item");
    const notice_style *style = style_for(item);
    char title[220], counts[80];
    compact_title(title, sizeof(title), item);
    notice_counts(counts, sizeof(counts), data);
    const char *body = compact_body(item);
    int middle = box.y + box.height / 2;
    int icon = box.x + 27, x = icon + 39, right_edge = box.x + box.width - 27;
    int count_width = smaller((right_edge - x) / 2, widget_text_width(c, counts, 17));
    if (running(data)) {
        float wave = (float)(now % 1500) / 1500.f;
        for (int i = 0; i < 5; ++i) {
            int height = 7 + (int)(8.5f * (1.f + sinf((wave - i * .14f) * 6.2831853f)));
            widget_round(c, (widget_box){icon + i * 5, middle - height / 2, 3, height}, 1, style->color, opacity);
        }
    } else {
        notice_icon(c, icon + 2, middle - 10, style, opacity);
    }
    int title_size = item ? 24 : 28;
    int available = right_edge - x - (count_width > 0 ? count_width + 14 : 0);
    widget_text(c, x, middle - (*body ? 22 : title_size / 2), available, title_size, 1, title, WHITE, opacity);
    if (*body) widget_text(c, x, middle + 5, available, 17, 1, body, WHITE, opacity * 224 / 255);
    if (*counts) widget_text_right(c, right_edge - count_width, middle - 8, count_width, 17, counts, style->color, opacity);
}

static void notice_expanded(widget_canvas *c, widget_box box, const cJSON *data, uint8_t opacity)
{
    const cJSON *item = field(data, "item");
    const notice_style *style = style_for(item);
    bool wide = c->width >= 800;
    const cJSON *others = field(data, "others");
    int count = wide && box.width > 610 ? smaller(3, cJSON_GetArraySize(others)) : 0;
    int x = box.x + (wide ? 26 : 16), y = box.y + (wide ? 18 : 11);
    int width = box.width - (wide ? 52 : 32) - (count ? 240 : 0);
    char title[270], meta[96];
    const char *project = string(item, "project");
    if (*project && strcmp(project, string(item, "title")) != 0)
        snprintf(title, sizeof(title), "%s · %s · %s", string(item, "source"), style->label, project);
    else snprintf(title, sizeof(title), "%s · %s", string(item, "source"), style->label);
    int elapsed = integer(item, "elapsedSeconds", -1);
    if (elapsed >= 60) snprintf(meta, sizeof(meta), "用时 %d 分 %d 秒", elapsed / 60, elapsed % 60);
    else if (elapsed >= 0) snprintf(meta, sizeof(meta), "用时 %d 秒", elapsed);
    else if (!count) notice_counts(meta, sizeof(meta), data);
    else *meta = 0;
    int meta_width = smaller(width / 3, widget_text_width(c, meta, 14));
    widget_round(c, (widget_box){x, y, 30, 30}, 8, style->color, opacity * 36 / 255);
    notice_icon(c, x + 5, y + 4, style, opacity);
    widget_text(c, x + 39, y + 6, width - 42 - meta_width, 15, 1, title, style->color, opacity);
    if (*meta) widget_text_right(c, x + width - meta_width, y + 7, meta_width, 14, meta, WHITE, opacity * 215 / 255);
    int title_lines = widget_text(c, x, y + 37, width, 24, wide ? 2 : 1, string(item, "title"), WHITE, opacity);
    widget_text(c, x, y + 38 + title_lines * 27, width, 17, wide ? 4 : 2, string(item, "body"),
                WHITE, opacity * 235 / 255);
    if (count) {
        x += width + 20;
        widget_round(c, (widget_box){x, y, 220, 35 + 36 * count}, 13, WHITE, opacity * 19 / 255);
        widget_text(c, x + 12, y + 10, 192, 13, 1, "其他会话", WHITE, opacity * 215 / 255);
        for (int i = 0; i < count; ++i) {
            const cJSON *session = cJSON_GetArrayItem(others, i);
            const notice_style *entry = style_for(session);
            int line = y + 31 + i * 36;
            widget_round(c, (widget_box){x + 12, line + 5, 6, 6}, 3, entry->color, opacity);
            widget_text(c, x + 24, line, 184, 15, 1, string(session, "title"), WHITE, opacity);
            const char *label = string(session, "project");
            snprintf(title, sizeof(title), "%s · %s", *label ? label : string(session, "source"), entry->label);
            widget_text(c, x + 24, line + 17, 184, 13, 1, title, WHITE, opacity * 215 / 255);
        }
    }
}

widget_box widget_notice_paint(widget_canvas *c, widget_state *state, int64_t now)
{
    if (state->expires && now >= state->expires) {
        widget_snapshot after = state->after;
        state->after = (widget_snapshot){0};
        state->expires = 0;
        widget_set_data(state, after, true, now);
    }
    const widget_snapshot *content = &state->data;
    widget_box box = notice_box(c, &state->data);
    widget_box text_box = box;
    if (state->animating && now - state->transition >= TRANSITION_MS) {
        widget_release_snapshot(&state->previous);
        state->animating = false;
#ifdef ESP_PLATFORM
        ESP_LOGI("DESK_WIDGET", "NOTICE_MOTION frames=%u elapsed_ms=%u",
                 state->motion_frames, (unsigned)(now - state->transition));
#endif
    }
    if (state->animating) {
        ++state->motion_frames;
        float progress = (float)(now - state->transition) / TRANSITION_MS;
        float eased = progress * progress * (3.f - 2.f * progress);
        widget_box from = notice_box(c, &state->previous);
        // The compact text fits throughout the motion. Expand to the final
        // text layout only once the backdrop has reached its destination.
        if (expanded(state->data.json)) {
            content = &state->previous;
            text_box = from;
        }
        box.width = from.width + (int)((box.width - from.width) * eased);
        box.height = from.height + (int)((box.height - from.height) * eased);
        box.x = (c->width - box.width) / 2;
    }
    // The display task paces the transition to the LCD's available buffers.
    state->next_paint = state->animating ? now :
                        running(state->data.json) ? now + WAVE_FRAME_MS : INT64_MAX;
    widget_round_replace(c, box, smaller(29, box.height / 2), WIDGET_RGB(15, 23, 38), 166);
    c->clip = box;
    c->font = widget_snapshot_font(content);
    if (expanded(content->json)) notice_expanded(c, text_box, content->json, 255);
    else notice_compact(c, text_box, content->json, now, 255);
    return box;
}
