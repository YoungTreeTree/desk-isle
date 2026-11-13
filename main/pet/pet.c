#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lauxlib.h"
#include "lualib.h"
#include "display.h"
#include "pet.h"
#include "pet_scene.h"

#define PSRAM (MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)
#define MAX_ASSETS 32
#define LUA_BUDGET (4u * 1024u * 1024u)
#define FRAME_US 33333

static const char *TAG = "DESK_PET";
static const char callbacks_key, modules_key, input_key;

typedef struct {
    size_t size, used;
    uint32_t crc;
} pet_upload;

typedef struct {
    const uint8_t *bytes;
    pet_asset assets[MAX_ASSETS];
    unsigned count;
    char id[64], entry[80];
    lua_State *L;
    pet_scene *scene;
    size_t lua_used;
    int64_t deadline, last_step, last_paint, input_at;
    double input_time, frame_time;
    size_t pack_size;
    uint32_t pack_crc;
    uint32_t rng;
    uint16_t width, height;
    unsigned frames;
    bool logged_keys, logged_beats;
} pet_runtime;

static pet_upload upload;
static pet_runtime *active;
static uint8_t *pack_storage;

static unsigned u16(const uint8_t *p)
{
    return p[0] | (unsigned)p[1] << 8;
}

static uint32_t u32(const uint8_t *p)
{
    return u16(p) | (uint32_t)u16(p + 2) << 16;
}

static void destroy(pet_runtime *pet)
{
    if (!pet) return;
    if (pet->L) lua_close(pet->L);
    pet_scene_destroy(pet->scene);
    free(pet);
}

static void discard_upload(void)
{
    upload = (pet_upload){0};
}

void desk_pet_reset(void)
{
    destroy(active);
    active = NULL;
    discard_upload();
}

void desk_pet_release(void)
{
    desk_pet_reset();
    free(pack_storage);
    pack_storage = NULL;
}

bool desk_pet_running(void)
{
    return active != NULL;
}

static bool json_depth_ok(const uint8_t *data, size_t length)
{
    unsigned depth = 0;
    bool quoted = false;
    for (size_t i = 0; i < length; ++i) {
        if (quoted && data[i] == '\\') {
            ++i;
        } else if (data[i] == '"') {
            quoted = !quoted;
        } else if (!quoted && (data[i] == '{' || data[i] == '[')) {
            if (++depth > 12) return false;
        } else if (!quoted && (data[i] == '}' || data[i] == ']')) {
            if (!depth) return false;
            --depth;
        }
    }
    return depth == 0 && !quoted;
}

static cJSON *parse_object(const uint8_t *data, size_t size)
{
    if (!json_depth_ok(data, size)) return NULL;
    const char *end, *limit = (const char *)data + size;
    cJSON *value = cJSON_ParseWithLengthOpts((const char *)data, size, &end, false);
    if (value) {
        while (end < limit && (*end == ' ' || *end == '\r' || *end == '\n' || *end == '\t')) ++end;
        if (end == limit && cJSON_IsObject(value)) return value;
    }
    cJSON_Delete(value);
    return NULL;
}

static const pet_asset *asset(const pet_runtime *pet, const char *name, unsigned kind)
{
    for (unsigned i = 0; i < pet->count; ++i) {
        if (pet->assets[i].kind == kind && !strcmp(pet->assets[i].name, name)) return &pet->assets[i];
    }
    return NULL;
}

static bool read_manifest(pet_runtime *pet)
{
    const pet_asset *file = asset(pet, "manifest.json", PET_MANIFEST);
    if (!file) return false;
    cJSON *manifest = parse_object(file->data, file->size);
    if (!manifest) return false;
    const cJSON *api = cJSON_GetObjectItemCaseSensitive(manifest, "api");
    const char *id = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(manifest, "id"));
    const char *entry = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(manifest, "entry"));
    bool valid = cJSON_IsNumber(api) && api->valuedouble == 1 && id && *id && strlen(id) < sizeof(pet->id) &&
                 entry && asset(pet, entry, PET_SOURCE);
    if (valid) {
        strcpy(pet->id, id);
        strcpy(pet->entry, entry);
    }
    cJSON_Delete(manifest);
    return valid;
}

