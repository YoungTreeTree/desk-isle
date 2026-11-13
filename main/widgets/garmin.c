#include "widget_internal.h"

static void heart(widget_canvas *c, int x, int y, uint16_t color)
{
    widget_line(c, x, y + 10, x + 5, y + 10, 2, color, 255);
    widget_line(c, x + 5, y + 10, x + 8, y + 1, 2, color, 255);
    widget_line(c, x + 8, y + 1, x + 12, y + 17, 2, color, 255);
    widget_line(c, x + 12, y + 17, x + 16, y + 10, 2, color, 255);
    widget_line(c, x + 16, y + 10, x + 23, y + 10, 2, color, 255);
}

static void metric(widget_canvas *c, int x, int w, const char *name, const char *value, const char *unit,
                   const desk_frost_style *style)
{
    widget_round(c, (widget_box){x, 132, w, 70}, 9, WHITE, style->tile_opacity);
    text(c, x + 8, 141, w - 16, 13, name, style->muted);
    text(c, x + 8, 158, w - 16, 24, value, style->ink);
    text(c, x + 8, 184, w - 16, 12, unit, style->muted);
}

void widget_garmin_paint(widget_canvas *c, const cJSON *data, const desk_frost_style *style)
{
    int w = c->width - 40;
    heart(c, 20, 22, style->accent);
    text(c, 52, 20, 134, 20, "佳明健康", style->ink);
    right(c, 156, 24, w - 136, 13, *string(data, "status") ? string(data, "status") : "GARMIN CONNECT", style->muted);
    const cJSON *snapshot = field(data, "snapshot");
    if (!cJSON_IsObject(snapshot)) {
        heart(c, c->width / 2 - 12, 122, style->accent);
        const char *error = string(data, "error");
        center(c, 158, 21, *error ? error : "正在读取健康数据", style->muted);
        return;
    }
    char value[32], label[64], unit[24];
    int steps = integer(snapshot, "steps", -1), goal = integer(snapshot, "stepGoal", 0);
    format_steps(value, sizeof(value), steps);
    int text_width = smaller(w / 2, widget_text_width(c, value, 43));
    text(c, 20, 53, text_width + 1, 43, value, style->ink);
    text(c, 29 + text_width, 74, 25, 16, "步", style->muted);
    if (goal > 0) {
        format_steps(value, sizeof(value), goal);
        snprintf(label, sizeof(label), "目标 %s", value);
        right(c, 166, 74, w - 146, 15, label, style->muted);
    }
    bar(c, 20, 111, w, goal > 0 ? (int)((int64_t)smaller(goal, larger(0, steps)) * 100 / goal) : 0, style);
    int seconds = integer(snapshot, "sleepSeconds", -1), score = integer(snapshot, "sleepScore", -1);
    if (seconds < 0) snprintf(value, sizeof(value), "—");
    else snprintf(value, sizeof(value), "%d:%02d", seconds / 3600, seconds / 60 % 60);
    if (score < 0) snprintf(unit, sizeof(unit), "时:分");
    else snprintf(unit, sizeof(unit), "评分 %d", score);
    int tile = (w - 21) / 4;
    metric(c, 20, tile, "睡眠", value, unit, style);
    format_int(value, sizeof(value), integer(snapshot, "bodyBattery", -1));
    metric(c, 20 + (tile + 7), tile, "身体电量", value, "/ 100", style);
    format_int(value, sizeof(value), integer(snapshot, "restingHeartRate", -1));
    metric(c, 20 + 2 * (tile + 7), tile, "静息心率", value, "bpm", style);
    format_int(value, sizeof(value), integer(snapshot, "hrv", -1));
    metric(c, 20 + 3 * (tile + 7), tile, "夜间 HRV", value, "ms", style);
    text(c, 20, 216, w, 16, "近 24 小时压力", style->ink);
    const cJSON *points = field(snapshot, "stress");
    int count = smaller(144, cJSON_GetArraySize(points)), index = 0;
    bool found = false;
    const cJSON *point;
    cJSON_ArrayForEach(point, points) {
        if (index >= count) break;
        int x = 20 + index * w / count;
        int end = 20 + (++index) * w / count;
        if (!cJSON_IsNumber(point) || point->valueint < 0 || point->valueint > 100) continue;
        int height = larger(2, point->valueint * 43 / 100);
        widget_rect(c, (widget_box){x, 285 - height, larger(1, end - x - 1), height},
                    point->valueint < 26 ? style->accent : style->chart_amber, 255);
        found = true;
    }
    if (found) {
        text(c, 20, 291, w, 11, "24 小时前", style->muted);
        right(c, 20, 291, w, 11, "采集时", style->muted);
    } else {
        center(c, 253, 14, "暂无压力记录", style->muted);
    }
}
