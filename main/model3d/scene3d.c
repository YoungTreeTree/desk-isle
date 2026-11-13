#include "scene3d.h"
#include "cJSON.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define NODE_MAX 64
#define MESH_MAX 64
#define MATERIAL_MAX 32
#define TEXTURE_MAX 8
#define CLIP_MAX 8
#define TRACK_MAX 128
#define PACK_MAX (8u*1024u*1024u)

typedef struct { float p[3],q[4],s[3],weights[4],world[16]; int parent; unsigned visited; } node3d;
typedef struct { int node,material; unsigned count,index_count,morph_count; const float *p,*n,*uv,*morph[4]; const uint32_t *indices; } mesh3d;
typedef struct { float color[3]; int texture; bool two_sided; } material3d;
typedef struct { unsigned width,height; const uint16_t *pixels; } texture3d;
typedef struct { unsigned node,path,size,count; const float *times,*values; bool step; } track3d;
typedef struct { char name[32]; unsigned count; float duration; track3d tracks[TRACK_MAX]; } clip3d;
typedef struct { float x,y,z,u,v,light; } projected;
struct scene3d {
    scene3d_alloc allocate;
    const uint8_t *bytes; size_t length;
    unsigned node_count,mesh_count,material_count,texture_count,clip_count,vertex_count,triangle_count,max_vertices;
    unsigned width,height;
    node3d base[NODE_MAX],nodes[NODE_MAX];
    mesh3d meshes[MESH_MAX]; material3d materials[MATERIAL_MAX]; texture3d textures[TEXTURE_MAX];
    clip3d clips[CLIP_MAX];
    projected *projected;
    float *depth;
    int appear,idle,blink,greet;
    uint64_t (*clock_us)(void);
    scene3d_profile profile;
    scene3d_rect occupied, changed;
    const uint16_t *previous_output;
    unsigned previous_stride;
};