static bool valid_image(const uint8_t *p, size_t length)
{
    if (length < 8) return false;
    unsigned ow = u16(p), oh = u16(p + 2), w = u16(p + 4), h = u16(p + 6);
    return w && h && w <= ow && h <= oh && ow <= 4096 && oh <= 4096 &&
           length == 8 + (size_t)w*h*4;
}

static bool unpack(pet_runtime *pet, size_t size)
{
    if (size < 4 || memcmp(pet->bytes, "PET1", 4)) return false;
    const uint8_t *p = pet->bytes + 4, *end = pet->bytes + size;
    while (p < end) {
        if (end - p < 8 || pet->count >= MAX_ASSETS) return false;
        unsigned kind = p[0], name_size = p[1];
        size_t length = u32(p + 4);
        if (p[2] || p[3] || !name_size || name_size >= sizeof(pet->assets[0].name)) return false;
        p += 8;
        if ((size_t)(end - p) < name_size || length > (size_t)(end - p) - name_size) return false;

        pet_asset *out = &pet->assets[pet->count];
        for (unsigned i = 0; i < name_size; ++i) {
            if (p[i] < 32 || p[i] > 126) return false;
        }
        memcpy(out->name, p, name_size);
        for (unsigned i = 0; i < pet->count; ++i)
            if (!strcmp(out->name, pet->assets[i].name)) return false;
        p += name_size;
        bool valid = (kind == PET_SOURCE && length && length <= 64u*1024u) ||
                     (kind == PET_IMAGE && valid_image(p, length)) ||
                     (kind == PET_FONT && length == 95u*PET_GLYPH_BYTES) ||
                     (kind == PET_MANIFEST && length && length <= 4096);
        if (!valid) return false;
        out->kind = kind;
        out->size = length;
        out->data = p;
        ++pet->count;
        p += length;
    }
    return read_manifest(pet);
}

static void *lua_memory(void *context, void *p, size_t previous, size_t size)
{
    pet_runtime *pet = context;
    if (!p) previous = 0;
    if (!size) {
        free(p);
        pet->lua_used -= previous;
        return NULL;
    }
    if (size > LUA_BUDGET - (pet->lua_used - previous)) return NULL;
    void *out = heap_caps_realloc(p, size, PSRAM);
    if (out) pet->lua_used = pet->lua_used - previous + size;
    return out;
}

static pet_runtime *runtime(lua_State *L)
{
    return *(pet_runtime **)lua_getextraspace(L);
}

static void deadline_hook(lua_State *L, lua_Debug *debug)
{
    (void)debug;
    if (esp_timer_get_time() >= runtime(L)->deadline) luaL_error(L, "Lua time budget exceeded");
}

static void load_source(lua_State *L, const char *name)
{
    const pet_asset *file = asset(runtime(L), name, PET_SOURCE);
    if (!file) luaL_error(L, "Missing Lua module %s", name);
    if (luaL_loadbufferx(L, (const char *)file->data, file->size, name, "t") != LUA_OK) lua_error(L);
    lua_call(L, 0, 1);
}

static int require_module(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &modules_key);
    lua_getfield(L, -1, name);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        load_source(L, name);
        lua_pushvalue(L, -1);
        lua_setfield(L, -3, name);
    }
    return 1;
}

static int load_scene(lua_State *L)
{
    pet_scene_load(runtime(L)->scene, L);
    return 0;
}

static int update_scene(lua_State *L)
{
    pet_scene_set(runtime(L)->scene, L);
    return 0;
}

static int random_value(lua_State *L)
{
    pet_runtime *pet = runtime(L);
    pet->rng = pet->rng*1664525u + 1013904223u;
    lua_pushnumber(L, pet->rng / 4294967296.0);
    return 1;
}

static bool callback(lua_State *L, const char *name)
{
    lua_rawgetp(L, LUA_REGISTRYINDEX, &callbacks_key);
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
    if (!lua_isnil(L, -1)) return true;
    lua_pop(L, 1);
    return false;
}

