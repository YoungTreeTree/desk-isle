#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "protocol.h"
#include "uart_link.h"

typedef struct {
    unsigned frames;
    unsigned checksum_errors;
    unsigned keepalives;
    unsigned alpha_frames;
    unsigned picture_alpha_frames;
    unsigned widget_updates;
    unsigned glyph_updates;
    unsigned wallpapers;
    unsigned pet_messages;
    unsigned pet_recovery_messages;
    unsigned backlight_commands;
    unsigned model_commands;
    unsigned picture_commands;
} results;

static uint8_t alpha[DESK_MAX_PET_PIXELS];

static void received(void *context, const desk_message *message)
{
    results *counts = context;
    if (message->kind >= DESK_PICTURE_BEGIN && message->kind <= DESK_PICTURE_ABORT) {
        assert(message->id == 0x8100 && !message->width && !message->height && message->checksum_ok);
        assert(message->sequence == 110 + counts->picture_commands);
        assert(message->kind == DESK_PICTURE_BEGIN + counts->picture_commands);
        ++counts->picture_commands; return;
    }
    if(message->kind>=DESK_MODEL3D_BEGIN&&message->kind<=DESK_MODEL3D_ABORT){
        assert(message->id==DESK_MODEL3D_ID&&message->width==0&&message->height==0&&message->checksum_ok);
        assert(message->sequence==100+counts->model_commands);
        assert(message->kind==DESK_MODEL3D_BEGIN+counts->model_commands);
        ++counts->model_commands;return;
    }
    if (message->kind == DESK_SET_BACKLIGHT) {
        assert(message->id == 0 && message->width == 0 && message->height == 0 && message->length == 2);
        assert(message->sequence == 27 + counts->backlight_commands);
        assert(message->checksum_ok == (message->sequence == 27));
        assert(message->data[0] == 42 && message->data[1] == (message->sequence == 27));
        ++counts->backlight_commands;
        return;
    }
    if (message->kind >= DESK_PET_BEGIN && message->kind <= DESK_PET_INPUT) {
        assert(message->id == DESK_PET_ID && message->width == 0 && message->height == 0 && message->checksum_ok);
        assert(message->sequence == 15 + counts->pet_messages && message->kind == DESK_PET_BEGIN + counts->pet_messages);
        ++counts->pet_messages;
        return;
    }
    if (message->kind == DESK_PET_RESUME || message->kind == DESK_PET_CLEAR) {
        assert(message->id == DESK_PET_ID && message->width == 0 && message->height == 0 && message->checksum_ok);
        assert(message->sequence == 29 + counts->pet_recovery_messages);
        assert(message->kind == DESK_PET_RESUME + counts->pet_recovery_messages);
        assert(message->length == (message->kind == DESK_PET_RESUME ? 8u : 0u));
        ++counts->pet_recovery_messages;
        return;
    }
    if (message->kind == DESK_SET_WALLPAPER) {
        assert(message->id == 0 && message->checksum_ok);
        if (counts->wallpapers == 0) {
            assert(message->sequence == 14 && message->width == DESK_LCD_WIDTH && message->height == DESK_LCD_HEIGHT);
            assert(message->length > DESK_MAX_JPEG && message->length <= DESK_MAX_WALLPAPER_JPEG);
        } else {
            assert(message->sequence == 22 && message->width == DESK_LCD_HEIGHT && message->height == DESK_LCD_WIDTH);
            assert(message->length == 6);
        }
        assert(message->data[0] == 0xff && message->data[message->length - 1] == 0xd9);
        assert(message->checksum == desk_crc32(message->data, message->length));
        ++counts->wallpapers;
        return;
    }
    if (message->kind == DESK_WIDGET_DATA) {
        assert(message->id == 0x8003 && message->sequence == 11 && message->checksum_ok);
        assert(message->width == 0 && message->height == 0 && message->data[0] == '{');
        ++counts->widget_updates;
        return;
    }
    if (message->kind == DESK_WIDGET_GLYPH_DATA) {
        assert(message->id == 0x8003 && message->sequence == 21 && message->checksum_ok);
        assert(message->width == 0 && message->height == 0);
        size_t json = message->data[0] | (size_t)message->data[1] << 8;
        assert(json >= 2 && json + 4 < message->length && message->data[2] == '{');
        assert(message->data[2 + json] == 1 && message->data[3 + json] == 0);
        ++counts->glyph_updates;
        return;
    }
    if (message->kind == DESK_KEEPALIVE) {
        assert(message->sequence == 3);
        assert(message->checksum_ok && message->length == 0);
        ++counts->keepalives;
        return;
    }
    if (message->kind == DESK_ALPHA_FRAME) {
        assert(message->checksum_ok);
        const size_t pixels = (size_t)message->width * message->height;
        assert(pixels <= sizeof(alpha));
        desk_frame_data frame;
        if (message->id != DESK_PET_ID) {
            assert(desk_frame_payload(message, &frame) && frame.jpeg_length == 6);
            assert(desk_unpack_alpha(frame.mask, frame.mask_length, alpha, pixels));
            if (message->sequence == 23) {
                assert(message->id == DESK_PICTURE_FIRST_ID && message->width == 80 && message->height == 80);
                assert(frame.mask_length < pixels && alpha[0] == 0 && alpha[255] == 128 && alpha[pixels - 1] == 255);
            } else {
                assert(message->sequence == 24 && message->id == DESK_PICTURE_LAST_ID);
                assert(pixels == DESK_MAX_PICTURE_PIXELS && frame.mask_length == pixels);
                assert(alpha[0] == 0 && alpha[1] == 128 && alpha[2] == 255 && alpha[pixels - 1] == 1);
            }
            ++counts->picture_alpha_frames;
            return;
        }
        if (message->sequence == 8) {
            assert(!desk_frame_payload(message, &frame));
        } else {
            assert(desk_frame_payload(message, &frame) && frame.jpeg_length == 6);
            assert(frame.jpeg == message->data && frame.jpeg[0] == 0xff && frame.jpeg[1] == 0xd8);
            assert(desk_unpack_alpha(frame.mask, frame.mask_length, alpha, pixels));
            if (message->sequence == 7) {
                assert(frame.mask_length < pixels);
                assert(alpha[0] == 0 && alpha[255] == 128 && alpha[pixels - 1] == 255);
            } else {
                assert((message->sequence == 9 || message->sequence == 10) && frame.mask_length == pixels);
                if (message->sequence == 10) {
                    assert(message->width == DESK_PET_LARGE_WIDTH && message->height == DESK_PET_LARGE_HEIGHT);
                }
                assert(alpha[0] == 0 && alpha[1] == 128 && alpha[2] == 255 && alpha[pixels - 1] == 1);
            }
        }
        ++counts->alpha_frames;
        return;
    }
    assert(message->kind == DESK_FRAME);
    assert(message->width == 512 && message->height == 288);
    assert(message->data[0] == 0xff && message->data[1] == 0xd8);
    if (!message->checksum_ok) {
        assert(message->sequence == 2 && message->length == 6);
        ++counts->checksum_errors;
        return;
    }
    if (message->sequence == 1) assert(message->length == 6);
    else assert(message->sequence == 4 && message->length == DESK_MAX_JPEG);
    ++counts->frames;
}

