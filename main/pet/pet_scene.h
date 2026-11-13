#pragma once

#include "lua.h"
#include "widget.h"

enum { PET_SOURCE = 1, PET_IMAGE = 2, PET_FONT = 3, PET_MANIFEST = 4 };
enum { PET_GLYPH_WIDTH = 32, PET_GLYPH_HEIGHT = 36, PET_GLYPH_SIZE = 24,
       PET_GLYPH_BYTES = 1 + PET_GLYPH_WIDTH * PET_GLYPH_HEIGHT };

typedef struct {
    char name[80];
    const uint8_t *data;
    size_t size;
    unsigned kind;
} pet_asset;

typedef struct pet_scene pet_scene;

pet_scene *pet_scene_create(const pet_asset *assets, unsigned count);
void pet_scene_destroy(pet_scene *scene);
void pet_scene_load(pet_scene *scene, lua_State *L);
void pet_scene_set(pet_scene *scene, lua_State *L);
bool pet_scene_dirty(const pet_scene *scene);
widget_box pet_scene_paint(widget_canvas *canvas, void *context);