static void field(lua_State *L, const char *key, lua_Number number)
{
    lua_pushnumber(L, number);
    lua_setfield(L, -2, key);
}

static int init_runtime(lua_State *L)
{
    const luaL_Reg libraries[] = {
        {"_G", luaopen_base}, {LUA_MATHLIBNAME, luaopen_math}, {LUA_TABLIBNAME, luaopen_table},
        {LUA_STRLIBNAME, luaopen_string}, {LUA_UTF8LIBNAME, luaopen_utf8}, {NULL, NULL},
    };
    for (const luaL_Reg *lib = libraries; lib->name; ++lib) {
        luaL_requiref(L, lib->name, lib->func, 1);
        lua_pop(L, 1);
    }
    const char *disabled[] = {"dofile", "loadfile", "load", "collectgarbage", "print", "warn", "pcall", "xpcall"};
    for (unsigned i = 0; i < sizeof(disabled) / sizeof(*disabled); ++i) {
        lua_pushnil(L);
        lua_setglobal(L, disabled[i]);
    }
    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &modules_key);
    const luaL_Reg api[] = {{"load", load_scene}, {"set", update_scene},
                            {"require", require_module}, {"random", random_value}, {NULL, NULL}};
    luaL_newlib(L, api);
    lua_setglobal(L, "miucs");

    pet_runtime *pet = runtime(L);
    load_source(L, pet->entry);
    luaL_checktype(L, -1, LUA_TTABLE);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &callbacks_key);
    if (callback(L, "create")) {
        lua_createtable(L, 0, 2);
        field(L, "api", 1);
        field(L, "seed", pet->rng);
        lua_call(L, 1, 0);
    }
    if (!pet_scene_dirty(pet->scene)) return luaL_error(L, "No pet scene created");
    if (callback(L, "activate")) {
        lua_createtable(L, 0, 4);
        lua_pushstring(L, pet->id);
        lua_setfield(L, -2, "id");
        field(L, "width", pet->width);
        field(L, "height", pet->height);
        field(L, "scale", 1);
        lua_call(L, 1, 0);
    }
    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &input_key);
    // Scene construction creates large temporary Lua path tables. Reclaim them before
    // switching to the frame budget, then keep short-lived input tables in the young generation.
    lua_gc(L, LUA_GCGEN, 0, 0);
    return 0;
}

static void to_lua(lua_State *L, const cJSON *item)
{
    if (cJSON_IsObject(item) || cJSON_IsArray(item)) {
        luaL_checkstack(L, 4, "Pet input nested too deeply");
        bool array = cJSON_IsArray(item);
        lua_createtable(L, array ? cJSON_GetArraySize(item) : 0, array ? 0 : cJSON_GetArraySize(item));
        int index = 0;
        for (const cJSON *value = item->child; value; value = value->next) {
            to_lua(L, value);
            if (array) lua_rawseti(L, -2, ++index);
            else lua_setfield(L, -2, value->string);
        }
    } else if (cJSON_IsString(item)) lua_pushstring(L, item->valuestring);
    else if (cJSON_IsNumber(item) && isfinite(item->valuedouble)) lua_pushnumber(L, item->valuedouble);
    else if (cJSON_IsBool(item)) lua_pushboolean(L, cJSON_IsTrue(item));
    else lua_pushnil(L);
}

typedef struct {
    const cJSON *input;
    double now, dt;
} update_call;

static void clear_events(lua_State *L, const char *name)
{
    lua_getfield(L, -1, name);
    bool has_events = lua_istable(L, -1) && lua_rawlen(L, -1) > 0;
    lua_pop(L, 1);
    if (has_events) {
        lua_newtable(L);
        lua_setfield(L, -2, name);
    }
}

static void age_field(lua_State *L, const char *name, double elapsed)
{
    lua_getfield(L, -1, name);
    bool exists = lua_isnumber(L, -1);
    double age = lua_tonumber(L, -1);
    lua_pop(L, 1);
    if (exists) field(L, name, age + elapsed);
}

