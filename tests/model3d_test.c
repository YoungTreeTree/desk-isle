#include "scene3d.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <limits.h>

static unsigned allocations_left=UINT_MAX;
static void *limited_allocate(size_t n){if(!allocations_left)return NULL;--allocations_left;return malloc(n);}

static uint64_t hash(const uint16_t *p,size_t count){uint64_t h=1469598103934665603ULL;for(size_t i=0;i<count;i++){h^=p[i];h*=1099511628211ULL;}return h;}
static void check_transparent_component(const uint8_t *pack,size_t length){
    scene3d *incremental=scene3d_create(pack,length,malloc),*reference=scene3d_create(pack,length,malloc);
    assert(incremental&&reference);
    uint16_t *color=malloc(320*480*2),*fresh[2]={malloc(320*480*2),malloc(320*480*2)};
    const unsigned stride=336;size_t bytes=(size_t)stride*480;
    uint8_t *alpha=malloc(bytes),*expected=malloc(bytes);assert(color&&fresh[0]&&fresh[1]&&alpha&&expected);
    const double times[]={0,.25,2.1,3.1,6.4,7.8,10.2,12,1.6,0};
    for(unsigned scale=1;scale<=4;scale*=2){
        assert(scene3d_resize(incremental,320/scale,480/scale));assert(scene3d_resize(reference,320/scale,480/scale));
        assert(!scene3d_copy_alpha(incremental,alpha,stride,scale));
        memset(alpha,0x5a,bytes);
        for(unsigned frame=0;frame<sizeof(times)/sizeof(times[0]);frame++){
            assert(scene3d_render(incremental,color,320/scale,times[frame],false,NULL));
            assert(scene3d_copy_alpha(incremental,alpha,stride,scale));
            assert(scene3d_render(reference,fresh[frame%2],320/scale,times[frame],false,NULL));
            memset(expected,0x5a,bytes);assert(scene3d_copy_alpha(reference,expected,stride,scale));
            assert(!memcmp(alpha,expected,bytes)); // No trails after moving, replaying or changing resolution.
            unsigned covered=0,clear=0;
            for(unsigned y=0;y<480;y++)for(unsigned x=0;x<stride;x++){
                uint8_t a=alpha[y*stride+x];
                if(x>=320){assert(a==0x5a);continue;}
                assert(a==0||a==255);if(a)++covered;else ++clear;
            }
            assert(clear>0);if(times[frame]==6.4)assert(covered>0);
        }
        assert(!scene3d_copy_alpha(incremental,NULL,stride,scale));
        assert(!scene3d_copy_alpha(incremental,alpha,319,scale));
        assert(!scene3d_copy_alpha(incremental,alpha,stride,3));
    }
    free(color);free(fresh[0]);free(fresh[1]);free(alpha);free(expected);scene3d_destroy(incremental);scene3d_destroy(reference);
}
int main(int argc,char **argv){
    assert(argc>=2);FILE *file=fopen(argv[1],"rb");assert(file);assert(!fseek(file,0,SEEK_END));long length=ftell(file);assert(length>20);rewind(file);
    uint8_t *pack=malloc((size_t)length);assert(pack);assert(fread(pack,1,(size_t)length,file)==(size_t)length);fclose(file);
    scene3d *scene=scene3d_create(pack,(size_t)length,limited_allocate);
    if(argc>=3&&!strcmp(argv[2],"--reject")){assert(!scene);free(pack);puts("PASS rejected invalid model");return 0;}
    assert(scene);
    check_transparent_component(pack,(size_t)length);
    for(unsigned i=0;i<2;i++){allocations_left=i;assert(!scene3d_create(pack,(size_t)length,limited_allocate));}
    allocations_left=UINT_MAX;
    assert(!scene3d_create(pack,19,malloc));assert(!scene3d_create(pack,(size_t)length-1,malloc));
    pack[0]^=1;assert(!scene3d_create(pack,(size_t)length,malloc));pack[0]^=1;
    assert(!scene3d_resize(scene,0,720));assert(!scene3d_resize(scene,1280,1280));
    assert(scene3d_resize(scene,1280,720));
    uint16_t *pixels=calloc(1280u*720u,2);assert(pixels);
    assert(scene3d_render(scene,pixels,1280,0,false,NULL));uint64_t closed=hash(pixels,1280u*720u);
    assert(scene3d_render(scene,pixels,1280,6.4,false,NULL));uint64_t idle=hash(pixels,1280u*720u);
    allocations_left=0;assert(!scene3d_resize(scene,640,360));allocations_left=UINT_MAX;
    assert(scene3d_render(scene,pixels,1280,6.4,false,NULL));assert(hash(pixels,1280u*720u)==idle);
    assert(closed!=idle);assert(!scene3d_render(scene,pixels,1,0,false,NULL));
    // Compare incremental redraw with a complete redraw at every frame, including
    // shrinking, large jumps in animation time, replay, and blinking/greeting.
    scene3d *reference=scene3d_create(pack,(size_t)length,malloc);assert(reference);
    assert(scene3d_resize(reference,1280,720));
    uint16_t *fresh[2]={malloc(1280u*720u*2),malloc(1280u*720u*2)};
    uint16_t *composed=malloc(1280u*720u*2);assert(fresh[0]&&fresh[1]&&composed);
    memcpy(composed,pixels,1280u*720u*2);
    const double times[]={0,.25,2.1,4.9,6.4,7.2,10.2,1.6,0};
    for(unsigned i=0;i<sizeof(times)/sizeof(times[0]);i++){
        bool greet=(i%3)==2;
        assert(scene3d_render(scene,pixels,1280,times[i],greet,NULL));
        assert(scene3d_render(reference,fresh[i%2],1280,times[i],greet,NULL));
        scene3d_rect changed=scene3d_changed_rect(scene);
        assert(changed.x+changed.width<=1280&&changed.y+changed.height<=720);
        for(unsigned y=changed.y;y<changed.y+changed.height;y++)
            memcpy(composed+y*1280+changed.x,pixels+y*1280+changed.x,changed.width*2);
        assert(!memcmp(pixels,fresh[i%2],1280u*720u*2));
        assert(!memcmp(composed,pixels,1280u*720u*2));
    }
    scene3d_destroy(reference);free(fresh[0]);free(fresh[1]);free(composed);
    assert(scene3d_render(scene,pixels,1280,6.4,false,NULL));
    if(argc>=3){
        file=fopen(argv[2],"wb");assert(file);fprintf(file,"P6\n1280 720\n255\n");
        for(size_t i=0;i<1280u*720u;i++){unsigned c=pixels[i];uint8_t rgb[3]={(uint8_t)(((c>>11)&31)*255/31),(uint8_t)(((c>>5)&63)*255/63),(uint8_t)((c&31)*255/31)};fwrite(rgb,1,3,file);}fclose(file);
    }
    for(unsigned cycle=0;cycle<3;cycle++){
        assert(scene3d_render(scene,pixels,1280,2.1,false,NULL));
        assert(scene3d_render(scene,pixels,1280,6.4,true,NULL));
        assert(scene3d_render(scene,pixels,1280,6.4,false,NULL));assert(hash(pixels,1280u*720u)==idle);
        assert(scene3d_render(scene,pixels,1280,0,false,NULL));assert(hash(pixels,1280u*720u)==closed);
    }
    assert(scene3d_resize(scene,320,180));assert(scene3d_render(scene,pixels,320,6,false,NULL));
    assert(scene3d_resize(scene,720,1280));assert(scene3d_render(scene,pixels,720,6,false,NULL));
    printf("PASS triangles=%u vertices=%u memory=%zu; render/replay/resize/invalid inputs\n",scene3d_triangles(scene),scene3d_vertices(scene),scene3d_memory(scene));
    scene3d_destroy(scene);free(pixels);free(pack);return 0;
}
