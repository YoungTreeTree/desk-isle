#pragma once

#include "esp_err.h"
#include "protocol.h"

esp_err_t desk_pet_receive(const desk_message *message, const desk_component *component);
void desk_pet_tick(const desk_component *component, int64_t now);
bool desk_pet_running(void);
void desk_pet_idle_input(void);
void desk_pet_reset(void);