static void advance_input(lua_State *L, double now)
{
    lua_getfield(L, -1, "now");
    double elapsed = fmax(0, now - lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, -1, "keyboard");
    if (lua_istable(L, -1)) {
        clear_events(L, "events");
        age_field(L, "idleDuration", elapsed);
    }
    lua_pop(L, 1);
    lua_getfield(L, -1, "audio");
    if (lua_istable(L, -1)) {
        clear_events(L, "beats");
        clear_events(L, "onsets");
        field(L, "spectralFluxPeak", 0);
        age_field(L, "frameAge", elapsed);
    }
    lua_pop(L, 1);
}

static int invoke_update(lua_State *L)
{
    const update_call *call = lua_touserdata(L, 1);
    if (!callback(L, "update")) return 0;
    if (call->input) {
        to_lua(L, call->input);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &input_key);
    }
    lua_rawgetp(L, LUA_REGISTRYINDEX, &input_key);
    // An idle tick advances continuous state without replaying the last packet's events.
    if (!call->input) advance_input(L, call->now);
    field(L, "now", call->now);
    field(L, "deltaTime", call->dt);
    lua_call(L, 1, 0);
    return 0;
}

static bool call_lua(pet_runtime *pet, lua_CFunction fn, void *argument, int64_t limit)
{
    lua_State *L = pet->L;
    pet->deadline = esp_timer_get_time() + limit;
    lua_sethook(L, deadline_hook, LUA_MASKCOUNT, 1000);
    lua_pushcfunction(L, fn);
    lua_pushlightuserdata(L, argument);
    int status = lua_pcall(L, 1, 0, 0);
    lua_sethook(L, NULL, 0, 0);
    if (status == LUA_OK) return true;
    const char *error = lua_tostring(L, -1);
    ESP_LOGW(TAG, "Native pet rejected: %s", error ? error : "Lua error");
    lua_pop(L, 1);
    return false;
}

static bool step(pet_runtime *pet, int64_t now, const cJSON *input)
{
    double time = pet->input_time + (now - pet->input_at)/1000000.0;
    update_call call = {.input = input, .now = fmax(time, pet->frame_time), .dt = (now - pet->last_step)/1000000.0};
    if (!call_lua(pet, invoke_update, &call, 40000)) return false;
    pet->last_step = now;
    pet->frame_time = call.now;
    return true;
}

void desk_pet_idle_input(void)
{
    static const cJSON idle = {.type = cJSON_Object};
    if (active && !step(active, esp_timer_get_time(), &idle)) desk_pet_reset();
}

static esp_err_t commit(const desk_component *component)
{
    if (!upload.size || upload.used != upload.size || desk_crc32(pack_storage, upload.size) != upload.crc) {
        discard_upload();
        return ESP_ERR_INVALID_CRC;
    }
    pet_runtime *candidate = heap_caps_calloc(1, sizeof(*candidate), PSRAM);
    if (!candidate) {
        discard_upload();
        return ESP_ERR_NO_MEM;
    }
    size_t size = upload.size;
    candidate->bytes = pack_storage;
    candidate->pack_size = size;
    candidate->pack_crc = upload.crc;
    candidate->rng = upload.crc;
    candidate->width = component->rect.width;
    candidate->height = component->rect.height;
    upload = (pet_upload){0};
    esp_err_t result = ESP_ERR_INVALID_ARG;
    if (unpack(candidate, size)) {
        candidate->scene = pet_scene_create(candidate->assets, candidate->count);
        if (candidate->scene) candidate->L = lua_newstate(lua_memory, candidate);
        if (candidate->L) {
            *(pet_runtime **)lua_getextraspace(candidate->L) = candidate;
            if (call_lua(candidate, init_runtime, NULL, 2000000)) {
                result = desk_display_paint_pet(pet_scene_paint, candidate->scene);
                if (result == ESP_OK) result = desk_display_flush();
            }
        }
    }
    if (result != ESP_OK) {
        destroy(candidate);
        return result;
    }
    active = candidate;
    active->input_at = active->last_step = active->last_paint = esp_timer_get_time();
    ESP_LOGI(TAG, "NATIVE_PET_READY %s bytes=%zu assets=%u lua=%zu", active->id, size, active->count, active->lua_used);
    return ESP_OK;
}

