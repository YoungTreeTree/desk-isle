#include "model3d.h"
#include "scene3d.h"
#include "display.h"
#include "control.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static scene3d *scene;
static uint8_t *active_pack,*upload;
static size_t active_size,upload_size,upload_used;
static uint32_t active_crc,upload_crc;
static int64_t upload_at,start,next_frame,yield_at,paused_at;
static uint64_t frames,render_us,max_us,present_base;
static uint64_t composition_base;
static unsigned divisor=1,render_width,render_height;
static uint16_t *low_pixels;
static bool paused,greeting;
static const char *TAG="DESK_3D";
static uint32_t u32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void *allocate(size_t n){return heap_caps_malloc(n,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);}
static void abort_upload(void){free(upload);upload=NULL;upload_used=upload_size=0;}
static uint64_t clock_us(void){return (uint64_t)esp_timer_get_time();}
static void reset_stats(void){frames=render_us=max_us=0;present_base=desk_display_present_count();composition_base=desk_display_model_composition_us();scene3d_reset_profile(scene);start=esp_timer_get_time();next_frame=0;paused_at=0;}
static bool resize(const desk_component *c,unsigned scale){
    unsigned w=c->rect.width/scale,h=c->rect.height/scale;
    uint16_t *pixels=NULL;
    if(scale!=1){pixels=allocate((size_t)w*h*2);if(!pixels)return false;}
    if(!scene3d_resize(scene,w,h)){free(pixels);return false;}
    free(low_pixels);low_pixels=pixels;render_width=w;render_height=h;divisor=scale;return true;
}
void desk_model3d_layout(const desk_component *c){
    if(!c){scene3d_destroy(scene);scene=NULL;free(active_pack);active_pack=NULL;active_size=0;active_crc=0;free(low_pixels);low_pixels=NULL;abort_upload();frames=0;return;}
    if(scene&&(render_width!=c->rect.width/divisor||render_height!=c->rect.height/divisor)){
        if(!resize(c,divisor)){scene3d_destroy(scene);scene=NULL;free(active_pack);active_pack=NULL;active_size=0;active_crc=0;free(low_pixels);low_pixels=NULL;}
        paused=greeting=false;reset_stats();
    }
}
size_t desk_model3d_pack_size(void){return active_size;}
uint32_t desk_model3d_pack_crc(void){return active_crc;}
esp_err_t desk_model3d_receive(const desk_message *m,const desk_component *c){
    if(m->kind==DESK_MODEL3D_ABORT){abort_upload();return ESP_OK;}
    if(!c)return ESP_ERR_NOT_FOUND;
    if(m->kind==DESK_MODEL3D_BEGIN){
        size_t size=u32(m->data);if(size<20||size>DESK_MAX_MODEL3D_PACK)return ESP_ERR_INVALID_SIZE;
        abort_upload();upload=allocate(size);if(!upload)return ESP_ERR_NO_MEM;
        upload_size=size;upload_crc=u32(m->data+4);upload_at=esp_timer_get_time();return ESP_OK;
    }
    if(m->kind==DESK_MODEL3D_CHUNK){
        if(!upload||u32(m->data)!=upload_used||m->length-4>upload_size-upload_used)return ESP_ERR_INVALID_ARG;
        memcpy(upload+upload_used,m->data+4,m->length-4);upload_used+=m->length-4;upload_at=esp_timer_get_time();return ESP_OK;
    }
    if(m->kind==DESK_MODEL3D_COMMIT){
        if(!upload||upload_used!=upload_size||desk_crc32(upload,upload_size)!=upload_crc)return ESP_ERR_INVALID_CRC;
        scene3d *candidate=scene3d_create(upload,upload_size,allocate);
        if(!candidate){abort_upload();return ESP_ERR_INVALID_ARG;}
        if(!scene3d_resize(candidate,c->rect.width,c->rect.height)){scene3d_destroy(candidate);abort_upload();return ESP_ERR_NO_MEM;}
        scene3d_destroy(scene);free(active_pack);free(low_pixels);low_pixels=NULL;
        scene=candidate;active_pack=upload;active_size=upload_size;active_crc=upload_crc;upload=NULL;upload_size=upload_used=0;
        scene3d_set_clock(scene,clock_us);
        divisor=1;render_width=c->rect.width;render_height=c->rect.height;paused=greeting=false;reset_stats();
        ESP_LOGI(TAG,"MODEL_READY bytes=%u triangles=%u vertices=%u renderer=%u",(unsigned)active_size,scene3d_triangles(scene),scene3d_vertices(scene),(unsigned)scene3d_memory(scene));return ESP_OK;
    }
    if(m->kind==DESK_MODEL3D_CONTROL){
        if(!scene)return ESP_ERR_INVALID_STATE;
        unsigned action=m->data[0],value=m->data[1];
        if(action==0){ // Pause/resume; exclude the paused wall time from the animation clock.
            if(value>1)return ESP_ERR_INVALID_ARG;
            if(value&&!paused)paused_at=esp_timer_get_time();
            if(!value&&paused){start+=esp_timer_get_time()-paused_at;paused_at=0;}
            paused=value!=0;
        }else if(action==1){paused=greeting=false;reset_stats();}
        else if(action==2){if(value!=1&&value!=2&&value!=4)return ESP_ERR_INVALID_ARG;if(!resize(c,value))return ESP_ERR_NO_MEM;paused=greeting=false;reset_stats();}
        else if(action==3){if(value>1)return ESP_ERR_INVALID_ARG;greeting=value!=0;}
        else return ESP_ERR_INVALID_ARG;
        return ESP_OK;
    }
    return m->kind==DESK_MODEL3D_STATS?ESP_OK:ESP_ERR_INVALID_ARG;
}
static void cooperate(void){int64_t now=esp_timer_get_time();if(now-yield_at>=20000){vTaskDelay(1);yield_at=esp_timer_get_time();}}
typedef struct { double seconds; bool valid; } model_paint;
static widget_box paint(widget_canvas *canvas,void *context){
    model_paint *frame=context;
    double seconds=frame->seconds;
    uint16_t *target=divisor==1?canvas->pixels:low_pixels;
    if(!scene3d_render(scene,target,divisor==1?(unsigned)canvas->stride:render_width,seconds,greeting,cooperate))return (widget_box){0};
    if(!scene3d_copy_alpha(scene,canvas->alpha,(unsigned)canvas->stride,divisor))return (widget_box){0};
    frame->valid=true;
    const scene3d_rect changed=scene3d_changed_rect(scene);
    if(divisor!=1){
        for(unsigned y=changed.y*divisor;y<(changed.y+changed.height)*divisor;y++){
            const uint16_t *source=low_pixels+(y/divisor)*render_width;uint16_t *out=canvas->pixels+y*canvas->stride;
            for(unsigned x=changed.x*divisor;x<(changed.x+changed.width)*divisor;x++)out[x]=source[x/divisor];}
    }
    return (widget_box){changed.x*divisor,changed.y*divisor,changed.width*divisor,changed.height*divisor};
}
void desk_model3d_tick(const desk_component *c,int64_t now){
    if(upload&&now-upload_at>30000000)abort_upload();
    const desk_backlight light=desk_control_backlight();
    if(upload||!c||!scene||paused||light.blanked||!light.brightness||now<next_frame||!desk_display_frame_ready())return;
    int64_t before=esp_timer_get_time();yield_at=before;double seconds=(before-start)/1000000.;
    model_paint frame={.seconds=seconds};
    esp_err_t result=desk_display_paint_model3d(paint,&frame);
    if(result==ESP_OK&&!frame.valid)result=ESP_FAIL;
    uint64_t elapsed=esp_timer_get_time()-before;
    if(result!=ESP_OK){paused=true;paused_at=esp_timer_get_time();ESP_LOGW(TAG,"MODEL_FRAME_FAILED %s",esp_err_to_name(result));return;}
    ++frames;render_us+=elapsed;if(elapsed>max_us)max_us=elapsed;next_frame=before+16667;
}
int desk_model3d_stats(char *line,size_t capacity,uint32_t sequence){
    uint64_t elapsed=scene?(uint64_t)((paused?paused_at:esp_timer_get_time())-start):0;
    uint64_t presented=scene?desk_display_present_count()-present_base:0;
    return snprintf(line,capacity,"DESKISLE_3D_STATS 1 %"PRIu32" %u %u %"PRIu64" %"PRIu64" %"PRIu64" %"PRIu64" %"PRIu64" %"PRIu64" %u %u %u %u %u %u %u\n",
        sequence,render_width,render_height,frames,presented,elapsed,render_us,max_us,frames?render_us/frames:0,
        scene3d_triangles(scene),scene3d_vertices(scene),(unsigned)active_size,(unsigned)scene3d_memory(scene),
        (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),(unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM),
        (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
}
int desk_model3d_profile(char *line,size_t capacity,uint32_t sequence){
    scene3d_profile p=scene3d_get_profile(scene);
    return snprintf(line,capacity,"DESKISLE_3D_PROFILE 1 %"PRIu32" %"PRIu64" %"PRIu64" %"PRIu64" %"PRIu64" %"PRIu64" %"PRIu64"\n",
        sequence,p.frames,p.animation_us,p.clear_us,p.vertex_us,p.raster_us,
        scene?desk_display_model_composition_us()-composition_base:0);
}
