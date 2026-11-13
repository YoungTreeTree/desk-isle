#include "widget_internal.h"

static void device_icon(widget_canvas *c, int x, int y, const char *symbol, uint16_t muted)
{
    if (strcmp(symbol, "headphones") == 0) {
        widget_line(c, x, y + 14, x, y + 7, 2, muted, 255);
        widget_line(c, x, y + 7, x + 4, y + 2, 2, muted, 255);
        widget_line(c, x + 4, y + 2, x + 12, y + 2, 2, muted, 255);
        widget_line(c, x + 12, y + 2, x + 16, y + 7, 2, muted, 255);
        widget_line(c, x + 16, y + 7, x + 16, y + 14, 2, muted, 255);
    } else {
        bool laptop = strcmp(symbol, "laptopcomputer") == 0;
        widget_round(c, (widget_box){x, y + 2, 17, laptop ? 12 : 15}, 3, muted, 255);
        widget_round(c, (widget_box){x + 2, y + 4, 13, laptop ? 8 : 11}, 2, WHITE, 178);
        if (laptop) widget_rect(c, (widget_box){x - 2, y + 15, 21, 2}, muted, 255);
    }
}

static void battery_row(widget_canvas *c, int y, const char *name, const char *symbol, int level,
                        const cJSON *details, const desk_frost_style *style)
{
    const int name_x = 40, edge = c->width - 14, value_width = 40;
    const int value_x = edge - value_width;
    device_icon(c, 14, y + 5, symbol, style->muted);
    int left = percent(details, "left"), right_level = percent(details, "right"), box = percent(details, "box");
    bool has_parts = left >= 0 || right_level >= 0 || box >= 0;
    bool compact = c->height == 160;
    int text_y = y + (compact && !has_parts ? 8 : 3);
    widget_text(c, name_x, text_y, value_x - name_x - 4, 14, compact || has_parts ? 1 : 2, name, style->ink, 255);
    char value[12], parts[64] = "", part[20];
    format_percent(value, sizeof(value), level);
    right(c, value_x, text_y + 1, value_width, 14, value, level < 0 ? style->muted : style->accent);
    if (has_parts) {
        if (left >= 0) snprintf(parts, sizeof(parts), "左 %d%%", left);
        if (right_level >= 0) {
            snprintf(part, sizeof(part), "%s右 %d%%", *parts ? " · " : "", right_level);
            strncat(parts, part, sizeof(parts) - strlen(parts) - 1);
        }
        if (box >= 0) {
            snprintf(part, sizeof(part), "%s盒 %d%%", *parts ? " · " : "", box);
            strncat(parts, part, sizeof(parts) - strlen(parts) - 1);
        }
        text(c, name_x, y + (compact ? 20 : 24), edge - name_x, 11, parts, style->muted);
    }
}

void widget_bluetooth_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style)
{
    const int edge = c->width - 14, count_width = 69;
    bool compact = c->height == 160;
    widget_line(c, 19, 13, 19, 30, 2, style->accent, 255);
    widget_line(c, 19, 13, 25, 18, 2, style->accent, 255);
    widget_line(c, 25, 18, 14, 26, 2, style->accent, 255);
    widget_line(c, 14, 17, 25, 25, 2, style->accent, 255);
    widget_line(c, 25, 25, 19, 30, 2, style->accent, 255);
    text(c, 34, 13, 83, 17, "蓝牙设备", style->ink);
    const cJSON *devices = field(data, "devices");
    int count = integer(data, "count", 0);
    if (count > 0) {
        char label[36];
        snprintf(label, sizeof(label), "%d 已连接", count);
        right(c, edge - count_width, 17, count_width, 12, label, style->muted);
    }
    battery_row(c, compact ? 39 : 47, "本机", "laptopcomputer", percent(data, "computerBattery"), NULL, style);
    widget_rect(c, (widget_box){40, compact ? 73 : 88, edge - 40, 1}, style->muted, 53);
    if (cJSON_GetArraySize(devices) > 0) {
        for (int i = 0; i < smaller(2, cJSON_GetArraySize(devices)); ++i) {
            const cJSON *device = cJSON_GetArrayItem(devices, i);
            if (i) widget_rect(c, (widget_box){40, compact ? 108 : 140, edge - 40, 1}, style->muted, 53);
            battery_row(c, compact ? 74 + i * 35 : 97 + i * 50, string(device, "name"), string(device, "symbol"),
                        percent(device, "level"), device, style);
        }
    } else {
        const char *status = string(data, "status");
        const char *label = strcmp(status, "off") == 0 ? "蓝牙已关闭" :
                            strcmp(status, "unavailable") == 0 ? "设备信息暂不可用" :
                            strcmp(status, "connected") == 0 ? "未连接蓝牙设备" : "正在读取设备";
        center(c, compact ? 106 : 123, 14, label, style->muted);
    }
}
