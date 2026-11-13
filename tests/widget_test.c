#include "widget.h"
#include "frosted.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t hash(const void *bytes, size_t count, uint64_t value)
{
    const uint8_t *p = bytes;
    for (size_t i = 0; i < count; ++i) value = (value ^ p[i]) * UINT64_C(1099511628211);
    return value;
}

static void render(uint16_t id, int w, int h, uint8_t rotation, int64_t now, const uint32_t *frost)
{
    desk_component component = {id, {0, 0, w, h}};
    assert(desk_widget_supported(&component));
    size_t pixels = (size_t)w * h;
    uint16_t *color = calloc(pixels, sizeof(*color));
    uint8_t *alpha = calloc(pixels, 1);
    assert(color && alpha);
    widget_canvas canvas = {.pixels = color, .alpha = alpha, .stride = w, .width = w, .height = h};
    widget_box dirty = desk_widget_paint(&component, &canvas, frost, rotation, now);
    uint64_t sum = hash(color, pixels * 2, UINT64_C(14695981039346656037));
    sum = hash(alpha, pixels, sum);
    printf("%u %dx%d r%u t%lld %d,%d,%d,%d %016llx due=%d\n", id, w, h, rotation,
           (long long)now, dirty.x, dirty.y, dirty.width, dirty.height, (unsigned long long)sum,
           desk_widget_due(id, now + 1));
    free(color); free(alpha);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    FILE *file = fopen(argv[1], "rb"); assert(file);
    assert(fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file); assert(length > 0);
    rewind(file);
    uint8_t *font = malloc((size_t)length); assert(font);
    assert(fread(font, 1, (size_t)length, file) == (size_t)length); fclose(file);
    assert(desk_widget_load_font(font, (size_t)length));
    uint32_t *frost = malloc(DESK_FROST_SAMPLES * sizeof(*frost)); assert(frost);
    for (int i = 0; i < DESK_FROST_SAMPLES; ++i) frost[i] = 0xff8090a0u;
    const char *payloads[] = {
        "{\"v\":1,\"data\":{\"status\":\"已连接\",\"snapshot\":{\"steps\":1234,\"stepsGoal\":5000,\"bodyBattery\":63,\"restingHeartRate\":53,\"hrv\":55}}}",
        "{\"v\":1,\"data\":{\"plan\":\"PLUS\",\"tokens\":\"123456\",\"localTokens\":true,\"week\":{\"remaining\":63,\"reset\":\"周五重置\"}}}",
        "{\"v\":1,\"data\":{\"running\":1,\"waiting\":0,\"item\":{\"style\":\"running\",\"source\":\"codex\",\"title\":\"构建项目\",\"body\":\"正在测试\"}}}",
        "{\"v\":1,\"data\":{\"status\":\"connected\",\"devices\":[{\"name\":\"Keyboard\",\"symbol\":\"keyboard\",\"level\":80}]}}",
        "{\"v\":1,\"data\":{\"cpu\":25,\"gpu\":10,\"temperature\":48,\"miucsTenths\":0,\"deskIsleTenths\":50}}"
    };
    const int sizes[][3] = {{0x8001,400,320},{0x8002,400,320},{0x8002,320,320},{0x8002,320,400},
                           {0x8003,920,280},{0x8003,480,160},{0x8004,320,160},{0x8004,200,200},
                           {0x8004,280,200},{0x8005,320,160},{0x8005,400,240}};
    assert(!desk_widget_supported(NULL));
    assert(desk_widget_index(0x8006) == -1);
    desk_component invalid = {0x8001,{0,0,40,40}};
    assert(!desk_widget_supported(&invalid));
    for (unsigned i = 0; i < sizeof(sizes) / sizeof(*sizes); ++i) {
        uint16_t id = sizes[i][0]; const char *payload = payloads[id - 0x8001];
        for (uint8_t rotation = 0; rotation < 4; ++rotation) {
            assert(desk_widget_update(id, (const uint8_t *)payload, strlen(payload), NULL, 0, 1000));
            render(id, sizes[i][1], sizes[i][2], rotation, 1000, frost);
            if (id == 0x8003) {
                const char *expanded = "{\"v\":1,\"expiresInMs\":1000,\"data\":{\"item\":{\"style\":\"success\",\"source\":\"codex\",\"title\":\"已完成\",\"body\":\"测试通过\"}},\"after\":{\"running\":1,\"item\":{\"style\":\"running\",\"source\":\"codex\",\"title\":\"下个任务\"}}}";
                assert(desk_widget_update(id, (const uint8_t *)expanded, strlen(expanded), NULL, 0, 2000));
                int times[] = {2000, 2090, 2180, 2360, 3000, 3180, 3360};
                for (unsigned t = 0; t < sizeof(times) / sizeof(*times); ++t)
                    render(id, sizes[i][1], sizes[i][2], rotation, times[t], frost);
            }
            const char *bad = "{\"v\":2,\"data\":{}}";
            assert(!desk_widget_update(id, (const uint8_t *)bad, strlen(bad), NULL, 0, 4000));
            desk_widget_forget(id);
        }
    }
    free(frost); free(font);
    return 0;
}
