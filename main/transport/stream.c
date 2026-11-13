#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "driver/jpeg_decode.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tinyusb_cdc_acm.h"
#include "tusb.h"
#include "control.h"
#include "display.h"
#include "pet.h"
#include "model3d.h"
#include "protocol.h"
#include "uart_link.h"

#define SPEC_INTERVAL_US 1000000
#define LEASE_US ((int64_t)DESK_LEASE_MS * 1000)
#define NATIVE_GRACE_US ((int64_t)DESK_NATIVE_PET_GRACE_MS * 1000)
#define PARTIAL_TIMEOUT_US 2000000
#define UART_IDLE_US 15000000
#define PET_INPUT_SLOTS 16u
#define COMMAND_CAPACITY (PET_INPUT_SLOTS + 4)
#define SCENE_TICK_MS 5

static const char *TAG = "DESK_USB";
static TaskHandle_t receiver;
static TaskHandle_t scene;
static QueueHandle_t commands;
static SemaphoreHandle_t input_space;
static uint8_t *input_storage;
static unsigned next_input_slot;

enum stream_source { STREAM_OFF, STREAM_USB, STREAM_UART };

typedef struct {
    desk_parser parser;
    tinyusb_cdcacm_itf_t port;
    enum desk_uart_channel channel;
    SemaphoreHandle_t spare_ready;
    uint8_t *spare;
    atomic_uint generation;
    atomic_int source;
    int64_t last_rx;
} stream_session;

typedef struct {
    stream_session *session;
    desk_message message;
    unsigned generation;
    int64_t received_at;
} queued_message;

static stream_session animation = {.port = TINYUSB_CDC_ACM_0, .channel = DESK_UART_ANIMATION};
static stream_session settings = {.port = TINYUSB_CDC_ACM_1, .channel = DESK_UART_LAYOUT, .parser.controls = true};
static bool uart_ready;
static desk_uart_decoder uart_decoder;
static bool uart_has_token;
static uint16_t uart_last_token;
static uint8_t uart_last_channel;
static int64_t next_spec;
static int64_t pet_last_valid;
static bool pet_visible;
static bool animation_can_resume;
static bool pet_can_resume;
static bool pet_input_idle;
static unsigned pet_frames;
static uint8_t rx_chunk[4096];
static size_t wallpaper_length;
static uint32_t wallpaper_checksum;

static void hide_pet(void);

static bool session_connected(const stream_session *session)
{
    const int source = atomic_load(&session->source);
    return source == STREAM_UART || (source == STREAM_USB && tud_cdc_n_connected(session->port));
}

static void send_line(const stream_session *session, const char *line, int length)
{
    if (length <= 0) return;
    if (atomic_load(&session->source) == STREAM_UART) {
        uint8_t wire[2 * (DESK_UART_HEADER + 384 + DESK_UART_TRAILER) + 2];
        if (length <= 384) {
            const size_t size = desk_uart_encode(session->channel, 0, (const uint8_t *)line, length, wire);
            uart_write_bytes(UART_NUM_0, wire, size);
        }
        return;
    }
    const tinyusb_cdcacm_itf_t port = session->port;
    if (!tud_cdc_n_connected(port)) return;
    if (tud_cdc_n_write_available(port) < (size_t)length &&
        tinyusb_cdcacm_write_flush(port, pdMS_TO_TICKS(50)) != ESP_OK) return;
    if (tinyusb_cdcacm_write_queue(port, (const uint8_t *)line, length) == (size_t)length)
        tinyusb_cdcacm_write_flush(port, 0);
}

static void advertise_pet(void)
{
    const desk_component *pet = desk_layout_component(desk_control_layout(), DESK_PET_ID);
    if (!pet) return;
    char line[224];
    int length = snprintf(line, sizeof(line),
                          "DESKISLE_ALPHA 1 %u\n"
                          "DESKISLE_PET 1 %u %u %u %u\n"
                          "DESKISLE_PET 2 %u %u %u %u\n"
                          "DESKISLE_PET 3 %u %u %u %u\n"
                          "DESKISLE %u %u %u %u JPEG %u %u\n",
                          DESK_PET_ID, DESK_PET_ID, DESK_MAX_PET_PACK_LEGACY, DESK_MAX_PET_CHUNK, DESK_MAX_PET_INPUT,
                          DESK_PET_ID, DESK_MAX_PET_PACK, DESK_MAX_PET_CHUNK, DESK_MAX_PET_INPUT,
                          DESK_PET_ID, DESK_MAX_PET_PACK, DESK_MAX_PET_CHUNK, DESK_MAX_PET_INPUT,
                          DESK_PROTOCOL_VERSION, DESK_PET_ID, desk_jpeg_dimension(pet->rect.width),
                          desk_jpeg_dimension(pet->rect.height),
                          DESK_MAX_JPEG, DESK_LEASE_MS);
    if (length < (int)sizeof(line)) send_line(&animation, line, length);
}

