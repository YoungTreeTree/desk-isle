#pragma once
#include <sys/ioctl.h>
#include <termios.h>
#include <IOKit/serial/ioss.h>
#include "frosted.h"
#include "MacSensors.h"

static inline int desk_uart_set_speed(int descriptor, speed_t baud)
{
    return ioctl(descriptor, IOSSIOSPEED, &baud);
}
