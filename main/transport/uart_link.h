#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DESK_UART_BAUD 3000000
#define DESK_UART_CHUNK 2048u
#define DESK_UART_HEADER 8u
#define DESK_UART_TRAILER 4u
#define DESK_UART_WIRE_MAX (2u * (DESK_UART_HEADER + DESK_UART_CHUNK + DESK_UART_TRAILER) + 2u)

enum desk_uart_channel {
    DESK_UART_ANIMATION = 0,
    DESK_UART_LAYOUT = 1,
    DESK_UART_RECEIVED = 2,
};

typedef struct {
    uint8_t bytes[DESK_UART_HEADER + DESK_UART_CHUNK + DESK_UART_TRAILER];
    size_t length;
    bool escaped, invalid;
} desk_uart_decoder;

typedef void (*desk_uart_packet_fn)(uint8_t channel, uint16_t token, const uint8_t *data, size_t length);

void desk_uart_feed(desk_uart_decoder *decoder, const uint8_t *data, size_t length, desk_uart_packet_fn receive);
size_t desk_uart_encode(uint8_t channel, uint16_t token, const uint8_t *data, size_t length, uint8_t *wire);
