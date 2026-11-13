#pragma once

#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// AppleSMC user-client ABI. Only key metadata (9) and value reads (5) are used.
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, memory; } limits;
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, command;
    uint32_t data;
    uint8_t bytes[32];
} desk_smc_message;

typedef struct { uint32_t key, size, type; } desk_smc_key;

_Static_assert(sizeof(desk_smc_message) == 80 && offsetof(desk_smc_message, bytes) == 48,
               "AppleSMC message layout changed");

static inline bool desk_smc_call(io_connect_t connection, desk_smc_message *input, desk_smc_message *output)
{
    size_t size = sizeof(*output);
    return IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size) == KERN_SUCCESS &&
           size == sizeof(*output) && output->result == 0;
}

static inline bool desk_smc_describe(io_connect_t connection, uint32_t key, desk_smc_key *descriptor)
{
    desk_smc_message input = { .key = key, .command = 9 }, output = {0};
    if (!desk_smc_call(connection, &input, &output)) return false;
    // flt (IEEE float) and sp78 (signed 8.8 fixed point) are the sensor types we understand.
    if (!((output.info.type == 0x666c7420 && output.info.size == 4) ||
          (output.info.type == 0x73703738 && output.info.size == 2))) return false;
    *descriptor = (desk_smc_key){key, output.info.size, output.info.type};
    return true;
}

static inline bool desk_smc_read(io_connect_t connection, desk_smc_key descriptor, double *value)
{
    desk_smc_message input = { .key = descriptor.key, .command = 5 }, output = {0};
    input.info.size = descriptor.size;
    if (!desk_smc_call(connection, &input, &output)) return false;
    if (descriptor.type == 0x666c7420 && descriptor.size == 4) {
        uint32_t bits = (uint32_t)output.bytes[0] | (uint32_t)output.bytes[1] << 8 |
                        (uint32_t)output.bytes[2] << 16 | (uint32_t)output.bytes[3] << 24;
        float number;
        memcpy(&number, &bits, sizeof(number));
        *value = number;
    } else if (descriptor.type == 0x73703738 && descriptor.size == 2) {
        *value = (int16_t)((uint16_t)output.bytes[0] << 8 | output.bytes[1]) / 256.0;
    } else return false;
    return isfinite(*value);
}