static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static const cJSON *field(const cJSON *o,const char *k) { return cJSON_GetObjectItemCaseSensitive(o,k); }
static int integer(const cJSON *o,const char *k,int missing) {
    const cJSON *v=field(o,k);
    if (!cJSON_IsNumber(v)||!isfinite(v->valuedouble)||v->valuedouble<INT_MIN||v->valuedouble>INT_MAX||floor(v->valuedouble)!=v->valuedouble) return missing;
    return (int)v->valuedouble;
}
static unsigned count(const cJSON *o) { return cJSON_IsArray(o)?(unsigned)cJSON_GetArraySize(o):0; }
static bool floats(const cJSON *o,float *v,unsigned n) {
    if (count(o)!=n) return false;
    for (unsigned i=0;i<n;i++) { const cJSON *x=cJSON_GetArrayItem(o,i); if(!cJSON_IsNumber(x)||!isfinite(x->valuedouble)||fabs(x->valuedouble)>10000) return false; v[i]=(float)x->valuedouble; }
    return true;
}
static const void *range(scene3d *s,int offset,size_t bytes) {
    if (offset<0||offset%4||!bytes||(size_t)offset>s->length||bytes>s->length-(size_t)offset) return NULL;
    return s->bytes+offset;
}
static const float *float_range(scene3d *s,int offset,size_t n) {
    const float *p=range(s,offset,n*sizeof(float));
    if (!p) return NULL;
    for (size_t i=0;i<n;i++) if (!isfinite(p[i])||fabsf(p[i])>100000) return NULL;
    return p;
}
static bool parse(scene3d *s,const cJSON *root) {
    if (integer(root,"v",0)!=1) return false;
    const cJSON *nodes=field(root,"nodes"),*meshes=field(root,"meshes"),*materials=field(root,"materials"),*textures=field(root,"textures"),*clips=field(root,"clips");
    s->node_count=count(nodes);s->mesh_count=count(meshes);s->material_count=count(materials);s->texture_count=count(textures);s->clip_count=count(clips);
    if (!s->node_count||s->node_count>NODE_MAX||!s->mesh_count||s->mesh_count>MESH_MAX||!s->material_count||s->material_count>MATERIAL_MAX||s->texture_count>TEXTURE_MAX||s->clip_count>CLIP_MAX) return false;
    for(unsigned i=0;i<s->node_count;i++) {
        const cJSON *o=cJSON_GetArrayItem(nodes,i);node3d *n=&s->base[i];
        n->parent=integer(o,"parent",INT_MAX);
        if(n->parent < -1||n->parent >= (int)s->node_count||n->parent==(int)i||!floats(field(o,"p"),n->p,3)||!floats(field(o,"q"),n->q,4)||!floats(field(o,"s"),n->s,3)) return false;
        const cJSON *weights=field(o,"weights");if(count(weights)>4||!floats(weights,n->weights,count(weights))) return false;
    }
    for(unsigned i=0;i<s->node_count;i++) {
        int cursor=i;unsigned length=0;
        while(cursor>=0) { if(++length>s->node_count) return false;cursor=s->base[cursor].parent; }
    }
    for(unsigned i=0;i<s->texture_count;i++) {
        const cJSON *o=cJSON_GetArrayItem(textures,i);texture3d *t=&s->textures[i];
        int w=integer(o,"width",0),h=integer(o,"height",0);
        if(w<1||w>512||h<1||h>512) return false;
        t->width=w;t->height=h;t->pixels=range(s,integer(o,"offset",-1),(size_t)w*h*2);
        if(!t->pixels) return false;
    }
    for(unsigned i=0;i<s->material_count;i++) {
        const cJSON *o=cJSON_GetArrayItem(materials,i);material3d *m=&s->materials[i];
        m->texture=integer(o,"texture",INT_MAX);m->two_sided=cJSON_IsTrue(field(o,"doubleSided"));
        if(m->texture < -1||m->texture >= (int)s->texture_count||!floats(field(o,"color"),m->color,3)) return false;
        for(unsigned j=0;j<3;j++) { if(m->color[j]<0||m->color[j]>1) return false; m->color[j]=powf(m->color[j],1.f/2.2f); }
    }
    for(unsigned i=0;i<s->mesh_count;i++) {
        const cJSON *o=cJSON_GetArrayItem(meshes,i);mesh3d *m=&s->meshes[i];
        m->node=integer(o,"node",-1);m->material=integer(o,"material",-1);
        int vertices=integer(o,"count",0),indices=integer(o,"indexCount",0);
        if(m->node<0||m->node>=(int)s->node_count||m->material<0||m->material>=(int)s->material_count||vertices<1||vertices>100000||indices<3||indices>300000||indices%3) return false;
        m->count=vertices;m->index_count=indices;s->vertex_count+=vertices;s->triangle_count+=indices/3;
        if(s->vertex_count>150000||s->triangle_count>100000) return false;
        if(m->count>s->max_vertices) s->max_vertices=m->count;
        m->p=float_range(s,integer(o,"position",-1),m->count*3);m->n=float_range(s,integer(o,"normal",-1),m->count*3);
        m->indices=range(s,integer(o,"indices",-1),m->index_count*4);
        if(!m->p||!m->n||!m->indices) return false;
        for(unsigned j=0;j<m->index_count;j++) if(m->indices[j]>=m->count) return false;
        int uv=integer(o,"uv",-1);if(uv!=-1) { m->uv=float_range(s,uv,m->count*2);if(!m->uv)return false; }
        if(s->materials[m->material].texture>=0&&!m->uv) return false;
        const cJSON *morphs=field(o,"morphs");m->morph_count=count(morphs);if(m->morph_count>4)return false;
        for(unsigned j=0;j<m->morph_count;j++) {
            const cJSON *v=cJSON_GetArrayItem(morphs,j);
            if(!cJSON_IsNumber(v)||v->valuedouble<0||v->valuedouble>PACK_MAX||floor(v->valuedouble)!=v->valuedouble) return false;
            m->morph[j]=float_range(s,(int)v->valuedouble,m->count*3);if(!m->morph[j])return false;
        }
    }
    s->appear=s->idle=s->blink=s->greet=-1;
    for(unsigned i=0;i<s->clip_count;i++) {
        const cJSON *o=cJSON_GetArrayItem(clips,i),*name=field(o,"name"),*duration=field(o,"duration"),*tracks=field(o,"tracks");clip3d *c=&s->clips[i];
        if(!cJSON_IsString(name)||!cJSON_IsNumber(duration)||!isfinite(duration->valuedouble)||duration->valuedouble<=0||duration->valuedouble>600) return false;
        strncpy(c->name,name->valuestring,sizeof(c->name)-1);c->duration=duration->valuedouble;c->count=count(tracks);if(c->count>TRACK_MAX)return false;
        if(!strcmp(c->name,"appear"))s->appear=i;else if(!strcmp(c->name,"idle"))s->idle=i;else if(!strcmp(c->name,"blink"))s->blink=i;else if(!strcmp(c->name,"greet"))s->greet=i;
        for(unsigned j=0;j<c->count;j++) {
            const cJSON *o=cJSON_GetArrayItem(tracks,j);track3d *t=&c->tracks[j];
            int node=integer(o,"node",-1),path=integer(o,"path",-1),size=integer(o,"size",0),n=integer(o,"count",0);
            if(node<0||node>=(int)s->node_count||path<0||path>3||size<1||size>4||n<1||n>4096||
               (path<3&&size!=(path==1?4:3))) return false;
            t->node=node;t->path=path;t->size=size;t->count=n;t->step=cJSON_IsTrue(field(o,"step"));
            t->times=float_range(s,integer(o,"times",-1),n);t->values=float_range(s,integer(o,"values",-1),(size_t)n*size);
            if(!t->times||!t->values||t->times[0]<0||t->times[n-1]>c->duration+.001f) return false;
            for(int k=1;k<n;k++)if(t->times[k]<=t->times[k-1])return false;
        }
    }
    return true;
}

