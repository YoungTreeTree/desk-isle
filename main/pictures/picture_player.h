#pragma once
#include "picture_pack.h"

typedef struct {
    void *(*allocate)(size_t); // 64-byte aligned PSRAM; released with free().
    bool (*validate_jpeg)(const desk_frame_data *, unsigned, unsigned);
    bool (*draw)(uint16_t, const desk_frame_data *);
    int64_t (*clock_us)(void);
} desk_picture_hooks;

typedef struct {
    uint16_t id, width, height, frame_count;
    size_t bytes;
    uint32_t crc, duration_ms;
    unsigned state; // 0 playing, 1 paused, 2 decode failed
    uint64_t decoded, presented, elapsed_us, decode_us, max_decode_us;
} desk_picture_status;

void desk_pictures_init(desk_picture_hooks hooks);
bool desk_pictures_receive(const desk_message *message, const desk_component *component, int64_t now);
void desk_pictures_layout(const desk_layout *layout);
void desk_pictures_tick(int64_t now, bool enabled);
void desk_pictures_presented(void);
void desk_pictures_forget(uint16_t id);
desk_picture_status desk_pictures_status(uint16_t id, int64_t now);
size_t desk_pictures_memory(void); // Includes the in-progress upload, bounded by the cache budget.
