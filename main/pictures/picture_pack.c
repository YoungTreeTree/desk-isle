#include "picture_pack.h"
#include <string.h>

static uint16_t u16(const uint8_t *p) { return (uint16_t)p[0] | (uint16_t)p[1] << 8; }
static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static size_t align64(size_t n) { return (n + 63u) & ~(size_t)63u; }

bool desk_picture_pack_open(desk_picture_pack *out, const uint8_t *data, size_t size)
{
    if (!out || !data || size < 64 || size > DESK_MAX_PICTURE_PACK || memcmp(data, "DIGA", 4) || u16(data + 4) != 1) return false;
    unsigned count = u16(data + 6), width = u16(data + 8), height = u16(data + 10);
    uint32_t duration = u32(data + 12);
    if (count < 2 || count > DESK_MAX_PICTURE_FRAMES || width != height || width < DESK_PICTURE_GRID_STEP ||
        width > DESK_MAX_PICTURE_SIDE || width % DESK_PICTURE_GRID_STEP || duration < count || duration > 86400000u) return false;
    size_t cursor = align64(16u + 16u * count), pixels = (size_t)width * height;
    if (cursor > size) return false;
    uint32_t previous = 0;
    for (unsigned i = 0; i < count; ++i) {
        const uint8_t *entry = data + 16 + 16 * i;
        uint32_t start = u32(entry), offset = u32(entry + 4), jpeg = u32(entry + 8), mask = u32(entry + 12);
        if ((!i && start) || (i && start <= previous) || start >= duration || offset != cursor ||
            jpeg < 4 || jpeg > DESK_MAX_JPEG || mask > pixels || jpeg > size - cursor || mask > size - cursor - jpeg) return false;
        if (data[cursor] != 0xff || data[cursor + 1] != 0xd8) return false;
        if (mask && mask != pixels) {
            if (mask % 2) return false;
            size_t covered = 0;
            const uint8_t *runs = data + cursor + jpeg;
            for (size_t n = 0; n < mask; n += 2) {
                if (!runs[n] || runs[n] > pixels - covered) return false;
                covered += runs[n];
            }
            if (covered != pixels) return false;
        }
        cursor = align64(cursor + jpeg + mask);
        if (cursor > size) return false;
        previous = start;
    }
    if (cursor != size) return false;
    *out = (desk_picture_pack){data, size, width, height, count, duration};
    return true;
}

desk_frame_data desk_picture_pack_frame(const desk_picture_pack *pack, unsigned index)
{
    if (!pack || index >= pack->count) return (desk_frame_data){0};
    const uint8_t *entry = pack->data + 16 + 16 * index;
    uint32_t offset = u32(entry + 4), jpeg = u32(entry + 8), mask = u32(entry + 12);
    return (desk_frame_data){.jpeg = pack->data + offset, .jpeg_length = jpeg,
                             .mask = mask ? pack->data + offset + jpeg : NULL, .mask_length = mask};
}

unsigned desk_picture_pack_index(const desk_picture_pack *pack, uint64_t elapsed_ms)
{
    if (!pack || !pack->count || !pack->duration_ms) return 0;
    uint32_t phase = elapsed_ms % pack->duration_ms;
    unsigned index = 0;
    while (index + 1 < pack->count && u32(pack->data + 16 + 16 * (index + 1)) <= phase) ++index;
    return index;
}