scene3d *scene3d_create(const uint8_t *pack,size_t length,scene3d_alloc allocate) {
    if(!pack||length<20||length>PACK_MAX||memcmp(pack,"D3M1",4)||u32(pack+4)!=1) return NULL;
    size_t json=u32(pack+8),binary=u32(pack+12);
    if(!json||json%4||json>256u*1024u||json>length-16||binary!=length-16-json||((uintptr_t)(pack+16+json)%4))return NULL;
    // Bound parser nesting before allocating cJSON's tree.
    unsigned depth=0;bool quoted=false;
    for(size_t i=16;i<16+json;i++){uint8_t c=pack[i];if(quoted&&c=='\\'){i++;continue;}if(c=='"'){quoted=!quoted;continue;}if(!quoted){if(c=='['||c=='{'){if(++depth>16)return NULL;}if(c==']'||c=='}'){if(!depth)return NULL;depth--;}}}
    if(depth||quoted)return NULL;
    const char *end=NULL;cJSON *root=cJSON_ParseWithLengthOpts((const char *)pack+16,json,&end,false);if(!root)return NULL;
    if(end<(const char *)pack+16||end>(const char *)pack+16+json){cJSON_Delete(root);return NULL;}
    while(end<(const char *)pack+16+json){if(*end!=' '&&*end!='\r'&&*end!='\n'&&*end!='\t'){cJSON_Delete(root);return NULL;}end++;}
    scene3d *s=allocate(sizeof(*s));if(!s){cJSON_Delete(root);return NULL;}memset(s,0,sizeof(*s));s->allocate=allocate;s->bytes=pack+16+json;s->length=binary;
    bool ok=parse(s,root);cJSON_Delete(root);
    if(ok) s->projected=allocate(s->max_vertices*sizeof(projected));
    if(!ok||!s->projected){scene3d_destroy(s);return NULL;}return s;
}
void scene3d_destroy(scene3d *s){if(!s)return;free(s->projected);free(s->depth);free(s);}
bool scene3d_resize(scene3d *s,unsigned width,unsigned height){
    if(!s||!width||!height||width>1280||height>1280||(size_t)width*height>1280u*720u)return false;
    if(s->width==width&&s->height==height)return true;
    float *next=s->allocate((size_t)width*height*sizeof(float));if(!next)return false;
    free(s->depth);s->depth=next;s->width=width;s->height=height;s->previous_output=NULL;return true;
}
unsigned scene3d_triangles(const scene3d *s){return s?s->triangle_count:0;}
unsigned scene3d_vertices(const scene3d *s){return s?s->vertex_count:0;}
size_t scene3d_memory(const scene3d *s){return s?sizeof(*s)+s->max_vertices*sizeof(projected)+(size_t)s->width*s->height*sizeof(float):0;}
void scene3d_set_clock(scene3d *s,uint64_t (*clock_us)(void)){if(s)s->clock_us=clock_us;}
void scene3d_reset_profile(scene3d *s){if(s)s->profile=(scene3d_profile){0};}
scene3d_profile scene3d_get_profile(const scene3d *s){return s?s->profile:(scene3d_profile){0};}
static uint64_t clock_us(const scene3d *s){return s->clock_us?s->clock_us():0;}
scene3d_rect scene3d_changed_rect(const scene3d *s){return s?s->changed:(scene3d_rect){0};}
static scene3d_rect union_rect(scene3d_rect a,scene3d_rect b){
    if(!a.width||!a.height)return b;
    if(!b.width||!b.height)return a;
    unsigned x=a.x<b.x?a.x:b.x,y=a.y<b.y?a.y:b.y;
    unsigned right=a.x+a.width>b.x+b.width?a.x+a.width:b.x+b.width;
    unsigned bottom=a.y+a.height>b.y+b.height?a.y+a.height:b.y+b.height;
    return (scene3d_rect){x,y,right-x,bottom-y};
}

