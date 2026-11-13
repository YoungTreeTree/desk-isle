#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "esp_heap_caps.h"
#include "lauxlib.h"
#include "pet_scene.h"
#include "widget_paint.h"

#define PSRAM (MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)
#define MAX_NODES 640
#define MAX_PATH_POINTS 22000
#define MAX_CROSSINGS 128

typedef enum { GROUP, PATH, RECT, IMAGE, TEXT, ELLIPSE } node_type;
typedef enum { FULL_SCENE, BASE_LAYER, FOREGROUND } draw_pass;
typedef struct { float x, y; bool move; } point;
typedef struct { float x, y, width, height; } box;
typedef struct { float x, y, a, b, c, d, opacity; } transform;

typedef struct {
    node_type type;
    draw_pass layer;
    uint16_t first, next, count, capacity, path_ref;
    bool visible, clipped, cropped, has_base, has_front, base_changed, front_changed;
    float x, y, width, height, sx, sy, opacity, z;
    float rotation, cosine, sine, pivot_x, pivot_y;
    float radius, stroke_width, baseline, font_size;
    uint32_t color;
    box clip, crop;
    const pet_asset *asset;
    char label[32];
    point *points;
    float min_x, max_x, min_y, max_y;
    widget_box base_bounds, front_bounds;
} node;

struct pet_scene {
    const pet_asset *assets;
    unsigned assets_count, count, path_points;
    bool dirty, base_dirty;
    uint16_t *base;
    size_t base_capacity;
    int cached_width, cached_height;
    node nodes[MAX_NODES + 1];
};

static const char node_ids;

pet_scene *pet_scene_create(const pet_asset *assets, unsigned count)
{
    pet_scene *scene = heap_caps_calloc(1, sizeof(*scene), PSRAM);
    if (scene) {
        scene->assets = assets;
        scene->assets_count = count;
    }
    return scene;
}

void pet_scene_destroy(pet_scene *scene)
{
    if (!scene) return;
    for (unsigned i = 1; i <= scene->count; ++i) free(scene->nodes[i].points);
    free(scene->base);
    free(scene);
}

static float bounded(lua_State *L, int index, float limit)
{
    double n = luaL_checknumber(L, index);
    if (!isfinite(n) || fabs(n) > limit) luaL_error(L, "Scene number out of range");
    return (float)n;
}

static float number(lua_State *L, int index, const char *key, float fallback, float limit)
{
    lua_getfield(L, index, key);
    float value = lua_isnil(L, -1) ? fallback : bounded(L, -1, limit);
    lua_pop(L, 1);
    return value;
}

static float coordinate(lua_State *L, int index, int key)
{
    lua_geti(L, index, key);
    float value = bounded(L, -1, 4096);
    lua_pop(L, 1);
    return value;
}

static bool read_box(lua_State *L, int index, const char *key, box *out)
{
    lua_getfield(L, index, key);
    bool exists = !lua_isnil(L, -1);
    if (exists) {
        luaL_checktype(L, -1, LUA_TTABLE);
        int at = lua_gettop(L);
        *out = (box){coordinate(L, at, 1), coordinate(L, at, 2),
                     coordinate(L, at, 3), coordinate(L, at, 4)};
        if (out->width < 0 || out->height < 0) luaL_error(L, "Invalid scene rectangle");
    }
    lua_pop(L, 1);
    return exists;
}

static uint32_t color_field(lua_State *L, int index, const char *key, uint32_t fallback)
{
    lua_getfield(L, index, key);
    uint32_t color = fallback;
    if (!lua_isnil(L, -1)) {
        size_t size;
        const char *s = luaL_checklstring(L, -1, &size);
        if ((size != 7 && size != 9) || s[0] != '#' || strspn(s + 1, "0123456789abcdefABCDEF") != size - 1)
            luaL_error(L, "Invalid scene color");
        color = strtoul(s + 1, NULL, 16);
        if (size == 7) color = (color << 8) | 255;
    }
    lua_pop(L, 1);
    return color;
}

static const pet_asset *find_asset(pet_scene *scene, lua_State *L, int index, const char *key,
                                   unsigned kind, const pet_asset *previous)
{
    lua_getfield(L, index, key);
    if (previous && lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return previous;
    }
    const char *name = luaL_checkstring(L, -1);
    const pet_asset *result = NULL;
    for (unsigned i = 0; i < scene->assets_count; ++i) {
        const pet_asset *asset = &scene->assets[i];
        if (asset->kind == kind && !strcmp(name, asset->name)) {
            result = asset;
            break;
        }
    }
    if (!result) luaL_error(L, "Missing asset %s", name);
    lua_pop(L, 1);
    return result;
}