static void reply_layout(const stream_session *session, uint32_t sequence, enum desk_layout_status status)
{
    const desk_layout *layout = desk_control_layout();
    char line[384];
    int length = snprintf(line, sizeof(line), "DESKISLE_LAYOUT 1 %" PRIu32 " %u %u %u %u %u %u %u %u",
                          sequence, status, DESK_LCD_WIDTH, DESK_LCD_HEIGHT, DESK_MAX_COMPONENTS,
                          DESK_MAX_COMPONENT_PIXELS, DESK_MAX_JPEG, layout->rotation, layout->count);
    for (unsigned i = 0; i < layout->count && length > 0 && length < (int)sizeof(line); ++i) {
        const desk_component *component = &layout->components[i];
        desk_rect rect = component->rect;
        length += snprintf(line + length, sizeof(line) - length, " %u %u %u %u %u",
                           component->id, rect.x, rect.y, rect.width, rect.height);
    }
    if (length > 0 && length < (int)sizeof(line)) {
        char capability[384];
        const desk_backlight backlight = desk_control_backlight();
        int capability_length = snprintf(capability, sizeof(capability),
                                         "DESKISLE_WIDGETS 1 %" PRIu32 "\n"
                                         "DESKISLE_WIDGETS 2 %" PRIu32 "\n"
                                         "DESKISLE_WIDGETS 3 %" PRIu32 "\n"
                                         "DESKISLE_GLYPHS 1 %" PRIu32 " %u\n"
                                         "DESKISLE_WALLPAPER 1 %" PRIu32 " %u %zu %" PRIu32 "\n"
                                         "DESKISLE_WALLPAPER_LANDSCAPE 1 %" PRIu32 "\n"
                                         "DESKISLE_PICTURE_ALPHA 1 %" PRIu32 "\n"
                                         "DESKISLE_BACKLIGHT 1 %" PRIu32 " %u %u\n",
                                         sequence, sequence, sequence, sequence, DESK_MAX_WIDGET_GLYPH_PACKET,
                                         sequence, DESK_MAX_WALLPAPER_JPEG, wallpaper_length, wallpaper_checksum,
                                         sequence, sequence, sequence, backlight.brightness, backlight.blanked);
        if (capability_length > 0 && capability_length < (int)sizeof(capability))
            send_line(session, capability, capability_length);
        char model[128];
        int model_length=snprintf(model,sizeof(model),"DESKISLE_3D 1 %"PRIu32" %u %u %u %"PRIu32"\n",
            sequence,DESK_MAX_MODEL3D_PACK,DESK_MAX_MODEL3D_CHUNK,(unsigned)desk_model3d_pack_size(),desk_model3d_pack_crc());
        if(model_length>0&&model_length<(int)sizeof(model))send_line(session,model,model_length);
        line[length++] = '\n';
        send_line(session, line, length);
    }
}