bool scene3d_copy_alpha(const scene3d *s,uint8_t *alpha,unsigned stride,unsigned scale){
    if(!s||!alpha||!s->depth||!s->previous_output||(scale!=1&&scale!=2&&scale!=4)||stride<s->width*scale)return false;
    const scene3d_rect r=s->changed;
    for(unsigned y=r.y;y<r.y+r.height;y++){
        const float *depth=s->depth+(size_t)y*s->width;
        uint8_t *row=alpha+(size_t)y*scale*stride;
        for(unsigned x=r.x;x<r.x+r.width;x++)memset(row+x*scale,depth[x]>0?255:0,scale);
        for(unsigned dy=1;dy<scale;dy++)memcpy(row+(size_t)dy*stride+r.x*scale,row+r.x*scale,r.width*scale);
    }
    return true;
}

static void clip(scene3d *s,int index,float seconds){
    if(index<0)return;
    const clip3d *c=&s->clips[index];
    for(unsigned k=0;k<c->count;k++) {
        const track3d *t=&c->tracks[k];unsigned a=0,b=t->count-1;
        while(a+1<b){unsigned middle=(a+b)/2;if(t->times[middle]>seconds)b=middle;else a=middle;}
        if(seconds<=t->times[0])a=b=0;else if(seconds>=t->times[t->count-1])a=b=t->count-1;
        float f=a==b||t->step?0:(seconds-t->times[a])/(t->times[b]-t->times[a]);
        const float *left=t->values+a*t->size,*right=t->values+b*t->size;node3d *n=&s->nodes[t->node];
        float *out=t->path==0?n->p:t->path==1?n->q:t->path==2?n->s:n->weights;
        float sign=1;if(t->path==1){float dot=0;for(unsigned i=0;i<4;i++)dot+=left[i]*right[i];if(dot<0)sign=-1;}
        for(unsigned i=0;i<t->size;i++)out[i]=left[i]+(right[i]*sign-left[i])*f;
        if(t->path==1){float mag=0;for(unsigned i=0;i<4;i++)mag+=out[i]*out[i];if(mag>1e-12f){mag=1/sqrtf(mag);for(unsigned i=0;i<4;i++)out[i]*=mag;}}
    }
}
static void transform(scene3d *s,unsigned index){
    node3d *n=&s->nodes[index];if(n->visited)return;n->visited=1;
    float x=n->q[0],y=n->q[1],z=n->q[2],w=n->q[3];
    float a[16]={ (1-2*(y*y+z*z))*n->s[0],2*(x*y+z*w)*n->s[0],2*(x*z-y*w)*n->s[0],0,
        2*(x*y-z*w)*n->s[1],(1-2*(x*x+z*z))*n->s[1],2*(y*z+x*w)*n->s[1],0,
        2*(x*z+y*w)*n->s[2],2*(y*z-x*w)*n->s[2],(1-2*(x*x+y*y))*n->s[2],0,n->p[0],n->p[1],n->p[2],1};
    if(n->parent<0){memcpy(n->world,a,sizeof(a));return;}
    transform(s,(unsigned)n->parent);const float *p=s->nodes[n->parent].world;
    for(unsigned c=0;c<4;c++)for(unsigned r=0;r<4;r++)n->world[c*4+r]=p[r]*a[c*4]+p[4+r]*a[c*4+1]+p[8+r]*a[c*4+2]+p[12+r]*a[c*4+3];
}
static float edge(const projected *a,const projected *b,float x,float y){return (x-a->x)*(b->y-a->y)-(y-a->y)*(b->x-a->x);}
static int imin(int a,int b){return a<b?a:b;}
static float fclamp(float x,float a,float b){return fminf(b,fmaxf(a,x));}
static __attribute__((noinline)) void triangle(scene3d *s,uint16_t *restrict output,unsigned stride,const projected *a,const projected *b,const projected *c,const material3d *m){
    if(a->z<=0||b->z<=0||c->z<=0)return;
    float area=edge(a,b,c->x,c->y);if(!isfinite(area)||fabsf(area)<.0001f||(!m->two_sided&&area<=0))return;
    if(area<0){const projected *temp=b;b=c;c=temp;area=-area;}
    float min_x=fminf(a->x,fminf(b->x,c->x)),max_x=fmaxf(a->x,fmaxf(b->x,c->x));
    float min_y=fminf(a->y,fminf(b->y,c->y)),max_y=fmaxf(a->y,fmaxf(b->y,c->y));
    if(max_x<0||max_y<0||min_x>=s->width||min_y>=s->height)return;
    // Clip before conversion. Positive truncation is floor; one extra sample at
    // the upper edge is rejected by the barycentric coverage check.
    int x0=(int)fmaxf(0,min_x),x1=imin((int)s->width-1,(int)fminf((float)s->width,max_x)+1);
    int y0=(int)fmaxf(0,min_y),y1=imin((int)s->height-1,(int)fminf((float)s->height,max_y)+1);
    float inv=1/area,dx0=(c->y-b->y)*inv,dy0=-(c->x-b->x)*inv,dx1=(a->y-c->y)*inv,dy1=-(a->x-c->x)*inv;
    float row0=edge(b,c,x0+.5f,y0+.5f)*inv,row1=edge(c,a,x0+.5f,y0+.5f)*inv;
    const texture3d *texture=m->texture<0?NULL:&s->textures[m->texture];
    // Depth and projected vertices are separate allocations. Snapshot invariants
    // before writing depth so the compiler need not reload PSRAM vertex/material
    // fields at every pixel (their float pointers could otherwise alias).
    float *restrict depth=s->depth;
    const float az=a->z,bz=b->z,cz=c->z,au=a->u,bu=b->u,cu=c->u,av=a->v,bv=b->v,cv=c->v;
    const float al=a->light,bl=b->light,cl=c->light,mr=m->color[0],mg=m->color[1],mb=m->color[2];
    for(int y=y0;y<=y1;y++,row0+=dy0,row1+=dy1){
        float w0=row0,w1=row1;size_t zoffset=(size_t)y*s->width+x0,offset=(size_t)y*stride+x0;
        for(int x=x0;x<=x1;x++,w0+=dx0,w1+=dx1,zoffset++,offset++){
            float w2=1-w0-w1;if(w0<-.00001f||w1<-.00001f||w2<-.00001f)continue;
            float iz=w0*az+w1*bz+w2*cz;if(iz<=depth[zoffset])continue;
            float light=fclamp(w0*al+w1*bl+w2*cl,.2f,1.f);
            unsigned r=31,g=63,blue=31;
            if(texture){float z=1/iz,u=(w0*au+w1*bu+w2*cu)*z,v=(w0*av+w1*bv+w2*cv)*z;
                // Most glTF UVs already lie in the first repeat. Avoid two libm
                // calls for every covered pixel while retaining repeat semantics.
                if(u<0||u>=1)u-=floorf(u);
                if(v<0||v>=1)v-=floorf(v);
                unsigned tx=(unsigned)(u*texture->width),ty=(unsigned)(v*texture->height);
                if(tx>=texture->width)tx=texture->width-1;
                if(ty>=texture->height)ty=texture->height-1;
                uint16_t color=texture->pixels[ty*texture->width+tx];r=color>>11;g=(color>>5)&63;blue=color&31;}
            r=(unsigned)(r*mr*light);g=(unsigned)(g*mg*light);blue=(unsigned)(blue*mb*light);
            output[offset]=(uint16_t)((r<<11)|(g<<5)|blue);depth[zoffset]=iz;
        }
    }
}
bool scene3d_render(scene3d *s,uint16_t *output,unsigned stride,double seconds,bool greeting,void(*cooperate)(void)){
    if(!s||!output||!s->depth||stride<s->width||!isfinite(seconds)||seconds<0)return false;
    uint64_t at=clock_us(s),next;
    memcpy(s->nodes,s->base,s->node_count*sizeof(node3d));
    float appearance=s->appear<0?0:s->clips[s->appear].duration;
    if(seconds<appearance)clip(s,s->appear,(float)seconds);
    else {clip(s,s->appear,appearance);double t=seconds-appearance;
        if(s->idle>=0)clip(s,s->idle,(float)fmod(t,s->clips[s->idle].duration));
        if(greeting&&s->greet>=0)clip(s,s->greet,(float)fmod(t,s->clips[s->greet].duration));
        if(s->blink>=0){float blink=(float)fmod(t,4.8);if(blink<s->clips[s->blink].duration)clip(s,s->blink,blink);}}
    for(unsigned i=0;i<s->node_count;i++){
        transform(s,i);
        for(unsigned j=0;j<16;j++)if(!isfinite(s->nodes[i].world[j])||fabsf(s->nodes[i].world[j])>1000000.f)return false;
    }
    next=clock_us(s);s->profile.animation_us+=next-at;at=next;
    const bool first=s->previous_output!=output||s->previous_stride!=stride;
    const scene3d_rect old=s->occupied;
    const scene3d_rect clear=first?(scene3d_rect){0,0,s->width,s->height}:old;
    // Outside the preceding frame's geometry, both color and depth are already
    // background. Clearing the old footprint is sufficient even when it moves.
    for(unsigned y=clear.y;y<clear.y+clear.height;y++){
        memset(s->depth+(size_t)y*s->width+clear.x,0,clear.width*sizeof(float));
        uint16_t *row=output+(size_t)y*stride+clear.x;
        for(unsigned x=0;x<clear.width;x++)row[x]=0xef9e;
    }
    float left=(float)s->width,top=(float)s->height,right=0,bottom=0;
    next=clock_us(s);s->profile.clear_us+=next-at;at=next;
    // Same framing as the reviewed browser model. Portrait backs off to fit the ball and full jump.
    const float yaw=.35f,pitch=.24f,cy=cosf(yaw),sy=sinf(yaw),cp=cosf(pitch),sp=sinf(pitch);
    const float focal=(float)s->height/(2*tanf(35.f*3.14159265f/360.f));
    const float distance=s->width<s->height?13.5f:9.8f;
    for(unsigned mi=0;mi<s->mesh_count;mi++){
        const mesh3d *m=&s->meshes[mi];const node3d *node=&s->nodes[m->node];const float *w=node->world;
        unsigned active_morphs[4],morph_count=0;
        for(unsigned k=0;k<m->morph_count;k++)if(node->weights[k]!=0)active_morphs[morph_count++]=k;
        for(unsigned i=0;i<m->count;i++){
            float p[3]={m->p[i*3],m->p[i*3+1],m->p[i*3+2]};
            for(unsigned j=0;j<morph_count;j++){unsigned k=active_morphs[j];for(unsigned d=0;d<3;d++)p[d]+=m->morph[k][i*3+d]*node->weights[k];}
            float x=w[0]*p[0]+w[4]*p[1]+w[8]*p[2]+w[12],y=w[1]*p[0]+w[5]*p[1]+w[9]*p[2]+w[13]-1.65f,z=w[2]*p[0]+w[6]*p[1]+w[10]*p[2]+w[14];
            float vx=cy*x-sy*z,vy=-sy*sp*x+cp*y-cy*sp*z,depth=distance-(sy*cp*x+sp*y+cy*cp*z);
            projected *v=&s->projected[i];v->z=depth>.1f?1/depth:0;v->x=s->width*.5f+vx*focal*v->z;v->y=s->height*.5f-vy*focal*v->z;
            if(!isfinite(v->x)||!isfinite(v->y)||fabsf(v->x)>1000000.f||fabsf(v->y)>1000000.f)v->z=0;
            if(v->z>0){left=fminf(left,v->x);top=fminf(top,v->y);right=fmaxf(right,v->x);bottom=fmaxf(bottom,v->y);}
            const float *normal=m->n+i*3;float nx=w[0]*normal[0]+w[4]*normal[1]+w[8]*normal[2],ny=w[1]*normal[0]+w[5]*normal[1]+w[9]*normal[2],nz=w[2]*normal[0]+w[6]*normal[1]+w[10]*normal[2];
            float mag=sqrtf(nx*nx+ny*ny+nz*nz);v->light=.65f+.35f*fmaxf(0,mag>1e-8f?(-.3f*nx+.8f*ny+.52f*nz)/mag:0);
            v->u=m->uv?m->uv[i*2]*v->z:0;v->v=m->uv?m->uv[i*2+1]*v->z:0;
        }
        next=clock_us(s);s->profile.vertex_us+=next-at;at=next;
        for(unsigned i=0;i<m->index_count;i+=3){
            triangle(s,output,stride,&s->projected[m->indices[i]],&s->projected[m->indices[i+1]],&s->projected[m->indices[i+2]],&s->materials[m->material]);
            if(cooperate&&i%6144==0)cooperate();
        }
        next=clock_us(s);s->profile.raster_us+=next-at;at=next;
    }
    unsigned x0=(unsigned)fclamp(left-2,0,(float)s->width),y0=(unsigned)fclamp(top-2,0,(float)s->height);
    unsigned x1=(unsigned)fclamp(right+3,0,(float)s->width),y1=(unsigned)fclamp(bottom+3,0,(float)s->height);
    s->occupied=x1>x0&&y1>y0?(scene3d_rect){x0,y0,x1-x0,y1-y0}:(scene3d_rect){0};
    s->changed=first?clear:union_rect(old,s->occupied);
    s->previous_output=output;s->previous_stride=stride;
    ++s->profile.frames;
    return true;
}
