#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "layout.h"

#define DESK_PROTOCOL_VERSION 1u
#define DESK_HEADER_SIZE 24u
#define DESK_MAX_JPEG (96u * 1024u)
#define DESK_MAX_PET_PIXELS (DESK_PET_LARGE_WIDTH * DESK_PET_LARGE_HEIGHT)
#define DESK_MAX_ALPHA_FRAME (DESK_MAX_JPEG + DESK_MAX_PET_PIXELS + 4u)
#define DESK_PICTURE_FIRST_ID 0x8100u
#define DESK_PICTURE_LAST_ID 0x81ffu
#define DESK_PICTURE_GRID_STEP (2u * DESK_GRID_PX)
#define DESK_MAX_PICTURE_SIDE (8u * DESK_GRID_PX)
#define DESK_MAX_PICTURE_PIXELS (DESK_MAX_PICTURE_SIDE * DESK_MAX_PICTURE_SIDE)
#define DESK_MAX_WIDGET_DATA 4096u
#define DESK_MAX_WIDGET_GLYPH_PACKET (256u * 1024u)
#define DESK_MAX_WALLPAPER_JPEG (512u * 1024u)
#define DESK_MAX_PET_PACK_LEGACY (6u * 1024u * 1024u)
#define DESK_MAX_PET_PACK (8u * 1024u * 1024u)
#define DESK_MAX_PET_CHUNK (96u * 1024u)
#define DESK_MAX_PET_INPUT (16u * 1024u)
#define DESK_LEASE_MS 3000u
#define DESK_NATIVE_PET_GRACE_MS 60000u
#define DESK_BACKLIGHT_MAX 100u

typedef enum {
    DESK_FRAME = 1,
    DESK_KEEPALIVE = 2,
    DESK_GET_LAYOUT = 3,
    DESK_SET_LAYOUT = 4,
    DESK_ALPHA_FRAME = 5,
    DESK_WIDGET_DATA = 6,
    DESK_SET_WALLPAPER = 7,
    DESK_PET_BEGIN = 8,
    DESK_PET_CHUNK = 9,
    DESK_PET_COMMIT = 10,
    DESK_PET_INPUT = 11,
    DESK_WIDGET_GLYPH_DATA = 12,
    DESK_SET_BACKLIGHT = 13,
    DESK_PET_RESUME = 14,
    DESK_PET_CLEAR = 15,
} desk_message_kind;

typedef enum {
    DESK_ACK_OK = 0,
    DESK_ACK_CHECKSUM = 1,
    DESK_ACK_DIMENSIONS = 2,
    DESK_ACK_DISPLAY = 3,
    DESK_ACK_WIDGET_DATA = 4,
    DESK_ACK_PET = 5,
    DESK_ACK_PET_MISSING = 6,
} desk_ack_status;

typedef struct {
    desk_message_kind kind;
    uint32_t sequence;
    uint32_t checksum;
    uint16_t id;
    uint16_t width;
    uint16_t height;
    const uint8_t *data;
    size_t length;
    bool checksum_ok;
} desk_message;

typedef struct {
    const uint8_t *jpeg, *mask;
    size_t jpeg_length, mask_length;
} desk_frame_data;

typedef void (*desk_message_fn)(void *context, const desk_message *message);

typedef struct {
    uint8_t header[DESK_HEADER_SIZE];
    size_t header_used;
    size_t payload_used;
    size_t payload_size;
    uint8_t *payload;
    size_t payload_capacity;
    bool controls;
    desk_message_fn on_message;
    void *context;
} desk_parser;

void desk_parser_reset(desk_parser *parser);
void desk_parser_feed(desk_parser *parser, const uint8_t *data, size_t size);
uint32_t desk_crc32(const uint8_t *data, size_t size);
bool desk_frame_payload(const desk_message *message, desk_frame_data *frame);
bool desk_unpack_alpha(const uint8_t *mask, size_t length, uint8_t *alpha, size_t pixels);