static esp_err_t accept_input(const desk_message *message)
{
    if (!active) return ESP_ERR_INVALID_STATE;
    cJSON *input = parse_object(message->data, message->length);
    if (!input) return ESP_ERR_INVALID_ARG;
    const cJSON *time = cJSON_GetObjectItemCaseSensitive(input, "now");
    if (!cJSON_IsNumber(time) || !isfinite(time->valuedouble) || time->valuedouble < 0) {
        cJSON_Delete(input);
        return ESP_ERR_INVALID_ARG;
    }
    const cJSON *keyboard = cJSON_GetObjectItemCaseSensitive(input, "keyboard");
    const cJSON *audio = cJSON_GetObjectItemCaseSensitive(input, "audio");
    int keys = cJSON_GetArraySize(cJSON_GetObjectItemCaseSensitive(keyboard, "events"));
    int beats = cJSON_GetArraySize(cJSON_GetObjectItemCaseSensitive(audio, "beats"));
    active->input_at = esp_timer_get_time();
    active->input_time = time->valuedouble;
    bool success = step(active, active->input_at, input);
    cJSON_Delete(input);
    if (!success) {
        desk_pet_reset();
        return ESP_FAIL;
    }
    if ((keys && !active->logged_keys) || (beats && !active->logged_beats)) {
        active->logged_keys |= keys > 0;
        active->logged_beats |= beats > 0;
        ESP_LOGI(TAG, "NATIVE_PET_INPUT keys=%d beats=%d bytes=%zu", keys, beats, message->length);
    }
    return ESP_OK;
}

esp_err_t desk_pet_receive(const desk_message *message, const desk_component *component)
{
    const uint8_t *data = message->data;
    switch (message->kind) {
    case DESK_PET_BEGIN: {
        size_t size = u32(data);
        if (size < 4 || size > DESK_MAX_PET_PACK) return ESP_ERR_INVALID_SIZE;
        // Reserve once on first use so repeated switches do not need a new
        // contiguous allocation for every atlas. The LCD keeps the old pixels.
        if (!pack_storage) pack_storage = heap_caps_malloc(DESK_MAX_PET_PACK, PSRAM);
        if (!pack_storage) return ESP_ERR_NO_MEM;
        desk_pet_reset();
        upload.size = size;
        upload.crc = u32(data + 4);
        return ESP_OK;
    }
    case DESK_PET_CHUNK: {
        size_t length = message->length - 4;
        if (!upload.size || u32(data) != upload.used || length > upload.size - upload.used) {
            discard_upload();
            return ESP_ERR_INVALID_SIZE;
        }
        memcpy(pack_storage + upload.used, data + 4, length);
        upload.used += length;
        return ESP_OK;
    }
    case DESK_PET_COMMIT:
        return commit(component);
    case DESK_PET_INPUT:
        return accept_input(message);
    case DESK_PET_RESUME:
        return active && active->pack_size == u32(data) && active->pack_crc == u32(data + 4)
            ? ESP_OK : ESP_ERR_NOT_FOUND;
    default:
        return ESP_ERR_NOT_SUPPORTED;
    }
}

void desk_pet_tick(const desk_component *component, int64_t now)
{
    if (!active) return;
    if (!component || (now - active->last_step >= FRAME_US && !step(active, now, NULL))) {
        desk_pet_reset();
        return;
    }
    bool resized = active->width != component->rect.width || active->height != component->rect.height;
    if (now - active->last_paint < FRAME_US || (!resized && !pet_scene_dirty(active->scene))) return;
    if (!desk_display_frame_ready()) return;
    esp_err_t result = desk_display_paint_pet(pet_scene_paint, active->scene);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Native pet paint failed: %s", esp_err_to_name(result));
        desk_pet_reset();
        return;
    }
    active->width = component->rect.width;
    active->height = component->rect.height;
    active->last_paint = now;
    if (++active->frames % 60 == 1)
        ESP_LOGI(TAG, "NATIVE_PET_DRAW frames=%u ms=%" PRId64, active->frames, (esp_timer_get_time() - now)/1000);
}