static void handle_message(const stream_session *session, const desk_message *message, int64_t started)
{
    if (message->kind == DESK_GET_LAYOUT || message->kind == DESK_SET_LAYOUT) {
        const desk_component *before = desk_layout_component(desk_control_layout(), DESK_PET_ID);
        const desk_rect previous_pet = before ? before->rect : (desk_rect){0};
        enum desk_layout_status status = DESK_LAYOUT_INVALID;
        if (message->checksum_ok) {
            status = message->kind == DESK_GET_LAYOUT ? desk_control_status()
                                                     : desk_control_apply(message->data, message->length);
        }
        desk_model3d_layout(desk_layout_component(desk_control_layout(),DESK_MODEL3D_ID));
        reply_layout(session, message->sequence, status);
        const desk_component *pet = desk_layout_component(desk_control_layout(), DESK_PET_ID);
        if (!pet) {
            hide_pet();
            // A full-screen 3D scene should not retain an unused 8 MiB pet atlas.
            // Keep the reservation only for skin changes within a pet layout.
            desk_pet_release();
        } else if (pet->rect.width != previous_pet.width || pet->rect.height != previous_pet.height) {
            pet_visible = desk_pet_running();
            advertise_pet();
            next_spec = esp_timer_get_time() + SPEC_INTERVAL_US;
        }
        return;
    }

    const desk_component *component = desk_layout_component(desk_control_layout(), message->id);
    desk_ack_status status = DESK_ACK_OK;
    if (!message->checksum_ok) {
        status = DESK_ACK_CHECKSUM;
    } else if (message->kind == DESK_SET_BACKLIGHT) {
        const desk_backlight next = {.brightness = message->data[0], .blanked = message->data[1] != 0};
        if (next.brightness > DESK_BACKLIGHT_MAX || message->data[1] > 1) status = DESK_ACK_DIMENSIONS;
        else if (desk_control_set_backlight(next) != ESP_OK) status = DESK_ACK_DISPLAY;
    } else if (message->kind == DESK_SET_WALLPAPER) {
        esp_err_t result = desk_display_set_wallpaper(message->data, message->length, message->width, message->height);
        if (result == ESP_OK) {
            wallpaper_length = message->length;
            wallpaper_checksum = message->checksum;
            ESP_LOGI(TAG, "WALLPAPER_READY bytes=%zu crc=%" PRIu32, wallpaper_length, wallpaper_checksum);
        } else {
            status = DESK_ACK_DISPLAY;
            ESP_LOGW(TAG, "Wallpaper rejected: %s", esp_err_to_name(result));
        }
    } else if (message->kind == DESK_PET_CLEAR) {
        hide_pet();
    } else if (!component) {
        status = DESK_ACK_DIMENSIONS;
    } else if (message->kind>=DESK_MODEL3D_BEGIN&&message->kind<=DESK_MODEL3D_ABORT) {
        esp_err_t result=desk_model3d_receive(message,component);
        if(result!=ESP_OK){status=DESK_ACK_MODEL3D;ESP_LOGW(TAG,"Model command %u: %s",message->kind,esp_err_to_name(result));}
        else if(message->kind==DESK_MODEL3D_STATS){
            char stats[384];int n=desk_model3d_profile(stats,sizeof(stats),message->sequence);
            if(n>0&&n<(int)sizeof(stats))send_line(session,stats,n);
            n=desk_model3d_stats(stats,sizeof(stats),message->sequence);
            if(n>0&&n<(int)sizeof(stats))send_line(session,stats,n);
        }
    } else if (message->kind == DESK_PET_RESUME) {
        animation_can_resume = true;
        if (desk_pet_receive(message, component) == ESP_OK) {
            pet_can_resume = true;
        } else {
            status = DESK_ACK_PET_MISSING;
        }
    } else if (message->kind == DESK_PET_INPUT && !desk_pet_running()) {
        status = DESK_ACK_PET_MISSING;
    } else if (message->kind >= DESK_PET_BEGIN && message->kind <= DESK_PET_INPUT) {
        esp_err_t result = desk_pet_receive(message, component);
        if (result != ESP_OK) {
            status = DESK_ACK_PET;
            ESP_LOGW(TAG, "Native pet message %u: %s", message->kind, esp_err_to_name(result));
        } else if (message->kind == DESK_PET_COMMIT) {
            pet_visible = true;
            pet_can_resume = animation_can_resume;
            pet_input_idle = false;
        } else if (message->kind == DESK_PET_INPUT) {
            pet_input_idle = false;
        }
    } else if (message->kind == DESK_WIDGET_DATA || message->kind == DESK_WIDGET_GLYPH_DATA) {
        bool has_glyphs = message->kind == DESK_WIDGET_GLYPH_DATA;
        esp_err_t result = desk_display_widget_update(message->id, message->data, message->length, has_glyphs);
        if (result == ESP_ERR_NOT_SUPPORTED) status = DESK_ACK_DIMENSIONS;
        else if (result == ESP_ERR_INVALID_ARG) status = DESK_ACK_WIDGET_DATA;
        else if (result != ESP_OK) status = DESK_ACK_DISPLAY;
        else ESP_LOGI(TAG, "WIDGET_DATA_OK id=%u bytes=%u exact=%u", message->id, (unsigned)message->length, has_glyphs);
    } else if (message->kind == DESK_KEEPALIVE) {
        if (!pet_visible) status = DESK_ACK_DISPLAY;
    } else if (message->width != desk_jpeg_dimension(component->rect.width) ||
               message->height != desk_jpeg_dimension(component->rect.height)) {
        status = DESK_ACK_DIMENSIONS;
    } else {
        desk_frame_data frame;
        esp_err_t result = desk_frame_payload(message, &frame) ? desk_display_frame(message->id, &frame)
                                                              : ESP_ERR_INVALID_SIZE;
        if (message->id == DESK_PET_ID && (result == ESP_OK || result == ESP_ERR_TIMEOUT)) {
            desk_pet_reset();
            pet_can_resume = false;
            pet_visible = true;
        }
        if (result != ESP_OK) {
            status = DESK_ACK_DISPLAY;
            ESP_LOGW(TAG, "FRAME_FAILED id=%u seq=%" PRIu32 " error=%s",
                     message->id, message->sequence, esp_err_to_name(result));
        }
    }
    const int64_t completed = esp_timer_get_time();
    if (status == DESK_ACK_OK && message->id == DESK_PET_ID) pet_last_valid = completed;

    char line[96];
    int length = snprintf(line, sizeof(line), "DESKISLE_ACK %" PRIu32 " %u %" PRId64 "\n",
                          message->sequence, status, (completed - started) / 1000);
    if (length < (int)sizeof(line)) send_line(session, line, length);
    if (status == DESK_ACK_OK && message->id == DESK_PET_ID &&
        (message->kind == DESK_FRAME || message->kind == DESK_ALPHA_FRAME) && ++pet_frames % 100 == 1) {
        ESP_LOGI(TAG, "CARD_FRAME_OK seq=%" PRIu32 " frames=%u bytes=%u", message->sequence, pet_frames, (unsigned)message->length);
    }
}