static unsigned uart_packets;

static void uart_received(uint8_t channel, uint16_t token, const uint8_t *data, size_t length)
{
    if (uart_packets == 0) {
        assert(channel == DESK_UART_ANIMATION && token == 0xc0db && length == 4);
        assert(memcmp(data, (uint8_t[]){0xc0, 0, 0xdb, 0x42}, length) == 0);
    } else {
        assert(uart_packets == 1 && channel == DESK_UART_LAYOUT && token == 0x1234 && length == 0);
    }
    ++uart_packets;
}

static void test_uart_link(void)
{
    const uint8_t payload[] = {0xc0, 0, 0xdb, 0x42};
    const uint8_t escaped[] = {0xc0, 'D', 'S', '2', 0, 0xdb, 0xdd, 0xdb, 0xdc, 4, 0,
                               0xdb, 0xdc, 0, 0xdb, 0xdd, 0x42, 0x79, 0xc6, 0x42, 0x45, 0xc0};
    uint8_t wire[DESK_UART_WIRE_MAX];
    desk_uart_decoder decoder = {0};
    size_t size = desk_uart_encode(DESK_UART_ANIMATION, 0xc0db, payload, sizeof(payload), wire);
    assert(size == sizeof(escaped) && memcmp(escaped, wire, size) == 0);
    desk_uart_feed(&decoder, (const uint8_t *)"ROM boot\n", 9, uart_received);
    wire[size - 6] ^= 1;
    desk_uart_feed(&decoder, wire, size, uart_received);
    assert(uart_packets == 0);
    wire[size - 6] ^= 1;
    // Simulate a cable unplug halfway through a frame, then a fragmented reconnect.
    desk_uart_feed(&decoder, wire, size - 4, uart_received);
    for (size_t i = 0; i < size; ++i) desk_uart_feed(&decoder, &wire[i], 1, uart_received);
    size = desk_uart_encode(DESK_UART_LAYOUT, 0x1234, NULL, 0, wire);
    desk_uart_feed(&decoder, wire, size, uart_received);
    assert(uart_packets == 2);
}