static bool add_point(node *n, point p, unsigned old_count)
{
    const point *old = &n->points[n->count];
    bool changed = n->count >= old_count || old->x != p.x || old->y != p.y || old->move != p.move;
    n->points[n->count++] = p;
    n->min_x = fminf(n->min_x, p.x);
    n->max_x = fmaxf(n->max_x, p.x);
    n->min_y = fminf(n->min_y, p.y);
    n->max_y = fmaxf(n->max_y, p.y);
    return changed;
}

static bool load_path(pet_scene *scene, node *n, lua_State *L, int path)
{
    luaL_checktype(L, path, LUA_TTABLE);
    size_t count = lua_rawlen(L, path);
    if (count > 2048) luaL_error(L, "Path too long");

    size_t capacity = count;
    for (size_t i = 1; i <= count; ++i) {
        lua_geti(L, path, i);
        luaL_checktype(L, -1, LUA_TTABLE);
        lua_geti(L, -1, 1);
        const char *op = luaL_checkstring(L, -1);
        if (!strcmp(op, "Q")) capacity += 11;
        else if (strcmp(op, "M") && strcmp(op, "L") && strcmp(op, "Z"))
            luaL_error(L, "Unsupported path command");
        lua_pop(L, 2);
    }
    if (capacity > n->capacity) {
        if (capacity - n->capacity > MAX_PATH_POINTS - scene->path_points)
            luaL_error(L, "Path budget exceeded");
        point *points = heap_caps_realloc(n->points, capacity * sizeof(*points), PSRAM);
        if (!points) luaL_error(L, "Path allocation failed");
        scene->path_points += capacity - n->capacity;
        n->points = points;
        n->capacity = capacity;
    }
    unsigned old_count = n->count;
    bool changed = old_count != capacity;
    n->count = 0;
    n->min_x = n->min_y = INFINITY;
    n->max_x = n->max_y = -INFINITY;
    point start = {0}, previous = {0};
    for (size_t i = 1; i <= count; ++i) {
        lua_geti(L, path, i);
        int at = lua_gettop(L);
        lua_geti(L, at, 1);
        char op = lua_tostring(L, -1)[0];
        lua_pop(L, 1);
        point p;
        if (op == 'Z') {
            p = start;
            p.move = false;
        } else {
            p = (point){coordinate(L, at, 2), coordinate(L, at, 3), op == 'M'};
            if (op == 'M') start = p;
            if (op == 'Q') {
                point control = p;
                p = (point){coordinate(L, at, 4), coordinate(L, at, 5), false};
                for (unsigned step = 1; step < 12; ++step) {
                    float t = step / 12.0f, u = 1 - t;
                    changed |= add_point(n, (point){u*u*previous.x + 2*t*u*control.x + t*t*p.x,
                                                    u*u*previous.y + 2*t*u*control.y + t*t*p.y, false}, old_count);
                }
            }
        }
        changed |= add_point(n, p, old_count);
        previous = p;
        lua_pop(L, 1);
    }
    return changed;
}

static void mark_changed(pet_scene *scene, node *n)
{
    scene->dirty = true;
    if (n->has_base) n->base_changed = scene->base_dirty = true;
    if (n->has_front) n->front_changed = true;
}

static void update_node(pet_scene *scene, node *n, lua_State *L, int index)
{
    bool changed = false;
    float old_rotation = n->rotation;
    float *fields[] = {&n->x, &n->y, &n->width, &n->height, &n->sx, &n->sy, &n->opacity, &n->rotation};
    const char *keys[] = {"x", "y", "width", "height", "scaleX", "scaleY", "opacity", "rotation"};
    const float limits[] = {4096, 4096, 4096, 4096, 4, 4, 1, 4096};
    for (unsigned i = 0; i < sizeof(fields) / sizeof(*fields); ++i) {
        float value = number(L, index, keys[i], *fields[i], limits[i]);
        if (fabsf(value - *fields[i]) >= .001f) {
            *fields[i] = value;
            changed = true;
        }
    }
    if (n->rotation != old_rotation) {
        n->cosine = cosf(n->rotation);
        n->sine = sinf(n->rotation);
    }
    uint32_t color = color_field(L, index, n->stroke_width > 0 ? "stroke" : "fill", n->color);
    box crop;
    if (read_box(L, index, "sourceRect", &crop) && (!n->cropped || memcmp(&crop, &n->crop, sizeof(crop)))) {
        n->crop = crop;
        n->cropped = true;
        changed = true;
    }
    lua_getfield(L, index, "visible");
    if (!lua_isnil(L, -1) && n->visible != lua_toboolean(L, -1)) {
        n->visible = lua_toboolean(L, -1);
        changed = true;
    }
    lua_pop(L, 1);
    if (n->color != color) {
        n->color = color;
        changed = true;
    }
    if (n->type == IMAGE) {
        const pet_asset *asset = find_asset(scene, L, index, "source", PET_IMAGE, n->asset);
        changed |= asset != n->asset;
        n->asset = asset;
    }
    if (n->type == PATH) {
        lua_getfield(L, index, "path");
        if (!lua_isnil(L, -1) && load_path(scene, n, L, lua_gettop(L))) {
            changed = true;
            unsigned id = n - scene->nodes;
            for (unsigned i = 1; i <= scene->count; ++i)
                if (scene->nodes[i].path_ref == id) mark_changed(scene, &scene->nodes[i]);
        }
        lua_pop(L, 1);
    }
    if (changed) mark_changed(scene, n);
}