static void queue_message(void *context, const desk_message *message)
{
    stream_session *session = context;
    queued_message queued = {
        .session = session, .message = *message,
        .generation = atomic_load(&session->generation), .received_at = esp_timer_get_time(),
    };
    if (!message->length || !message->checksum_ok) {
        queued.message.data = NULL;
    } else if (message->kind == DESK_PET_INPUT) {
        // The FIFO returns slots in the same order in which we fill them.
        xSemaphoreTake(input_space, portMAX_DELAY);
        uint8_t *slot = input_storage + next_input_slot * DESK_MAX_PET_INPUT;
        next_input_slot = (next_input_slot + 1) % PET_INPUT_SLOTS;
        memcpy(slot, message->data, message->length);
        queued.message.data = slot;
    } else {
        // Transfer the aligned payload buffer without copying images or wallpaper.
        // The host waits for an ACK before sending another large command.
        xSemaphoreTake(session->spare_ready, portMAX_DELAY);
        session->parser.payload = session->spare;
        session->spare = NULL;
    }
    xQueueSend(commands, &queued, portMAX_DELAY);
    xTaskNotifyGive(scene);
}

static void release_message(const queued_message *queued)
{
    if (!queued->message.data) return;
    if (queued->message.kind == DESK_PET_INPUT) {
        xSemaphoreGive(input_space);
    } else {
        queued->session->spare = (uint8_t *)queued->message.data;
        xSemaphoreGive(queued->session->spare_ready);
    }
}

static void receive_callback(int port, cdcacm_event_t *event)
{
    if (receiver) xTaskNotifyGive(receiver);
}

static void reset_session(stream_session *session, enum stream_source source)
{
    desk_parser_reset(&session->parser);
    atomic_fetch_add(&session->generation, 1);
    atomic_store(&session->source, source);
    xTaskNotifyGive(scene);
}

static void poll_usb(stream_session *session)
{
    const int source = atomic_load(&session->source);
    if (!tud_cdc_n_connected(session->port)) {
        if (source == STREAM_USB) {
            reset_session(session, STREAM_OFF);
            tud_cdc_n_read_flush(session->port);
        }
        return;
    }
    if (source != STREAM_USB) reset_session(session, STREAM_USB);
    // Bound work per port so layout requests and animation frames both get serviced.
    for (unsigned i = 0; i < 8; ++i) {
        size_t length = 0;
        esp_err_t result = tinyusb_cdcacm_read(session->port, rx_chunk, sizeof(rx_chunk), &length);
        if (result != ESP_OK || !length) break;
        session->last_rx = esp_timer_get_time();
        desk_parser_feed(&session->parser, rx_chunk, length);
    }
}

