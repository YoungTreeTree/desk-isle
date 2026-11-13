#pragma once

#include "widget.h"

#define WIDGET_RGB(r, g, b) ((uint16_t)((((r) & 248) << 8) | (((g) & 252) << 3) | ((b) >> 3)))

void widget_rect(widget_canvas *canvas, widget_box box, uint16_t color, uint8_t opacity);
void widget_round(widget_canvas *canvas, widget_box box, int radius, uint16_t color, uint8_t opacity);
void widget_round_replace(widget_canvas *canvas, widget_box box, int radius, uint16_t color, uint8_t opacity);
void widget_line(widget_canvas *canvas, int x, int y, int to_x, int to_y, int width, uint16_t color, uint8_t opacity);
bool widget_font_open(widget_font *font, const uint8_t *data, size_t size);
int widget_text_width(const widget_canvas *canvas, const char *text, int size);
int widget_text(widget_canvas *canvas, int x, int y, int width, int size, int max_lines,
                const char *text, uint16_t color, uint8_t opacity);
void widget_text_right(widget_canvas *canvas, int x, int y, int width, int size,
                       const char *text, uint16_t color, uint8_t opacity);
void widget_frost(widget_canvas *canvas, desk_rect rect, const uint32_t *grid, uint8_t rotation, bool dark);
