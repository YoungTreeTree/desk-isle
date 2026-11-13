#include "widget_internal.h"

static void tokens(char *out, size_t size, const char *raw)
{
    if (!*raw || strlen(raw) > 19 || strspn(raw, "0123456789") != strlen(raw)) {
        snprintf(out, size, "—");
        return;
    }
    unsigned long long amount = strtoull(raw, NULL, 10), divisor = 1;
    unsigned unit = 0;
    while (amount / divisor >= 1000 && unit < 6) {
        divisor *= 1000;
        ++unit;
    }
    if (!unit) {
        snprintf(out, size, "%llu", amount);
        return;
    }
    unsigned long long tenths = (amount / divisor) * 10 + (amount % divisor * 10 + divisor / 2) / divisor;
    const char suffix[] = " KMBTPE";
    if (tenths % 10) snprintf(out, size, "%llu.%llu%c", tenths / 10, tenths % 10, suffix[unit]);
    else snprintf(out, size, "%llu%c", tenths / 10, suffix[unit]);
}

static void quota(widget_canvas *c, int y, const char *label, const cJSON *quota_data,
                  const desk_frost_style *style)
{
    int w = c->width - 40;
    int remaining = percent(quota_data, "remaining");
    char value[12], reset[64];
    format_percent(value, sizeof(value), remaining);
    text(c, 20, y, 64, 16, label, style->ink);
    const char *time = string(quota_data, "reset");
    if (*time) {
        snprintf(reset, sizeof(reset), "%s 重置", time);
        text(c, 80, y + 3, w - 115, 12, reset, style->muted);
    }
    right(c, 20, y, w, 18, value, remaining < 0 ? style->muted : style->accent);
    bar(c, 20, y + 23, w, remaining, style);
}

void widget_codex_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style)
{
    int w = c->width - 40;
    bool tall = c->height > 320;
    widget_round(c, (widget_box){20, 19, 34, 34}, 8, style->accent, 42);
    text(c, 26, 25, 24, 21, ">_", style->accent);
    text(c, 64, 22, 111, 27, "Codex", style->ink);
    const char *plan = string(data, "plan");
    if (*plan) {
        int width = smaller(w / 2, widget_text_width(c, plan, 13) + 20);
        widget_round(c, (widget_box){c->width - 20 - width, 24, width, 24}, 12, WHITE, style->badge_opacity);
        text(c, c->width - 10 - width, 29, width - 20, 13, plan, style->ink);
    }
    int y = tall ? 82 : 69;
    text(c, 20, y, w, 15, "今日 Token", style->muted);
    if (*string(data, "tokens"))
        right(c, 20, y, w, 15, flag(data, "localTokens") ? "本机统计" : "账号统计", style->muted);
    char value[32];
    tokens(value, sizeof(value), string(data, "tokens"));
    text(c, 20, y + 20, w, c->width >= 400 || tall ? 56 : 48, value, style->ink);
    y = tall ? 191 : 162;
    widget_rect(c, (widget_box){20, y, w, 1}, style->ink, 47);
    text(c, 20, y + 13, w, 15, "订阅剩余额度", style->muted);
    if (flag(data, "staleQuotas")) right(c, 20, y + 13, w, 13, "上次同步", style->muted);
    quota(c, y + 39, "每周", field(data, "week"), style);
    quota(c, y + (tall ? 94 : 82), "5 小时", field(data, "fiveHours"), style);
}
