#include "picture_player.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    desk_picture_pack pack;
    desk_picture_status status;
    int64_t started, paused_at;
    unsigned index;
    bool pending;
} picture;

static picture players[DESK_MAX_COMPONENTS];
static desk_picture_hooks hooks;
static struct { uint8_t *bytes; size_t size, used; uint32_t crc; uint16_t id, width, height; int64_t at; } upload;
static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void abort_upload(void) { free(upload.bytes); memset(&upload, 0, sizeof(upload)); }
static picture *find(uint16_t id) {
    for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) if (players[i].status.id == id) return &players[i];
    return NULL;
}
void desk_pictures_init(desk_picture_hooks next) {
    abort_upload();
    for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) free((void *)players[i].pack.data);
    memset(players, 0, sizeof(players)); hooks = next;
}
size_t desk_pictures_memory(void) {
    size_t bytes = upload.size;
    for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) bytes += players[i].pack.size;
    return bytes;
}
void desk_pictures_forget(uint16_t id) {
    picture *p = find(id);
    if (p) { free((void *)p->pack.data); memset(p, 0, sizeof(*p)); }
    if (upload.id == id) abort_upload();
}
void desk_pictures_layout(const desk_layout *layout) {
    for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) {
        picture *p = &players[i];
        if (!p->status.id) continue;
        const desk_component *c = desk_layout_component(layout, p->status.id);
        if (!c || c->rect.width != p->pack.width || c->rect.height != p->pack.height) desk_pictures_forget(p->status.id);
    }
    if (upload.id) {
        const desk_component *c = desk_layout_component(layout, upload.id);
        if (!c || c->rect.width != upload.width || c->rect.height != upload.height) abort_upload();
    }
}
static bool draw(picture *p, unsigned index) {
    desk_frame_data frame = desk_picture_pack_frame(&p->pack, index);
    int64_t start = hooks.clock_us();
    if (!hooks.draw(p->status.id, &frame)) return false;
    uint64_t elapsed = (uint64_t)(hooks.clock_us() - start);
    p->status.decode_us += elapsed;
    if (elapsed > p->status.max_decode_us) p->status.max_decode_us = elapsed;
    ++p->status.decoded; p->index = index; p->pending = true;
    return true;
}
bool desk_pictures_receive(const desk_message *m, const desk_component *c, int64_t now) {
    if (!m || !m->checksum_ok || m->id < DESK_PICTURE_FIRST_ID || m->id > DESK_PICTURE_LAST_ID) return false;
    if (m->kind == DESK_PICTURE_ABORT) {
        if (upload.id == m->id) abort_upload();
        return m->length == 0;
    }
    if (!c || c->id != m->id) return false;
    if (m->kind == DESK_PICTURE_BEGIN) {
        if (m->length != 8) return false;
        size_t size = u32(m->data);
        if (size < 64 || size > DESK_MAX_PICTURE_PACK || size % 64) return false;
        abort_upload();
        if (size > DESK_PICTURE_CACHE_BUDGET - desk_pictures_memory()) return false;
        upload.bytes = hooks.allocate(size);
        if (!upload.bytes) return false;
        upload.size = size; upload.crc = u32(m->data + 4); upload.id = m->id; upload.at = now;
        upload.width = c->rect.width; upload.height = c->rect.height;
        return true;
    }
    if (m->kind == DESK_PICTURE_CHUNK) {
        if (!upload.bytes || upload.id != m->id || m->length <= 4 || m->length > DESK_MAX_PICTURE_CHUNK + 4 ||
            u32(m->data) != upload.used || m->length - 4 > upload.size - upload.used) return false;
        memcpy(upload.bytes + upload.used, m->data + 4, m->length - 4);
        upload.used += m->length - 4; upload.at = now; return true;
    }
    if (m->kind == DESK_PICTURE_COMMIT) {
        if (m->length || !upload.bytes || upload.id != m->id) return false;
        picture candidate = {.status = {.id = m->id, .bytes = upload.size, .crc = upload.crc}, .started = now};
        picture *slot = find(m->id); if (!slot) slot = find(0);
        bool valid = slot && upload.used == upload.size && desk_crc32(upload.bytes, upload.size) == upload.crc &&
            desk_picture_pack_open(&candidate.pack, upload.bytes, upload.size) &&
            candidate.pack.width == c->rect.width && candidate.pack.height == c->rect.height;
        for (unsigned i = 0; valid && i < candidate.pack.count; ++i) {
            desk_frame_data frame = desk_picture_pack_frame(&candidate.pack, i);
            valid = hooks.validate_jpeg(&frame, candidate.pack.width, candidate.pack.height);
        }
        // Preserve the old animation until the complete candidate, including its first
        // decoded frame, succeeds. Never expose a partially transferred resource.
        if (!valid || !draw(&candidate, 0)) { abort_upload(); return false; }
        candidate.status.width = candidate.pack.width; candidate.status.height = candidate.pack.height;
        candidate.status.frame_count = candidate.pack.count; candidate.status.duration_ms = candidate.pack.duration_ms;
        free((void *)slot->pack.data); *slot = candidate;
        memset(&upload, 0, sizeof(upload)); return true;
    }
    picture *p = find(m->id);
    if (m->kind == DESK_PICTURE_STATS) return m->length == 0;
    if (m->kind != DESK_PICTURE_CONTROL || m->length != 1 || m->data[0] > 3) return false;
    unsigned action = m->data[0]; // Resume, pause, restart, clear.
    if (action == 3) { desk_pictures_forget(m->id); return true; }
    if (!p) return false;
    if (action == 2) {
        p->started = now; p->paused_at = 0; p->status.state = 0;
        p->status.decoded = p->status.presented = p->status.decode_us = p->status.max_decode_us = 0;
        p->pending = false;
        p->index = p->pack.count;
    } else if (action == 1 && !p->status.state) { p->status.state = 1; p->paused_at = now; }
    else if (action == 0 && p->status.state) {
        p->started += now - p->paused_at; p->paused_at = 0; p->status.state = 0;
    }
    return true;
}
void desk_pictures_tick(int64_t now, bool enabled) {
    if (upload.bytes && now - upload.at >= 30000000) abort_upload();
    if (!enabled) return;
    for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) {
        picture *p = &players[i];
        if (!p->status.id || p->status.state) continue;
        unsigned index = desk_picture_pack_index(&p->pack, (uint64_t)(now - p->started) / 1000);
        if (index != p->index && !draw(p, index)) { p->status.state = 2; p->paused_at = now; }
    }
}
void desk_pictures_presented(void) {
    for (unsigned i = 0; i < DESK_MAX_COMPONENTS; ++i) if (players[i].pending) {
        ++players[i].status.presented; players[i].pending = false;
    }
}
desk_picture_status desk_pictures_status(uint16_t id, int64_t now) {
    picture *p = find(id);
    if (!p) return (desk_picture_status){.id = id};
    desk_picture_status result = p->status;
    result.elapsed_us = (uint64_t)((result.state ? p->paused_at : now) - p->started);
    return result;
}