static unsigned load_node(pet_scene *scene, lua_State *L, int index, int ids, int refs, unsigned depth)
{
    if (depth > 12 || scene->count >= MAX_NODES || !lua_checkstack(L, 12))
        luaL_error(L, "Scene node budget exceeded");
    luaL_checktype(L, index, LUA_TTABLE);
    unsigned id = ++scene->count;
    node *n = &scene->nodes[id];
    n->sx = n->sy = n->opacity = 1;
    n->cosine = 1;
    n->visible = true;
    n->color = 0x3d3d3dff;

    lua_getfield(L, index, "id");
    const char *name = luaL_checkstring(L, -1);
    lua_getfield(L, ids, name);
    if (!lua_isnil(L, -1)) luaL_error(L, "Duplicate scene node %s", name);
    lua_pop(L, 1);
    lua_pushinteger(L, id);
    lua_setfield(L, ids, name);
    lua_pop(L, 1);

    lua_getfield(L, index, "type");
    const char *type = luaL_checkstring(L, -1);
    const char *types[] = {"group", "path", "rect", "image", "text", "ellipse"};
    unsigned k = 0;
    while (k < sizeof(types) / sizeof(*types) && strcmp(type, types[k])) ++k;
    if (k == sizeof(types) / sizeof(*types)) luaL_error(L, "Unsupported node %s", type);
    n->type = (node_type)k;
    lua_pop(L, 1);
    const char *unsupported[] = {"matrix", "gradient", "mask", "halo"};
    for (unsigned i = 0; i < sizeof(unsupported) / sizeof(*unsupported); ++i) {
        lua_getfield(L, index, unsupported[i]);
        if (!lua_isnil(L, -1)) luaL_error(L, "Unsupported node property %s", unsupported[i]);
        lua_pop(L, 1);
    }
    lua_getfield(L, index, "stroke");
    if (!lua_isnil(L, -1)) n->stroke_width = fmaxf(.01f, number(L, index, "strokeWidth", 1, 128));
    lua_pop(L, 1);
    update_node(scene, n, L, index);
    n->z = number(L, index, "z", 0, 4096);
    n->radius = number(L, index, "radius", 0, 128);
    n->clipped = read_box(L, index, "clip", &n->clip);
    lua_getfield(L, index, "pivot");
    if (!lua_isnil(L, -1)) {
        luaL_checktype(L, -1, LUA_TTABLE);
        int pivot = lua_gettop(L);
        n->pivot_x = coordinate(L, pivot, 1);
        n->pivot_y = coordinate(L, pivot, 2);
    }
    lua_pop(L, 1);

    if (n->type == PATH) {
        lua_getfield(L, index, "pathRef");
        if (!lua_isnil(L, -1)) luaL_checktype(L, -1, LUA_TSTRING);
        lua_rawseti(L, refs, id);
    } else if (n->type == TEXT) {
        n->asset = find_asset(scene, L, index, "font", PET_FONT, NULL);
        n->font_size = number(L, index, "fontSize", 12, 128);
        n->baseline = number(L, index, "baseline", 12, 128);
        lua_getfield(L, index, "text");
        size_t size;
        const char *label = luaL_checklstring(L, -1, &size);
        if (size >= sizeof(n->label)) luaL_error(L, "Label too long");
        for (unsigned i = 0; i < size; ++i)
            if (label[i] < 32 || label[i] > 126) luaL_error(L, "Unsupported label character");
        memcpy(n->label, label, size);
        lua_pop(L, 1);
    }

    lua_getfield(L, index, "children");
    if (!lua_isnil(L, -1)) {
        luaL_checktype(L, -1, LUA_TTABLE);
        int children = lua_gettop(L);
        size_t count = lua_rawlen(L, children);
        if (count > MAX_NODES - scene->count) luaL_error(L, "Too many children");
        for (size_t i = 1; i <= count; ++i) {
            lua_geti(L, children, i);
            unsigned child = load_node(scene, L, lua_gettop(L), ids, refs, depth + 1);
            lua_pop(L, 1);
            uint16_t *next = &n->first;
            while (*next && scene->nodes[*next].z <= scene->nodes[child].z) next = &scene->nodes[*next].next;
            scene->nodes[child].next = *next;
            *next = child;
        }
    }
    lua_pop(L, 1);
    return id;
}

