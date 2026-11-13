#pragma once
#include "protocol.h"

// DIGA v1: 16-byte header, 16-byte frame entries; JPEG starts are 64-byte aligned.
// All integers are little endian. Each JPEG is followed by its raw/RLE alpha mask.
typedef struct {
    const uint8_t *data;
    size_t size;
    unsigned width, height, count;
    uint32_t duration_ms;
} desk_picture_pack;

bool desk_picture_pack_open(desk_picture_pack *pack, const uint8_t *data, size_t size);
desk_frame_data desk_picture_pack_frame(const desk_picture_pack *pack, unsigned index);
unsigned desk_picture_pack_index(const desk_picture_pack *pack, uint64_t elapsed_ms);
