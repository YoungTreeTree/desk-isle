#pragma once
#include "protocol.h"
#include "esp_err.h"
esp_err_t desk_model3d_receive(const desk_message *message,const desk_component *component);
void desk_model3d_layout(const desk_component *component);
void desk_model3d_tick(const desk_component *component,int64_t now);
size_t desk_model3d_pack_size(void);
uint32_t desk_model3d_pack_crc(void);
int desk_model3d_stats(char *line,size_t capacity,uint32_t sequence);
int desk_model3d_profile(char *line,size_t capacity,uint32_t sequence);