int main(int argc, char **argv)
{
    test_uart_link();
    assert(argc == 2);
    const size_t control_offset = strtoul(argv[1], NULL, 10);
    const size_t input_capacity = control_offset + DESK_MAX_WALLPAPER_JPEG + 4 * DESK_MAX_PICTURE_CHUNK;
    uint8_t *payload = malloc(DESK_MAX_WALLPAPER_JPEG);
    uint8_t *bytes = malloc(input_capacity);
    assert(payload && bytes);
    size_t size = fread(bytes, 1, input_capacity, stdin);
    assert(feof(stdin) && size > control_offset && control_offset > DESK_MAX_JPEG);
    assert(!desk_unpack_alpha((uint8_t[]){9, 255}, 2, alpha, 8));
    assert(!desk_unpack_alpha((uint8_t[]){3, 255}, 2, alpha, 8));

    const size_t chunks[] = {1, 2, 23, 24, 47, 512, 4096, 8192};
    for (unsigned index = 0; index < sizeof(chunks) / sizeof(chunks[0]); ++index) {
        results counts = {0};
        desk_parser parser = {
            .payload = payload, .payload_capacity = DESK_MAX_ALPHA_FRAME, .on_message = received, .context = &counts,
        };
        desk_parser_feed(&parser, bytes, 17);
        desk_parser_reset(&parser);
        for (size_t offset = 0; offset < size;) {
            size_t count = size - offset;
            if (count > chunks[index]) count = chunks[index];
            desk_parser_feed(&parser, bytes + offset, count);
            offset += count;
        }
        assert(counts.frames == 2 && counts.checksum_errors == 1 && counts.keepalives == 1 &&
               counts.alpha_frames == 4 && counts.widget_updates == 0 && counts.glyph_updates == 0 && counts.wallpapers == 0 &&
               counts.picture_alpha_frames == 0 && counts.pet_messages == 4 && counts.backlight_commands == 0);
        assert(counts.pet_recovery_messages == 2);
        assert(counts.model_commands == 0);
        assert(counts.picture_commands == 0);
        assert(parser.payload_size == 0);

        desk_parser_reset(&parser);
        parser.controls = true;
        parser.payload_capacity = DESK_MAX_WALLPAPER_JPEG;
        for (size_t offset = 0; offset < size;) {
            size_t count = size - offset;
            if (count > chunks[index]) count = chunks[index];
            desk_parser_feed(&parser, bytes + offset, count);
            offset += count;
        }
        assert(counts.widget_updates == 1 && counts.glyph_updates == 1 && counts.wallpapers == 2);
        assert(counts.model_commands == 6);
        assert(counts.picture_commands == 6);
        assert(counts.picture_alpha_frames == 2 && counts.alpha_frames == 4 && counts.pet_messages == 4 &&
               counts.pet_recovery_messages == 2 &&
               counts.backlight_commands == 2);
        assert(parser.header_used == 0 && parser.payload_size == 0);
    }
    free(bytes);
    free(payload);
    puts("PASS fragmented frames, CRC, limits, keepalive, alpha payloads, widgets, glyphs, wallpaper and native pet");
}
