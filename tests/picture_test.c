#define _POSIX_C_SOURCE 200112L
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "picture_player.h"

static int64_t clock_now;
static unsigned draws;
static bool fail_alloc, fail_draw;
static void *allocate(size_t size) { void *p = NULL; if (fail_alloc || posix_memalign(&p, 64, size)) return NULL; return p; }
static bool valid_jpeg(const desk_frame_data *f, unsigned w, unsigned h) { return f->jpeg[2] != 0xee && w == 80 && h == 80; }
static bool draw(uint16_t id, const desk_frame_data *f) {
    assert(id >= DESK_PICTURE_FIRST_ID && f->jpeg_length >= 6 && (uintptr_t)f->jpeg % 64 == 0);
    clock_now += 1000;
    if (fail_draw) return false;
    ++draws; return true;
}
static int64_t clock_us(void) { return clock_now; }
static void put32(uint8_t *p, uint32_t value) { for (unsigned i = 0; i < 4; ++i) p[i] = value >> (8 * i); }
static uint8_t *pack(void) {
    uint8_t *p = allocate(192); assert(p); memset(p, 0, 192);
    memcpy(p, "DIGA", 4); p[4] = 1; p[6] = 2; p[8] = p[10] = 80; put32(p + 12, 160);
    put32(p + 20, 64); put32(p + 24, 6);
    put32(p + 32, 80); put32(p + 36, 128); put32(p + 40, 6); put32(p + 44, 52);
    memcpy(p + 64, "\xff\xd8\x01\x00\xff\xd9", 6); memcpy(p + 128, "\xff\xd8\x02\x00\xff\xd9", 6);
    for (unsigned i = 0; i < 26; ++i) { p[134 + i * 2] = i == 25 ? 25 : 255; p[135 + i * 2] = 255; }
    return p;
}
static bool command(unsigned kind, const desk_component *c, const uint8_t *data, size_t length, int64_t now) {
    desk_message message = {.kind = kind, .id = c->id, .data = data, .length = length, .checksum_ok = true};
    return desk_pictures_receive(&message, c, now);
}
static void begin(const desk_component *c, const uint8_t *data, size_t length, int64_t now) {
    uint8_t b[8]; put32(b, (uint32_t)length); put32(b + 4, desk_crc32(data, length));
    assert(command(DESK_PICTURE_BEGIN, c, b, 8, now));
}
static void chunks(const desk_component *c, const uint8_t *data, size_t length, int64_t now) {
    for (size_t offset = 0; offset < length; offset += 40) {
        size_t count = length - offset < 40 ? length - offset : 40;
        uint8_t b[44]; put32(b, (uint32_t)offset); memcpy(b + 4, data + offset, count);
        assert(command(DESK_PICTURE_CHUNK, c, b, count + 4, now));
    }
}
static void install(const desk_component *c, const uint8_t *p, int64_t now) {
    begin(c, p, 192, now); chunks(c, p, 192, now); assert(command(DESK_PICTURE_COMMIT, c, NULL, 0, now));
}
static void validate_pack(void) {
    uint8_t *p = pack(); desk_picture_pack decoded;
    assert(desk_picture_pack_open(&decoded, p, 192));
    assert(decoded.count == 2 && decoded.duration_ms == 160);
    assert(desk_picture_pack_index(&decoded, 0) == 0 && desk_picture_pack_index(&decoded, 79) == 0);
    assert(desk_picture_pack_index(&decoded, 80) == 1 && desk_picture_pack_index(&decoded, 160) == 0);
    for (unsigned size = 0; size < 192; ++size) assert(!desk_picture_pack_open(&decoded, p, size));
    put32(p + 12, 80); assert(!desk_picture_pack_open(&decoded, p, 192)); put32(p + 12, 160);
    const unsigned offsets[] = {0, 4, 6, 8, 10, 16, 20, 24, 32, 36, 40, 44, 64, 134, 184};
    for (unsigned i = 0; i < sizeof(offsets) / sizeof(offsets[0]); ++i) {
        unsigned offset = offsets[i]; uint8_t old = p[offset]; p[offset] ^= 0xff;
        assert(!desk_picture_pack_open(&decoded, p, 192)); p[offset] = old;
    }
    free(p);
}
static void player_lifecycle(void) {
    uint8_t *p = pack();
    desk_layout layout = {.count = 2, .components = {{0x8100, {0, 0, 80, 80}}, {0x8101, {80, 0, 80, 80}}}};
    const desk_component *a = &layout.components[0], *b = &layout.components[1];
    install(a, p, 0); install(b, p, 0); assert(desk_pictures_memory() == 384);
    desk_pictures_presented(); desk_pictures_presented();
    assert(desk_pictures_status(a->id, 0).presented == 1);
    unsigned before = draws;
    // No host messages: the board alone advances both clocks through multiple loops.
    for (unsigned t = 1; t <= 24; ++t) { desk_pictures_tick(t * 80000, true); desk_pictures_presented(); }
    assert(draws == before + 48 && desk_pictures_status(a->id, 1920000).presented == 25);
    const uint8_t pause = 1, resume = 0;
    assert(command(DESK_PICTURE_CONTROL, a, &pause, 1, 1920000));
    before = draws; desk_pictures_tick(2000000, true); assert(draws == before + 1);
    assert(command(DESK_PICTURE_CONTROL, a, &resume, 1, 2000000));
    desk_pictures_tick(2080000, true); assert(draws == before + 3);
    before = draws; desk_pictures_tick(2200000, false); assert(draws == before);

    uint32_t crc = desk_pictures_status(a->id, 2200000).crc;
    // Incomplete upload / bad checksum never replaces the active animation.
    begin(a, p, 192, 2200000);
    assert(!command(DESK_PICTURE_COMMIT, a, NULL, 0, 2200000));
    assert(desk_pictures_memory() == 384 && desk_pictures_status(a->id, 2200000).crc == crc);
    begin(a, p, 192, 2200000); p[66] = 3; chunks(a, p, 192, 2200000);
    assert(!command(DESK_PICTURE_COMMIT, a, NULL, 0, 2200000));
    assert(desk_pictures_memory() == 384); p[66] = 1;
    // Validate every JPEG, not just the first; preserve old pixels on first-frame failure.
    p[130] = 0xee; begin(a, p, 192, 2200000); chunks(a, p, 192, 2200000);
    assert(!command(DESK_PICTURE_COMMIT, a, NULL, 0, 2200000)); p[130] = 2;
    begin(a, p, 192, 2200000); chunks(a, p, 192, 2200000); fail_draw = true;
    assert(!command(DESK_PICTURE_COMMIT, a, NULL, 0, 2200000)); fail_draw = false;
    assert(desk_pictures_status(a->id, 2200000).crc == crc && desk_pictures_memory() == 384);
    // A dropped connection leaves at most one staging buffer, reclaimed after 30 s.
    begin(a, p, 192, 2200000); assert(desk_pictures_memory() == 576);
    desk_pictures_tick(32200000, false); assert(desk_pictures_memory() == 384);
    fail_alloc = true; uint8_t request[8]; put32(request, 192); put32(request + 4, crc);
    assert(!command(DESK_PICTURE_BEGIN, a, request, 8, 33000000)); fail_alloc = false;
    // Rotation and moves keep resources; removal and resizing release only affected IDs.
    layout.rotation = 3; layout.components[0].rect.x = 160; desk_pictures_layout(&layout);
    assert(desk_pictures_memory() == 384);
    layout.components[0].rect.width = layout.components[0].rect.height = 160;
    desk_pictures_layout(&layout); assert(desk_pictures_memory() == 192);
    layout.count = 0; desk_pictures_layout(&layout); assert(desk_pictures_memory() == 0);
    layout.count = 2; layout.components[0].rect.width = layout.components[0].rect.height = 80;
    begin(a, p, 192, 0);
    layout.components[0].rect.width = layout.components[0].rect.height = 160;
    desk_pictures_layout(&layout); assert(desk_pictures_memory() == 0);
    layout.components[0].rect.width = layout.components[0].rect.height = 80;
    for (unsigned i = 0; i < 100; ++i) {
        install(a, p, 0); install(b, p, 0); desk_pictures_forget(a->id); desk_pictures_forget(b->id);
        assert(desk_pictures_memory() == 0);
    }
    // Staging memory is counted in the global cap before allocation.
    put32(request, DESK_MAX_PICTURE_PACK);
    assert(command(DESK_PICTURE_BEGIN, a, request, 8, 0));
    assert(desk_pictures_memory() == DESK_MAX_PICTURE_PACK);
    const uint8_t invalid_chunk[5] = {1, 0, 0, 0, 42};
    assert(!command(DESK_PICTURE_CHUNK, a, invalid_chunk, sizeof(invalid_chunk), 0));
    assert(command(DESK_PICTURE_ABORT, a, NULL, 0, 0)); assert(desk_pictures_memory() == 0);
    free(p);
}
static void cache_budget(void) {
    const unsigned count = 42, table_end = 704;
    const size_t size = table_end + count * DESK_MAX_JPEG;
    uint8_t *p = allocate(size); assert(p); memset(p, 0, size);
    memcpy(p, "DIGA", 4); p[4] = 1; p[6] = count; p[8] = p[10] = 80; put32(p + 12, count * 80);
    for (unsigned i = 0; i < count; ++i) {
        size_t offset = table_end + i * DESK_MAX_JPEG;
        put32(p + 16 + 16 * i, i * 80); put32(p + 20 + 16 * i, (uint32_t)offset);
        put32(p + 24 + 16 * i, DESK_MAX_JPEG); p[offset] = 0xff; p[offset + 1] = 0xd8;
    }
    desk_component a = {0x8100, {0, 0, 80, 80}}, b = {0x8101, {80, 0, 80, 80}};
    uint8_t *chunk = malloc(DESK_MAX_PICTURE_CHUNK + 4); assert(chunk);
    for (unsigned i = 0; i < 2; ++i) {
        const desk_component *c = i ? &b : &a;
        begin(c, p, size, 0);
        for (size_t offset = 0; offset < size; offset += DESK_MAX_PICTURE_CHUNK) {
            size_t n = size - offset < DESK_MAX_PICTURE_CHUNK ? size - offset : DESK_MAX_PICTURE_CHUNK;
            put32(chunk, (uint32_t)offset); memcpy(chunk + 4, p + offset, n);
            assert(command(DESK_PICTURE_CHUNK, c, chunk, n + 4, 0));
        }
        assert(command(DESK_PICTURE_COMMIT, c, NULL, 0, 0));
    }
    assert(desk_pictures_memory() == 2 * size);
    uint8_t request[8]; put32(request, (uint32_t)size); put32(request + 4, 0);
    assert(!command(DESK_PICTURE_BEGIN, &a, request, 8, 0));
    assert(desk_pictures_memory() == 2 * size && desk_pictures_status(a.id, 0).bytes == size);
    desk_pictures_forget(a.id); desk_pictures_forget(b.id);
    assert(desk_pictures_memory() == 0); free(chunk); free(p);
}
int main(int argc, char **argv) {
    desk_pictures_init((desk_picture_hooks){allocate, valid_jpeg, draw, clock_us});
    validate_pack(); player_lifecycle(); cache_budget();
    // Optional cross-language fixture exported by PicturePlaybackTests.
    if (argc == 2) {
        FILE *f = fopen(argv[1], "rb"); assert(f); assert(!fseek(f, 0, SEEK_END)); long size = ftell(f); rewind(f);
        uint8_t *data = malloc((size_t)size); assert(data && fread(data, 1, (size_t)size, f) == (size_t)size); fclose(f);
        desk_picture_pack value; assert(desk_picture_pack_open(&value, data, (size_t)size));
        printf("PASS Swift pack: %u frames, %u ms, %ux%u\n", value.count, value.duration_ms, value.width, value.height);
        free(data);
    }
    desk_pictures_init((desk_picture_hooks){allocate, valid_jpeg, draw, clock_us});
    puts("PASS native GIF validation, autonomous playback, atomic replacement, interruption and reclamation");
}