static void receive_uart(uint8_t channel, uint16_t token, const uint8_t *data, size_t length)
{
    if (channel == DESK_UART_RECEIVED) return;
    stream_session *session = channel == DESK_UART_ANIMATION ? &animation : &settings;
    if (tud_cdc_n_connected(session->port)) return;
    const bool active = atomic_load(&session->source) == STREAM_UART;
    if (!active && length) return;
    session->last_rx = esp_timer_get_time();
    const bool duplicate = active && uart_has_token && token == uart_last_token && channel == uart_last_channel;
    if (!duplicate) {
        if (length) desk_parser_feed(&session->parser, data, length);
        else reset_session(session, STREAM_UART);
        uart_has_token = true;
        uart_last_token = token;
        uart_last_channel = channel;
    }

    // A credit lets the Mac send one more fragment after this one reached the parser.
    uint8_t wire[2 * (DESK_UART_HEADER + DESK_UART_TRAILER) + 2];
    const size_t size = desk_uart_encode(DESK_UART_RECEIVED, token, NULL, 0, wire);
    uart_write_bytes(UART_NUM_0, wire, size);
}

static void expire_session(stream_session *session, int64_t now)
{
    if (atomic_load(&session->source) == STREAM_UART && now - session->last_rx >= UART_IDLE_US) {
        reset_session(session, STREAM_OFF);
    }
    if (session->parser.header_used && now - session->last_rx >= PARTIAL_TIMEOUT_US) {
        desk_parser_reset(&session->parser);
    }
}

static void stream_task(void *arg)
{
    for (;;) {
        const int64_t now = esp_timer_get_time();
        expire_session(&animation, now);
        expire_session(&settings, now);
        poll_usb(&animation);
        poll_usb(&settings);
        if (uart_ready) {
            for (unsigned i = 0; i < 4; ++i) {
                int length = uart_read_bytes(UART_NUM_0, rx_chunk, sizeof(rx_chunk), 0);
                if (length <= 0) break;
                desk_uart_feed(&uart_decoder, rx_chunk, length, receive_uart);
            }
        }
        const bool using_uart = atomic_load(&animation.source) == STREAM_UART ||
                                atomic_load(&settings.source) == STREAM_UART;
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(using_uart ? 3 : 10));
    }
}

static void hide_pet(void)
{
    desk_pet_reset();
    pet_can_resume = false;
    pet_input_idle = false;
    if (pet_visible) {
        desk_display_hide_component(DESK_PET_ID);
        pet_visible = false;
        ESP_LOGI(TAG, "CARD_HIDDEN");
    }
}

static void idle_pet_input(void)
{
    if (pet_input_idle) return;
    desk_pet_idle_input();
    pet_input_idle = true;
}

static void sync_animation(unsigned generation)
{
    static unsigned seen;
    if (seen != generation) {
        seen = generation;
        next_spec = 0;
        animation_can_resume = false;
        if (pet_can_resume && desk_pet_running()) idle_pet_input();
        else hide_pet();
    }
}

static void scene_task(void *arg)
{
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    for (;;) {
        queued_message queued;
        // Catch up on all queued input before spending time on another frame.
        // The queue capacity bounds this pass even with a continuous sender.
        for (unsigned i = 0; i < COMMAND_CAPACITY && xQueueReceive(commands, &queued, 0) == pdTRUE; ++i) {
            const unsigned generation = atomic_load(&queued.session->generation);
            if (queued.session == &animation) sync_animation(generation);
            if (queued.generation == generation && session_connected(queued.session)) {
                handle_message(queued.session, &queued.message, queued.received_at);
            }
            release_message(&queued);
        }
        sync_animation(atomic_load(&animation.generation));
        const int64_t now = esp_timer_get_time();
        const bool pet_connected = session_connected(&animation);
        if (pet_visible && (!pet_connected || now - pet_last_valid >= LEASE_US)) {
            if (pet_can_resume && desk_pet_running() && now - pet_last_valid < NATIVE_GRACE_US) idle_pet_input();
            else hide_pet();
        }
        if (!pet_connected) {
            next_spec = 0;
        } else if (now >= next_spec) {
            advertise_pet();
            next_spec = now + SPEC_INTERVAL_US;
        }
        desk_pet_tick(desk_layout_component(desk_control_layout(), DESK_PET_ID), esp_timer_get_time());
        desk_model3d_tick(desk_layout_component(desk_control_layout(), DESK_MODEL3D_ID), esp_timer_get_time());
        desk_display_tick();
        desk_control_tick();
        if (!uxQueueMessagesWaiting(commands)) ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(SCENE_TICK_MS));
    }
}

static esp_err_t init_session(stream_session *session)
{
    const tinyusb_config_cdcacm_t cdc = {
        .cdc_port = session->port, .callback_rx = receive_callback, .callback_line_state_changed = receive_callback,
    };
    return tinyusb_cdcacm_init(&cdc);
}

