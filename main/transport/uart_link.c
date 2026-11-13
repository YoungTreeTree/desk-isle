#include "uart_link.h"
#include "protocol.h"
#include <string.h>

enum { END = 0xc0, ESC = 0xdb, ESC_END = 0xdc, ESC_ESC = 0xdd };

void desk_uart_feed(desk_uart_decoder *decoder, const uint8_t *data, size_t length, desk_uart_packet_fn receive)
{
    while (length--) {
        uint8_t byte = *data++;
        if (byte == END) {
            const uint8_t *packet = decoder->bytes;
            if (!decoder->invalid && !decoder->escaped && decoder->length >= DESK_UART_HEADER + DESK_UART_TRAILER &&
                memcmp(packet, "DS2", 3) == 0 && packet[3] <= DESK_UART_RECEIVED) {
                const uint16_t token = packet[4] | (uint16_t)packet[5] << 8;
                const size_t size = packet[6] | (size_t)packet[7] << 8;
                const size_t end = decoder->length - DESK_UART_TRAILER;
                if (size == end - DESK_UART_HEADER) {
                    const uint8_t *crc = packet + end;
                    const uint32_t checksum = (uint32_t)crc[0] | (uint32_t)crc[1] << 8 |
                                              (uint32_t)crc[2] << 16 | (uint32_t)crc[3] << 24;
                    if (checksum == desk_crc32(packet, end)) receive(packet[3], token, packet + DESK_UART_HEADER, size);
                }
            }
            decoder->length = 0;
            decoder->escaped = decoder->invalid = false;
            continue;
        }
        if (decoder->invalid) continue;
        if (decoder->escaped) {
            decoder->escaped = false;
            if (byte == ESC_END) byte = END;
            else if (byte == ESC_ESC) byte = ESC;
            else { decoder->invalid = true; continue; }
        } else if (byte == ESC) {
            decoder->escaped = true;
            continue;
        }
        if (decoder->length == sizeof(decoder->bytes)) decoder->invalid = true;
        else decoder->bytes[decoder->length++] = byte;
    }
}

size_t desk_uart_encode(uint8_t channel, uint16_t token, const uint8_t *data, size_t length, uint8_t *wire)
{
    if (length > DESK_UART_CHUNK) return 0;
    uint8_t packet[DESK_UART_HEADER + DESK_UART_CHUNK + DESK_UART_TRAILER];
    const uint8_t header[] = {
        'D', 'S', '2', channel, (uint8_t)token, (uint8_t)(token >> 8), (uint8_t)length, (uint8_t)(length >> 8),
    };
    memcpy(packet, header, sizeof(header));
    const size_t end = DESK_UART_HEADER + length;
    if (length) memcpy(packet + DESK_UART_HEADER, data, length);
    const uint32_t checksum = desk_crc32(packet, end);
    for (unsigned i = 0; i < DESK_UART_TRAILER; ++i) packet[end + i] = (uint8_t)(checksum >> (8u * i));
    size_t size = 0;
    wire[size++] = END;
    for (size_t i = 0; i < end + DESK_UART_TRAILER; ++i) {
        const uint8_t byte = packet[i];
        if (byte == END || byte == ESC) {
            wire[size++] = ESC;
            wire[size++] = byte == END ? ESC_END : ESC_ESC;
        } else {
            wire[size++] = byte;
        }
    }
    wire[size++] = END;
    return size;
}
