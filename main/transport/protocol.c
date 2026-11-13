#include "protocol.h"
#include <string.h>

static uint16_t le16(const uint8_t *p)
{
    return (uint16_t)(p[0] | p[1] << 8);
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

uint32_t desk_crc32(const uint8_t *data, size_t size)
{
    // Byte-wise IEEE CRC avoids eight bit rounds for every USB payload byte.
    static const uint32_t table[256] = {
        0x00000000u, 0x77073096u, 0xee0e612cu, 0x990951bau, 0x076dc419u, 0x706af48fu, 0xe963a535u, 0x9e6495a3u,
        0x0edb8832u, 0x79dcb8a4u, 0xe0d5e91eu, 0x97d2d988u, 0x09b64c2bu, 0x7eb17cbdu, 0xe7b82d07u, 0x90bf1d91u,
        0x1db71064u, 0x6ab020f2u, 0xf3b97148u, 0x84be41deu, 0x1adad47du, 0x6ddde4ebu, 0xf4d4b551u, 0x83d385c7u,
        0x136c9856u, 0x646ba8c0u, 0xfd62f97au, 0x8a65c9ecu, 0x14015c4fu, 0x63066cd9u, 0xfa0f3d63u, 0x8d080df5u,
        0x3b6e20c8u, 0x4c69105eu, 0xd56041e4u, 0xa2677172u, 0x3c03e4d1u, 0x4b04d447u, 0xd20d85fdu, 0xa50ab56bu,
        0x35b5a8fau, 0x42b2986cu, 0xdbbbc9d6u, 0xacbcf940u, 0x32d86ce3u, 0x45df5c75u, 0xdcd60dcfu, 0xabd13d59u,
        0x26d930acu, 0x51de003au, 0xc8d75180u, 0xbfd06116u, 0x21b4f4b5u, 0x56b3c423u, 0xcfba9599u, 0xb8bda50fu,
        0x2802b89eu, 0x5f058808u, 0xc60cd9b2u, 0xb10be924u, 0x2f6f7c87u, 0x58684c11u, 0xc1611dabu, 0xb6662d3du,
        0x76dc4190u, 0x01db7106u, 0x98d220bcu, 0xefd5102au, 0x71b18589u, 0x06b6b51fu, 0x9fbfe4a5u, 0xe8b8d433u,
        0x7807c9a2u, 0x0f00f934u, 0x9609a88eu, 0xe10e9818u, 0x7f6a0dbbu, 0x086d3d2du, 0x91646c97u, 0xe6635c01u,
        0x6b6b51f4u, 0x1c6c6162u, 0x856530d8u, 0xf262004eu, 0x6c0695edu, 0x1b01a57bu, 0x8208f4c1u, 0xf50fc457u,
        0x65b0d9c6u, 0x12b7e950u, 0x8bbeb8eau, 0xfcb9887cu, 0x62dd1ddfu, 0x15da2d49u, 0x8cd37cf3u, 0xfbd44c65u,
        0x4db26158u, 0x3ab551ceu, 0xa3bc0074u, 0xd4bb30e2u, 0x4adfa541u, 0x3dd895d7u, 0xa4d1c46du, 0xd3d6f4fbu,
        0x4369e96au, 0x346ed9fcu, 0xad678846u, 0xda60b8d0u, 0x44042d73u, 0x33031de5u, 0xaa0a4c5fu, 0xdd0d7cc9u,
        0x5005713cu, 0x270241aau, 0xbe0b1010u, 0xc90c2086u, 0x5768b525u, 0x206f85b3u, 0xb966d409u, 0xce61e49fu,
        0x5edef90eu, 0x29d9c998u, 0xb0d09822u, 0xc7d7a8b4u, 0x59b33d17u, 0x2eb40d81u, 0xb7bd5c3bu, 0xc0ba6cadu,
        0xedb88320u, 0x9abfb3b6u, 0x03b6e20cu, 0x74b1d29au, 0xead54739u, 0x9dd277afu, 0x04db2615u, 0x73dc1683u,
        0xe3630b12u, 0x94643b84u, 0x0d6d6a3eu, 0x7a6a5aa8u, 0xe40ecf0bu, 0x9309ff9du, 0x0a00ae27u, 0x7d079eb1u,
        0xf00f9344u, 0x8708a3d2u, 0x1e01f268u, 0x6906c2feu, 0xf762575du, 0x806567cbu, 0x196c3671u, 0x6e6b06e7u,
        0xfed41b76u, 0x89d32be0u, 0x10da7a5au, 0x67dd4accu, 0xf9b9df6fu, 0x8ebeeff9u, 0x17b7be43u, 0x60b08ed5u,
        0xd6d6a3e8u, 0xa1d1937eu, 0x38d8c2c4u, 0x4fdff252u, 0xd1bb67f1u, 0xa6bc5767u, 0x3fb506ddu, 0x48b2364bu,
        0xd80d2bdau, 0xaf0a1b4cu, 0x36034af6u, 0x41047a60u, 0xdf60efc3u, 0xa867df55u, 0x316e8eefu, 0x4669be79u,
        0xcb61b38cu, 0xbc66831au, 0x256fd2a0u, 0x5268e236u, 0xcc0c7795u, 0xbb0b4703u, 0x220216b9u, 0x5505262fu,
        0xc5ba3bbeu, 0xb2bd0b28u, 0x2bb45a92u, 0x5cb36a04u, 0xc2d7ffa7u, 0xb5d0cf31u, 0x2cd99e8bu, 0x5bdeae1du,
        0x9b64c2b0u, 0xec63f226u, 0x756aa39cu, 0x026d930au, 0x9c0906a9u, 0xeb0e363fu, 0x72076785u, 0x05005713u,
        0x95bf4a82u, 0xe2b87a14u, 0x7bb12baeu, 0x0cb61b38u, 0x92d28e9bu, 0xe5d5be0du, 0x7cdcefb7u, 0x0bdbdf21u,
        0x86d3d2d4u, 0xf1d4e242u, 0x68ddb3f8u, 0x1fda836eu, 0x81be16cdu, 0xf6b9265bu, 0x6fb077e1u, 0x18b74777u,
        0x88085ae6u, 0xff0f6a70u, 0x66063bcau, 0x11010b5cu, 0x8f659effu, 0xf862ae69u, 0x616bffd3u, 0x166ccf45u,
        0xa00ae278u, 0xd70dd2eeu, 0x4e048354u, 0x3903b3c2u, 0xa7672661u, 0xd06016f7u, 0x4969474du, 0x3e6e77dbu,
        0xaed16a4au, 0xd9d65adcu, 0x40df0b66u, 0x37d83bf0u, 0xa9bcae53u, 0xdebb9ec5u, 0x47b2cf7fu, 0x30b5ffe9u,
        0xbdbdf21cu, 0xcabac28au, 0x53b39330u, 0x24b4a3a6u, 0xbad03605u, 0xcdd70693u, 0x54de5729u, 0x23d967bfu,
        0xb3667a2eu, 0xc4614ab8u, 0x5d681b02u, 0x2a6f2b94u, 0xb40bbe37u, 0xc30c8ea1u, 0x5a05df1bu, 0x2d02ef8du,
    };
    uint32_t crc = UINT32_MAX;
    while (size--) crc = (crc >> 8) ^ table[(crc ^ *data++) & 0xff];
    return ~crc;
}

void desk_parser_reset(desk_parser *parser)
{
    parser->header_used = 0;
    parser->payload_used = 0;
    parser->payload_size = 0;
}

static bool picture_alpha_dimensions(uint16_t id, unsigned width, unsigned height)
{
    return id >= DESK_PICTURE_FIRST_ID && id <= DESK_PICTURE_LAST_ID && width == height &&
           width >= DESK_PICTURE_GRID_STEP && width <= DESK_MAX_PICTURE_SIDE && width % DESK_PICTURE_GRID_STEP == 0;
}

bool desk_frame_payload(const desk_message *message, desk_frame_data *frame)
{
    if (message->kind == DESK_FRAME) {
        *frame = (desk_frame_data){.jpeg = message->data, .jpeg_length = message->length};
        return true;
    }
    if (message->kind != DESK_ALPHA_FRAME || message->length < 9) return false;

    const size_t end = message->length - 4;
    const size_t jpeg_length = le32(message->data + end);
    const size_t pixels = (size_t)message->width * message->height;
    bool dimensions_ok = message->id == DESK_PET_ID ? pixels <= DESK_MAX_PET_PIXELS :
                         picture_alpha_dimensions(message->id, message->width, message->height);
    if (!dimensions_ok || jpeg_length < 4 || jpeg_length > DESK_MAX_JPEG || jpeg_length >= end ||
        end - jpeg_length > pixels) return false;
    *frame = (desk_frame_data){
        .jpeg = message->data, .jpeg_length = jpeg_length,
        .mask = message->data + jpeg_length, .mask_length = end - jpeg_length,
    };
    return true;
}

bool desk_unpack_alpha(const uint8_t *mask, size_t length, uint8_t *alpha, size_t pixels)
{
    if (!length || length > pixels) return false;
    if (length == pixels) {
        memcpy(alpha, mask, pixels);
        return true;
    }
    if (length % 2 != 0) return false;
    size_t written = 0;
    for (size_t i = 0; i < length; i += 2) {
        size_t run = mask[i];
        if (!run || run > pixels - written) return false;
        memset(alpha + written, mask[i + 1], run);
        written += run;
    }
    return written == pixels;
}

static void deliver(desk_parser *parser)
{
    const uint8_t *header = parser->header;
    uint32_t checksum = le32(header + 16);
    desk_message message = {
        .kind = header[5],
        .sequence = le32(header + 8),
        .checksum = checksum,
        .id = le16(header + 6),
        .width = le16(header + 20),
        .height = le16(header + 22),
        .data = parser->payload,
        .length = parser->payload_size,
        .checksum_ok = desk_crc32(parser->payload, parser->payload_size) == checksum,
    };
    parser->on_message(parser->context, &message);
    desk_parser_reset(parser);
}

void desk_parser_feed(desk_parser *parser, const uint8_t *data, size_t size)
{
    while (size > 0) {
        if (parser->payload_size > 0) {
            size_t count = parser->payload_size - parser->payload_used;
            if (count > size) count = size;
            memcpy(parser->payload + parser->payload_used, data, count);
            parser->payload_used += count;
            data += count;
            size -= count;
            if (parser->payload_used == parser->payload_size) deliver(parser);
            continue;
        }

        parser->header[parser->header_used++] = *data++;
        --size;
        if (parser->header_used < DESK_HEADER_SIZE) continue;

        const uint8_t *header = parser->header;
        uint32_t length = le32(header + 12);
        uint16_t id = le16(header + 6);
        uint16_t width = le16(header + 20), height = le16(header + 22);
        uint32_t dimensions = le32(header + 20);
        bool frame_id = parser->controls ? id > DESK_PET_ID : id == DESK_PET_ID;
        bool valid_frame = frame_id && header[5] == DESK_FRAME && length >= 4 && length <= DESK_MAX_JPEG;
        bool valid_alpha = frame_id && header[5] == DESK_ALPHA_FRAME && length >= 9 &&
                           (parser->controls ? picture_alpha_dimensions(id, width, height) &&
                                               length <= DESK_MAX_JPEG + (size_t)width * height + 4u
                                             : length <= DESK_MAX_ALPHA_FRAME);
        bool valid_keepalive = !parser->controls && id == DESK_PET_ID && header[5] == DESK_KEEPALIVE &&
                               length == 0 && dimensions == 0;
        bool valid_settings = parser->controls && id == 0 && dimensions == 0 &&
                            ((header[5] == DESK_GET_LAYOUT && length == 0) ||
                             (header[5] == DESK_SET_LAYOUT && length >= 2 && length <= DESK_LAYOUT_WIRE_MAX) ||
                             (header[5] == DESK_SET_BACKLIGHT && length == 2));
        bool valid_widget = parser->controls && id > DESK_PET_ID && dimensions == 0 &&
                            ((header[5] == DESK_WIDGET_DATA && length >= 2 && length <= DESK_MAX_WIDGET_DATA) ||
                             (header[5] == DESK_WIDGET_GLYPH_DATA && length >= 6 &&
                              length <= DESK_MAX_WIDGET_GLYPH_PACKET));
        bool wallpaper_dimensions = (width == DESK_LCD_WIDTH && height == DESK_LCD_HEIGHT) ||
                                    (width == DESK_LCD_HEIGHT && height == DESK_LCD_WIDTH);
        bool valid_wallpaper = parser->controls && id == 0 && header[5] == DESK_SET_WALLPAPER &&
                               wallpaper_dimensions && length >= 4 && length <= DESK_MAX_WALLPAPER_JPEG;
        bool valid_pet = !parser->controls && id == DESK_PET_ID && dimensions == 0 &&
                         ((header[5] == DESK_PET_BEGIN && length == 8) ||
                          (header[5] == DESK_PET_CHUNK && length > 4 && length <= 4 + DESK_MAX_PET_CHUNK) ||
                          (header[5] == DESK_PET_COMMIT && length == 0) ||
                          (header[5] == DESK_PET_INPUT && length >= 2 && length <= DESK_MAX_PET_INPUT) ||
                          (header[5] == DESK_PET_RESUME && length == 8) ||
                          (header[5] == DESK_PET_CLEAR && length == 0));
        bool valid_model = parser->controls && id == DESK_MODEL3D_ID && dimensions == 0 &&
                          ((header[5] == DESK_MODEL3D_BEGIN && length == 8) ||
                           (header[5] == DESK_MODEL3D_CHUNK && length > 4 && length <= 4 + DESK_MAX_MODEL3D_CHUNK) ||
                           (header[5] == DESK_MODEL3D_COMMIT && length == 0) ||
                           (header[5] == DESK_MODEL3D_CONTROL && length == 2) ||
                           (header[5] == DESK_MODEL3D_STATS && length == 0) ||
                           (header[5] == DESK_MODEL3D_ABORT && length == 0));
        if (memcmp(header, "ISLE", 4) == 0 && header[4] == DESK_PROTOCOL_VERSION &&
            length <= parser->payload_capacity &&
            (valid_frame || valid_alpha || valid_keepalive || valid_settings || valid_widget || valid_wallpaper || valid_pet || valid_model)) {
            parser->payload_size = length;
            if (length == 0) deliver(parser);
        } else {
            // Recover at the next valid header after noise or a different protocol.
            memmove(parser->header, parser->header + 1, DESK_HEADER_SIZE - 1);
            parser->header_used = DESK_HEADER_SIZE - 1;
        }
    }
}