static void classify_layers(pet_scene *scene, unsigned id, bool *in_foreground)
{
    node *n = &scene->nodes[id];
    // Cache the geometry before the first image, retaining the original order
    // of all later artwork, paths, and other effects in the foreground.
    *in_foreground |= n->type == IMAGE;
    n->layer = *in_foreground ? FOREGROUND : BASE_LAYER;
    n->has_base = n->type != GROUP && n->layer == BASE_LAYER;
    n->has_front = n->type != GROUP && n->layer == FOREGROUND;
    for (unsigned child = n->first; child; child = scene->nodes[child].next) {
        classify_layers(scene, child, in_foreground);
        n->has_base |= scene->nodes[child].has_base;
        n->has_front |= scene->nodes[child].has_front;
    }
}

void pet_scene_load(pet_scene *scene, lua_State *L)
{
    if (scene->count) luaL_error(L, "Scene already loaded");
    lua_newtable(L);
    int ids = lua_gettop(L);
    lua_newtable(L);
    int refs = lua_gettop(L);
    load_node(scene, L, 1, ids, refs, 0);
    for (unsigned i = 1; i <= scene->count; ++i) {
        lua_rawgeti(L, refs, i);
        if (!lua_isnil(L, -1)) {
            const char *name = lua_tostring(L, -1);
            lua_getfield(L, ids, name);
            lua_Integer source = lua_tointeger(L, -1);
            if (source < 1 || source > scene->count || scene->nodes[source].type != PATH)
                luaL_error(L, "Unknown path %s", name);
            if (lua_rawgeti(L, refs, source) != LUA_TNIL) luaL_error(L, "Nested path reference %s", name);
            scene->nodes[i].path_ref = source;
            lua_pop(L, 2);
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &node_ids);
    if (scene->nodes[1].width <= 0 || scene->nodes[1].height <= 0) luaL_error(L, "Invalid scene size");
    bool in_foreground = false;
    classify_layers(scene, 1, &in_foreground);
    scene->base_dirty = true;
    scene->dirty = true;
}

void pet_scene_set(pet_scene *scene, lua_State *L)
{
    const char *id = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    if (lua_rawgetp(L, LUA_REGISTRYINDEX, &node_ids) != LUA_TTABLE) luaL_error(L, "Scene unavailable");
    lua_getfield(L, -1, id);
    lua_Integer index = lua_tointeger(L, -1);
    if (index < 1 || index > scene->count) luaL_error(L, "Unknown scene node %s", id);
    lua_pop(L, 2);
    update_node(scene, &scene->nodes[index], L, 2);
}

static int low_edge(float n, int low, int high)
{
    return (int)ceilf(fminf(high, fmaxf(low, n - .5f)));
}

static widget_box screen_box(widget_canvas *canvas, transform t, box rect)
{
    if (rect.width <= 0 || rect.height <= 0) return (widget_box){0};
    float origin_x = t.x + rect.x*t.a + rect.y*t.c;
    float origin_y = t.y + rect.x*t.b + rect.y*t.d;
    float ax = rect.width*t.a, ay = rect.width*t.b;
    float bx = rect.height*t.c, by = rect.height*t.d;
    widget_box clip = canvas->clip;
    int right = clip.x + clip.width, bottom = clip.y + clip.height;
    int x = low_edge(origin_x + fminf(0, ax) + fminf(0, bx), clip.x, right);
    int y = low_edge(origin_y + fminf(0, ay) + fminf(0, by), clip.y, bottom);
    return (widget_box){x, y, low_edge(origin_x + fmaxf(0, ax) + fmaxf(0, bx), x, right) - x,
                             low_edge(origin_y + fmaxf(0, ay) + fmaxf(0, by), y, bottom) - y};
}

static transform inverse(transform t)
{
    float det = t.a*t.d - t.b*t.c;
    transform result = {.a = t.d/det, .b = -t.b/det, .c = -t.c/det, .d = t.a/det};
    result.x = -result.a*t.x - result.c*t.y;
    result.y = -result.b*t.x - result.d*t.y;
    return result;
}

static float smallest_scale(transform t)
{
    if (t.b == 0 && t.c == 0) return fminf(fabsf(t.a), fabsf(t.d));
    return sqrtf(fminf(t.a*t.a + t.b*t.b, t.c*t.c + t.d*t.d));
}

static const node *path_geometry(const pet_scene *scene, const node *n)
{
    return n->path_ref ? &scene->nodes[n->path_ref] : n;
}

static void draw_path(widget_canvas *c, const node *n, const node *geometry,
                      transform t, uint16_t color, uint8_t alpha)
{
    const point *points = geometry->points;
    unsigned points_count = geometry->count;
    if (points_count < 2) return;
    if (n->stroke_width > 0) {
        int width = (int)fmaxf(1, roundf(n->stroke_width * smallest_scale(t)));
        for (unsigned i = 1; i < points_count; ++i) {
            point a = points[i-1], b = points[i];
            if (b.move) continue;
            float ax = t.x + a.x*t.a + a.y*t.c, ay = t.y + a.x*t.b + a.y*t.d;
            float bx = t.x + b.x*t.a + b.y*t.c, by = t.y + b.x*t.b + b.y*t.d;
            if (fmaxf(ax, bx) < c->clip.x - width || fminf(ax, bx) >= c->clip.x + c->clip.width + width ||
                fmaxf(ay, by) < c->clip.y - width || fminf(ay, by) >= c->clip.y + c->clip.height + width)
                continue;
            widget_line(c, (int)ax, (int)ay, (int)bx, (int)by, width, color, alpha);
        }
        return;
    }
    widget_box bounds = screen_box(c, t, (box){geometry->min_x, geometry->min_y,
        geometry->max_x - geometry->min_x, geometry->max_y - geometry->min_y});
    bool axis_aligned = t.b == 0 && t.c == 0;
    for (int y = bounds.y; y < bounds.y + bounds.height; ++y) {
        float at = y + .5f - t.y;
        if (axis_aligned) at /= t.d;
        float crossings[MAX_CROSSINGS];
        unsigned count = 0;
        for (unsigned i = 1; i < points_count; ++i) {
            point a = points[i-1], b = points[i];
            if (b.move) continue;
            float ay = axis_aligned ? a.y : a.x*t.b + a.y*t.d;
            float by = axis_aligned ? b.y : b.x*t.b + b.y*t.d;
            if ((ay > at) == (by > at)) continue;
            if (count == MAX_CROSSINGS) break;
            float ratio = (at - ay) / (by - ay);
            float x = t.x + (a.x + ratio*(b.x - a.x))*t.a + (a.y + ratio*(b.y - a.y))*t.c;
            unsigned j = count++;
            while (j > 0 && crossings[j-1] > x) {
                crossings[j] = crossings[j-1];
                --j;
            }
            crossings[j] = x;
        }
        for (unsigned i = 1; i < count; i += 2) {
            int x = low_edge(crossings[i-1], c->clip.x, c->clip.x + c->clip.width);
            int end = low_edge(crossings[i], x, c->clip.x + c->clip.width);
            widget_rect(c, (widget_box){x, y, end - x, 1}, color, alpha);
        }
    }
}

static bool inside_shape(bool ellipse, float x, float y, float rx, float ry, float radius)
{
    if (rx <= 0 || ry <= 0 || x >= rx || y >= ry) return false;
    if (ellipse) {
        x /= rx;
        y /= ry;
        return x*x + y*y < 1;
    }
    if (radius <= 0) return true;
    radius = fminf(radius, fminf(rx, ry));
    x = fmaxf(0, x - rx + radius);
    y = fmaxf(0, y - ry + radius);
    return x*x + y*y < radius*radius;
}

static void draw_shape(widget_canvas *c, const node *n, transform t, uint16_t color, uint8_t alpha)
{
    if (n->width <= 0 || n->height <= 0) return;
    if (n->type == RECT && n->stroke_width == 0 && t.b == 0 && t.c == 0) {
        widget_canvas full = *c;
        full.clip = (widget_box){0, 0, c->width, c->height};
        widget_box dest = screen_box(&full, t, (box){0, 0, n->width, n->height});
        widget_round(c, dest, (int)fmaxf(0, n->radius*smallest_scale(t)), color, alpha);
        return;
    }

    bool ellipse = n->type == ELLIPSE;
    float rx = n->width*.5f, ry = n->height*.5f, stroke = n->stroke_width*.5f;
    widget_box dest = screen_box(c, t, (box){-stroke, -stroke, n->width + 2*stroke, n->height + 2*stroke});
    transform inv = inverse(t);
    for (int y = dest.y; y < dest.y + dest.height; ++y) {
        int end = dest.x + dest.width;
        int start = end;
        for (int x = dest.x; x <= end; ++x) {
            float px = fabsf(inv.x + (x + .5f)*inv.a + (y + .5f)*inv.c - rx);
            float py = fabsf(inv.y + (x + .5f)*inv.b + (y + .5f)*inv.d - ry);
            bool paint = x < end && inside_shape(ellipse, px, py, rx + stroke, ry + stroke, n->radius + stroke) &&
                         (stroke == 0 || !inside_shape(ellipse, px, py, rx - stroke, ry - stroke, n->radius - stroke));
            if (paint && start == end) start = x;
            if (!paint && start != end) {
                widget_rect(c, (widget_box){start, y, x - start, 1}, color, alpha);
                start = end;
            }
        }
    }
}

static unsigned u16(const uint8_t *p)
{
    return p[0] | (unsigned)p[1] << 8;
}

static void put_sprite(widget_canvas *c, size_t i, const uint8_t *rgba, unsigned opacity)
{
    unsigned alpha = (rgba[3] * opacity + 127) / 255;
    if (!alpha) return;
    if (alpha == 255) {
        c->pixels[i] = WIDGET_RGB(rgba[0], rgba[1], rgba[2]);
        c->alpha[i] = 255;
        return;
    }
    uint16_t dst = c->alpha[i] ? c->pixels[i] : 0;
    unsigned inverse = 255 - alpha;
    unsigned r = (rgba[0] * opacity + ((dst >> 11) << 3) * inverse) / 255;
    unsigned g = (rgba[1] * opacity + (((dst >> 5) & 63) << 2) * inverse) / 255;
    unsigned b = (rgba[2] * opacity + ((dst & 31) << 3) * inverse) / 255;
    c->pixels[i] = WIDGET_RGB(r, g, b);
    c->alpha[i] = alpha + (c->alpha[i] * inverse + 127) / 255;
}

static void draw_image(widget_canvas *c, const node *n, transform t)
{
    const uint8_t *data = n->asset->data;
    unsigned ow = u16(data), oh = u16(data + 2), w = u16(data + 4), h = u16(data + 6);
    box src = n->cropped ? n->crop : (box){0, 0, ow, oh};
    if (n->width <= 0 || n->height <= 0 || src.width <= 0 || src.height <= 0) return;
    widget_box dest = screen_box(c, t, (box){0, 0, n->width, n->height});
    unsigned opacity = (unsigned)roundf(255*t.opacity);
    if (t.b != 0 || t.c != 0) {
        transform inv = inverse(t);
        float sx = src.width * w / (ow * n->width);
        float sy = src.height * h / (oh * n->height);
        for (int y = dest.y; y < dest.y + dest.height; ++y) {
            float x0 = inv.x + (y + .5f)*inv.c, y0 = inv.y + (y + .5f)*inv.d;
            for (int x = dest.x; x < dest.x + dest.width; ++x) {
                float px = x0 + (x + .5f)*inv.a, py = y0 + (x + .5f)*inv.b;
                if (px < 0 || py < 0 || px >= n->width || py >= n->height) continue;
                unsigned col = (unsigned)fmaxf(0, fminf(w - 1, src.x*w/ow + px*sx));
                unsigned row = (unsigned)fmaxf(0, fminf(h - 1, src.y*h/oh + py*sy));
                put_sprite(c, (size_t)y*c->stride + x, data + 8 + ((size_t)row*w + col)*4, opacity);
            }
        }
        return;
    }
    float sx = src.width * w / (ow * t.a * n->width);
    float sy = src.height * h / (oh * t.d * n->height);
    float x0 = src.x * w / ow + (.5f - t.x)*sx;
    float y0 = src.y * h / oh + (.5f - t.y)*sy;
    uint16_t columns[DESK_PET_LARGE_WIDTH];
    for (int x = 0; x < dest.width; ++x)
        columns[x] = (uint16_t)fmaxf(0, fminf(w - 1, x0 + (dest.x + x)*sx));
    for (int y = dest.y; y < dest.y + dest.height; ++y) {
        int row = (int)fmaxf(0, fminf(h - 1, y0 + y*sy));
        const uint8_t *source = data + 8 + (size_t)row*w*4;
        size_t at = (size_t)y*c->stride + dest.x;
        for (int x = 0; x < dest.width; ++x) put_sprite(c, at + x, source + columns[x]*4, opacity);
    }
}

static void draw_text(widget_canvas *c, const node *n, transform t, uint16_t color, uint8_t alpha)
{
    if (n->font_size <= 0) return;
    float scale = n->font_size / PET_GLYPH_SIZE;
    transform inv = inverse(t);
    float pen = 0;
    for (const char *p = n->label; *p; ++p) {
        const uint8_t *glyph = n->asset->data + (*p - 32)*PET_GLYPH_BYTES;
        box area = {pen - 2*scale, n->baseline - 28*scale, PET_GLYPH_WIDTH*scale, PET_GLYPH_HEIGHT*scale};
        widget_box dest = screen_box(c, t, area);
        for (int y = dest.y; y < dest.y + dest.height; ++y) {
            for (int x = dest.x; x < dest.x + dest.width; ++x) {
                float u = (inv.x + (x + .5f)*inv.a + (y + .5f)*inv.c - area.x)/scale;
                float v = (inv.y + (x + .5f)*inv.b + (y + .5f)*inv.d - area.y)/scale;
                if (u < 0 || v < 0 || u >= PET_GLYPH_WIDTH || v >= PET_GLYPH_HEIGHT) continue;
                unsigned col = (unsigned)u, row = (unsigned)v;
                unsigned a = (alpha * glyph[1 + row*PET_GLYPH_WIDTH + col] + 127)/255;
                if (a) widget_rect(c, (widget_box){x, y, 1, 1}, color, a);
            }
        }
        pen += glyph[0]*scale;
    }
}

static transform node_transform(const node *n, transform parent)
{
    float a = n->cosine*n->sx, b = n->sine*n->sx;
    float c = -n->sine*n->sy, d = n->cosine*n->sy;
    float px = n->pivot_x*n->width, py = n->pivot_y*n->height;
    float x = n->x + px - a*px - c*py, y = n->y + py - b*px - d*py;
    return (transform){.x = parent.x + parent.a*x + parent.c*y, .y = parent.y + parent.b*x + parent.d*y,
                       .a = parent.a*a + parent.c*b, .b = parent.b*a + parent.d*b,
                       .c = parent.a*c + parent.c*d, .d = parent.b*c + parent.d*d,
                       .opacity = n->opacity*parent.opacity};
}

static bool drawable(const node *n, transform t)
{
    return n->visible && t.opacity > 0 && fabsf(t.a*t.d - t.b*t.c) >= .000001f &&
           t.a*t.a + t.b*t.b <= 16 && t.c*t.c + t.d*t.d <= 16;
}

static widget_box join_bounds(widget_box a, widget_box b)
{
    if (a.width <= 0 || a.height <= 0) return b;
    if (b.width <= 0 || b.height <= 0) return a;
    int x = a.x < b.x ? a.x : b.x;
    int y = a.y < b.y ? a.y : b.y;
    int right_a = a.x + a.width, right_b = b.x + b.width;
    int bottom_a = a.y + a.height, bottom_b = b.y + b.height;
    return (widget_box){x, y, (right_a > right_b ? right_a : right_b) - x,
                             (bottom_a > bottom_b ? bottom_a : bottom_b) - y};
}

static box node_area(const pet_scene *scene, const node *n, transform t)
{
    if (n->type == IMAGE) return (box){0, 0, n->width, n->height};
    if (n->type == RECT || n->type == ELLIPSE) {
        float stroke = n->stroke_width*.5f;
        return (box){-stroke, -stroke, n->width + 2*stroke, n->height + 2*stroke};
    }
    if (n->type == PATH) {
        const node *geometry = path_geometry(scene, n);
        if (geometry->count < 2) return (box){0};
        float margin = n->stroke_width + 2 / smallest_scale(t);
        return (box){geometry->min_x - margin, geometry->min_y - margin,
                     geometry->max_x - geometry->min_x + 2*margin, geometry->max_y - geometry->min_y + 2*margin};
    }
    if (n->type == TEXT && n->font_size > 0) {
        float scale = n->font_size / PET_GLYPH_SIZE;
        unsigned width = PET_GLYPH_WIDTH;
        for (const char *p = n->label; *p; ++p) width += n->asset->data[(*p - 32)*PET_GLYPH_BYTES];
        return (box){-2*scale, n->baseline - 28*scale, width*scale, PET_GLYPH_HEIGHT*scale};
    }
    return (box){0};
}

static widget_box measure_layer(pet_scene *scene, unsigned id, widget_canvas *c, transform parent,
                                draw_pass pass, widget_box *dirty)
{
    node *n = &scene->nodes[id];
    const bool foreground = pass == FOREGROUND;
    if (foreground ? !n->has_front : !n->has_base) return (widget_box){0};
    widget_box *previous = foreground ? &n->front_bounds : &n->base_bounds;
    bool *changed = foreground ? &n->front_changed : &n->base_changed;
    transform t = node_transform(n, parent);
    widget_box bounds = {0}, saved = c->clip;
    if (drawable(n, t)) {
        if (n->clipped) c->clip = screen_box(c, t, n->clip);
        if (n->layer == pass) bounds = screen_box(c, t, node_area(scene, n, t));
        for (unsigned child = n->first; child; child = scene->nodes[child].next)
            bounds = join_bounds(bounds, measure_layer(scene, child, c, t, pass, dirty));
        c->clip = saved;
    }
    if (*changed) *dirty = join_bounds(*dirty, join_bounds(*previous, bounds));
    *previous = bounds;
    *changed = false;
    return bounds;
}

static void draw_node(const pet_scene *scene, unsigned id, widget_canvas *c, transform parent, draw_pass pass)
{
    const node *n = &scene->nodes[id];
    if (pass != FULL_SCENE) {
        widget_box b = pass == FOREGROUND ? n->front_bounds : n->base_bounds;
        widget_box clip = c->clip;
        if (b.width <= 0 || b.height <= 0 || b.x >= clip.x + clip.width ||
            b.x + b.width <= clip.x || b.y >= clip.y + clip.height || b.y + b.height <= clip.y) return;
    }
    transform t = node_transform(n, parent);
    if (!drawable(n, t)) return;
    widget_box saved = c->clip;
    if (n->clipped) c->clip = screen_box(c, t, n->clip);
    if (c->clip.width > 0 && c->clip.height > 0) {
        if (pass == FULL_SCENE || n->layer == pass) {
            uint16_t color = WIDGET_RGB(n->color >> 24, (n->color >> 16) & 255, (n->color >> 8) & 255);
            uint8_t alpha = (uint8_t)roundf(t.opacity * (n->color & 255));
            switch (n->type) {
            case GROUP: break;
            case PATH: draw_path(c, n, path_geometry(scene, n), t, color, alpha); break;
            case RECT:
            case ELLIPSE: draw_shape(c, n, t, color, alpha); break;
            case IMAGE: draw_image(c, n, t); break;
            case TEXT: draw_text(c, n, t, color, alpha); break;
            }
        }
        for (unsigned child = n->first; child; child = scene->nodes[child].next) draw_node(scene, child, c, t, pass);
    }
    c->clip = saved;
}

bool pet_scene_dirty(const pet_scene *scene)
{
    return scene->dirty;
}

static bool prepare_base(pet_scene *scene, widget_canvas *base, transform t, widget_box *dirty)
{
    size_t count = (size_t)base->stride * base->height;
    size_t bytes = count * (sizeof(uint16_t) + 1);
    if (scene->base_capacity < bytes) {
        uint16_t *memory = heap_caps_realloc(scene->base, bytes, PSRAM);
        if (!memory) return false;
        scene->base = memory;
        scene->base_capacity = bytes;
        scene->cached_width = 0;
    }
    base->pixels = scene->base;
    base->alpha = (uint8_t *)(scene->base + count);
    bool resized = scene->cached_width != base->width || scene->cached_height != base->height;
    if (resized || scene->base_dirty) {
        measure_layer(scene, 1, base, t, BASE_LAYER, dirty);
        if (resized) {
            memset(base->pixels, 0, count * sizeof(*base->pixels));
            memset(base->alpha, 0, count);
            *dirty = base->clip;
        } else {
            for (int y = dirty->y; y < dirty->y + dirty->height; ++y) {
                size_t offset = (size_t)y * base->stride + dirty->x;
                memset(base->pixels + offset, 0, dirty->width * sizeof(*base->pixels));
                memset(base->alpha + offset, 0, dirty->width);
            }
        }
        widget_box full = base->clip;
        base->clip = *dirty;
        draw_node(scene, 1, base, t, BASE_LAYER);
        base->clip = full;
        scene->cached_width = base->width;
        scene->cached_height = base->height;
        scene->base_dirty = false;
    }
    return true;
}

widget_box pet_scene_paint(widget_canvas *canvas, void *context)
{
    pet_scene *scene = context;
    const node *root = &scene->nodes[1];
    size_t pixels = (size_t)canvas->stride * canvas->height;
    float scale = root->width > 0 && root->height > 0
        ? fminf((canvas->width - 16)/root->width, (canvas->height - 16)/root->height) : 0;
    transform t = {.x = (canvas->width - root->width*scale)/2, .y = (canvas->height - root->height*scale)/2,
                   .a = scale, .d = scale, .opacity = 1};
    widget_box dirty = {0}, full = canvas->clip;
    widget_canvas base = *canvas;
    if (prepare_base(scene, &base, t, &dirty)) {
        measure_layer(scene, 1, canvas, t, FOREGROUND, &dirty);
        if (dirty.width > 0 && dirty.height > 0) {
            for (int y = dirty.y; y < dirty.y + dirty.height; ++y) {
                size_t offset = (size_t)y * canvas->stride + dirty.x;
                memcpy(canvas->pixels + offset, base.pixels + offset, dirty.width * sizeof(*base.pixels));
                memcpy(canvas->alpha + offset, base.alpha + offset, dirty.width);
            }
            canvas->clip = dirty;
            draw_node(scene, 1, canvas, t, FOREGROUND);
            canvas->clip = full;
        }
    } else {
        memset(canvas->pixels, 0, pixels * sizeof(*canvas->pixels));
        memset(canvas->alpha, 0, pixels);
        draw_node(scene, 1, canvas, t, FULL_SCENE);
        dirty = full;
    }
    scene->dirty = false;
    return dirty;
}