static bool prepare_session(stream_session *session)
{
    const jpeg_decode_memory_alloc_cfg_t input = {.buffer_direction = JPEG_DEC_ALLOC_INPUT_BUFFER};
    size_t capacity;
    size_t maximum = session->parser.controls ? DESK_MAX_WALLPAPER_JPEG : DESK_MAX_ALPHA_FRAME;
    session->parser.payload = jpeg_alloc_decoder_mem(maximum, &input, &capacity);
    session->spare = jpeg_alloc_decoder_mem(maximum, &input, &capacity);
    session->spare_ready = xSemaphoreCreateBinary();
    if (!session->parser.payload || !session->spare || !session->spare_ready) return false;
    session->parser.payload_capacity = maximum;
    session->parser.on_message = queue_message;
    session->parser.context = session;
    xSemaphoreGive(session->spare_ready);
    return true;
}

static void free_session(stream_session *session)
{
    free(session->parser.payload);
    free(session->spare);
    if (session->spare_ready) vSemaphoreDelete(session->spare_ready);
}

static bool start_uart(void)
{
    const uart_port_t port = UART_NUM_0;
    fflush(stdout);
    esp_err_t result = uart_driver_install(port, 8192, 2048, 0, NULL, 0);
    if (result == ESP_OK) {
        result = uart_set_rx_full_threshold(port, 64);
        if (result == ESP_OK) result = uart_set_baudrate(port, DESK_UART_BAUD);
        if (result == ESP_OK) {
            uart_vfs_dev_use_driver(port);
            ESP_LOGI(TAG, "DESK_UART_READY baud=%d", DESK_UART_BAUD);
            return true;
        }
        uart_driver_delete(port);
    }
    ESP_LOGW(TAG, "UART unavailable: %s", esp_err_to_name(result));
    return false;
}

static esp_err_t stream_start(void)
{
    commands = xQueueCreate(COMMAND_CAPACITY, sizeof(queued_message));
    input_space = xSemaphoreCreateCounting(PET_INPUT_SLOTS, PET_INPUT_SLOTS);
    input_storage = heap_caps_malloc(PET_INPUT_SLOTS * DESK_MAX_PET_INPUT, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    esp_err_t result = ESP_ERR_NO_MEM;
    if (commands && input_space && input_storage && prepare_session(&animation) && prepare_session(&settings)) {
        tinyusb_config_t config = TINYUSB_DEFAULT_CONFIG();
        desk_control_usb_config(&config.descriptor);
        result = tinyusb_driver_install(&config);
        if (result == ESP_OK) {
            result = init_session(&animation);
            if (result == ESP_OK) result = init_session(&settings);
            if (result == ESP_OK &&
                xTaskCreatePinnedToCore(scene_task, "desk_scene", 12288, NULL, 5, &scene, DESK_DISPLAY_CORE) != pdPASS) {
                result = ESP_ERR_NO_MEM;
            }
            if (result == ESP_OK) {
                uart_ready = start_uart();
                if (xTaskCreatePinnedToCore(stream_task, "desk_usb", 6144, NULL, 4, &receiver,
                                            TINYUSB_DEFAULT_TASK_AFFINITY) != pdPASS) result = ESP_ERR_NO_MEM;
            }
            if (result != ESP_OK) tinyusb_driver_uninstall();
        }
    }
    if (result != ESP_OK) {
        if (uart_ready) {
            uart_vfs_dev_use_nonblocking(UART_NUM_0);
            uart_set_baudrate(UART_NUM_0, CONFIG_ESP_CONSOLE_UART_BAUDRATE);
            uart_driver_delete(UART_NUM_0);
        }
        if (scene) vTaskDelete(scene);
        free_session(&animation);
        free_session(&settings);
        free(input_storage);
        if (input_space) vSemaphoreDelete(input_space);
        if (commands) vQueueDelete(commands);
    } else {
        xTaskNotifyGive(scene);
    }
    return result;
}

void app_main(void)
{
    const desk_layout initial = desk_control_init();
    ESP_ERROR_CHECK(desk_display_init(initial, desk_control_backlight().brightness));
    esp_err_t result = stream_start();
    if (result == ESP_OK) {
        ESP_LOGI(TAG, "DESK_USB_READY protocol=%u", DESK_PROTOCOL_VERSION);
    } else {
        ESP_LOGE(TAG, "USB unavailable: %s", esp_err_to_name(result));
    }
}
