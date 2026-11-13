#include "widget_internal.h"

static void load_metric(widget_canvas *c, int x, int width, const char *label,
                        const char *number, const char *unit, const desk_frost_style *style, uint16_t color)
{
    bool large = c->height == 240;
    int label_y = large ? 52 : 45, number_y = large ? 72 : 64, size = large ? 30 : 25;
    text(c, x, label_y, width - 1, large ? 13 : 12, label, color);
    text(c, x, number_y, width, size, number, style->ink);
    if (strcmp(number, "—")) {
        int advance = widget_text_width(c, number, size) + 2;
        text(c, x + advance, number_y + size - 13, width - advance, 12, unit, style->muted);
    }
}

static void load_series(widget_canvas *c, const cJSON *values, widget_box box, uint16_t color)
{
    const int count = smaller(cJSON_GetArraySize(values), 32);
    int previous_x = 0, previous_y = 0;
    bool has_previous = false;
    for (int i = 0; i < count; ++i) {
        const cJSON *entry = cJSON_GetArrayItem(values, i);
        int value = cJSON_IsNumber(entry) ? entry->valueint : -1;
        if (value < 0 || value > 100) {
            has_previous = false;
            continue;
        }
        int x = box.x + (count == 1 ? box.width - 1 : (box.width - 1) * i / (count - 1));
        int y = box.y + (box.height - 1) * (100 - value) / 100;
        if (has_previous) widget_line(c, previous_x, previous_y, x, y, 2, color, 255);
        else widget_rect(c, (widget_box){x, y, 2, 2}, color, 255);
        previous_x = x;
        previous_y = y;
        has_previous = true;
    }
}

void widget_mac_load_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style)
{
    const int inset = 16, width = c->width - 2 * inset;
    const int column = width / 4;
    bool large = c->height == 240;
    const char *pressure = string(data, "memoryPressure");
    const char *memory = "内存 —";
    uint16_t memory_color = style->muted;
    if (!strcmp(pressure, "normal")) {
        memory = "内存正常";
        memory_color = style->accent;
    }
    else if (!strcmp(pressure, "warning") || !strcmp(pressure, "critical")) {
        memory = !strcmp(pressure, "critical") ? "内存严重" : "内存紧张";
        memory_color = style->chart_amber;
    }
    widget_line(c, 18, 16, 30, 16, 2, style->accent, 255);
    widget_line(c, 18, 28, 30, 28, 2, style->accent, 255);
    widget_line(c, 16, 18, 16, 26, 2, style->accent, 255);
    widget_line(c, 32, 18, 32, 26, 2, style->accent, 255);
    widget_round(c, (widget_box){22, 30, 5, 2}, 1, style->accent, 255);
    text(c, 40, 12, 120, 18, "Mac 负载", style->ink);
    right(c, inset, 16, width, 12, memory, memory_color);

    char amount[24], label[64];
    format_int(amount, sizeof(amount), percent(data, "cpu"));
    load_metric(c, inset, column, "CPU", amount, "%", style, style->accent);
    format_int(amount, sizeof(amount), percent(data, "gpu"));
    load_metric(c, inset + column, column, "GPU", amount, "%", style, style->chart_amber);
    int temperature = integer(data, "cpuTemperature", -1);
    format_int(amount, sizeof(amount), temperature >= 1 && temperature <= 150 ? temperature : -1);
    load_metric(c, inset + column * 2, column, "CPU 最高温", amount, "°C", style, style->muted);
    int power = integer(data, "systemPowerTenths", -1);
    if (power < 0 || power > 20000) snprintf(amount, sizeof(amount), "—");
    else if (power >= 1000) snprintf(amount, sizeof(amount), "%d", (power + 5) / 10);
    else snprintf(amount, sizeof(amount), "%d.%d", power / 10, power % 10);
    load_metric(c, inset + column * 3, column, "整机功耗", amount, "W", style, style->muted);
    for (int i = 1; i < 4; ++i)
        widget_rect(c, (widget_box){inset + i * column - 8, large ? 55 : 48, 1, large ? 44 : 37}, style->ink, 26);

    int total = integer(data, "memoryTotalMiB", -1), used = integer(data, "memoryUsedMiB", -1);
    if (total <= 0 || total > 4 * 1024 * 1024) total = -1;
    if (used < 0 || total < 0 || used > total) used = -1;
    char used_label[16], total_label[16];
    if (used < 0) snprintf(used_label, sizeof(used_label), "—");
    else snprintf(used_label, sizeof(used_label), "%.1f", used / 1024.0);
    if (total < 0) snprintf(total_label, sizeof(total_label), "—");
    else snprintf(total_label, sizeof(total_label), "%g", total / 1024.0);
    snprintf(label, sizeof(label), "已用 %s / %s GB", used_label, total_label);
    int memory_y = large ? 118 : 103, bar_y = large ? 142 : 124;
    text(c, inset, memory_y, 40, 13, "内存", style->muted);
    right(c, inset + 44, memory_y - (large ? 1 : 0), width - 44, large ? 15 : 13, label, style->ink);
    widget_round(c, (widget_box){inset, bar_y, width, 4}, 2, style->ink, 31);
    int fill = used >= 0 ? (int)((int64_t)width * used / total) : 0;
    if (fill) widget_round(c, (widget_box){inset, bar_y, fill, 4}, 2, memory_color, 255);

    if (large) {
        text(c, inset, 155, width, 11, "最近 1 分钟", style->muted);
        right(c, inset, 155, width - 46, 11, "CPU", style->accent);
        right(c, inset, 155, width, 11, "GPU", style->chart_amber);
        widget_box graph = {inset, 174, width, 30};
        widget_rect(c, (widget_box){graph.x, graph.y, graph.width, 1}, style->ink, 26);
        widget_rect(c, (widget_box){graph.x, graph.y + graph.height / 2, graph.width, 1}, style->ink, 26);
        widget_rect(c, (widget_box){graph.x, graph.y + graph.height - 1, graph.width, 1}, style->ink, 26);
        load_series(c, field(data, "gpuHistory"), graph, style->chart_amber);
        load_series(c, field(data, "cpuHistory"), graph, style->accent);
    }
    int y = c->height - 23;
    format_tenths_percent(amount, sizeof(amount), integer(data, "miucsTenths", -1));
    snprintf(label, sizeof(label), "Miucs %s", amount);
    text(c, inset, y, width / 2, 11, label, style->muted);
    format_tenths_percent(amount, sizeof(amount), integer(data, "deskIsleTenths", -1));
    snprintf(label, sizeof(label), "桌屿 %s", amount);
    right(c, inset, y, width, 11, label, style->muted);
}
