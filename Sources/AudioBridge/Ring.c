#include "AudioBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <sys/proc_info.h>
int lc_process_descends_from(int32_t pid,int32_t ancestor) {
  if(ancestor<=1)return 0;
  for(int depth=0;depth<32 && pid>1;depth++){
    if(pid==ancestor)return 1;
    struct proc_bsdinfo info;
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return 0;
    if(info.pbi_ppid==(uint32_t)pid)return 0;
    pid=(int32_t)info.pbi_ppid;
  }
  return 0;
}
#define SLOTS 128
#define FRAMES 8192
typedef struct { float samples[FRAMES]; uint32_t frames; double rate; uint64_t host; } LCSlot;
struct LCRing { LCSlot slots[SLOTS]; _Atomic uint32_t read,write; _Atomic uint64_t dropped; _Atomic int32_t channel_mode; double nanos; int diagnostic; uint32_t captured_channels; uint64_t captured_frames; double channel_energy[16]; double legacy_energy; };
static double time_scale(void) { mach_timebase_info_data_t t; mach_timebase_info(&t); return (double)t.numer/t.denom; }
uint64_t lc_host_nanoseconds(void) { return (uint64_t)(mach_absolute_time()*time_scale()); }
LCRing *lc_ring_create(void) { LCRing *r=calloc(1,sizeof(LCRing)); if(r)r->nanos=time_scale();return r; }
void lc_ring_set_diagnostics(LCRing *r,int enabled){r->diagnostic=enabled;}
uint32_t lc_ring_capture_channels(LCRing *r){return r->captured_channels;}
double lc_ring_capture_legacy_rms(LCRing *r){return r->captured_frames?sqrt(r->legacy_energy/r->captured_frames):0;}
double lc_ring_capture_channel_rms(LCRing *r,uint32_t channel){return channel<16 && r->captured_frames ? sqrt(r->channel_energy[channel]/r->captured_frames):0;}
void lc_ring_destroy(LCRing *r) { free(r); }
void lc_ring_reset(LCRing *r) {r->captured_channels=0;r->captured_frames=0;r->legacy_energy=0;memset(r->channel_energy,0,sizeof(r->channel_energy)); atomic_store(&r->read,0);atomic_store(&r->write,0);atomic_store(&r->dropped,0); }
void lc_ring_set_channel_mode(LCRing *r,int32_t mode){atomic_store(&r->channel_mode,mode);}
static float get(const AudioBufferList *abl,const AudioStreamBasicDescription *f,uint32_t i,uint32_t ch) {
  uint32_t bi=(f->mFormatFlags & kAudioFormatFlagIsNonInterleaved)?ch:0;
  if(bi>=abl->mNumberBuffers)return 0;
  const AudioBuffer *b=&abl->mBuffers[bi];uint32_t n=b->mNumberChannels;
  uint32_t k=(f->mFormatFlags & kAudioFormatFlagIsNonInterleaved)?i:i*n+ch;
  uint32_t bytes=f->mBitsPerChannel/8;
  if(!b->mData || (k+1)*bytes>b->mDataByteSize)return 0;
  if(f->mFormatFlags & kAudioFormatFlagIsBigEndian)return 0;
  if((f->mFormatFlags & kAudioFormatFlagIsFloat)&&bytes==4)return ((float*)b->mData)[k];
  if((f->mFormatFlags & kAudioFormatFlagIsFloat)&&bytes==8)return (float)((double*)b->mData)[k];
  if((f->mFormatFlags & kAudioFormatFlagIsSignedInteger)&&bytes==2)return ((int16_t*)b->mData)[k]/32768.f;
  if((f->mFormatFlags & kAudioFormatFlagIsSignedInteger)&&bytes==4)return ((int32_t*)b->mData)[k]/2147483648.f;
  return 0;
}
int lc_ring_write(LCRing *r,const AudioBufferList *abl,const AudioStreamBasicDescription *f,uint32_t frames,uint64_t host) {
  uint32_t w=atomic_load_explicit(&r->write,memory_order_relaxed),next=(w+1)%SLOTS;
  if(next==atomic_load_explicit(&r->read,memory_order_acquire)||frames>FRAMES){atomic_fetch_add(&r->dropped,frames);return 0;}
  LCSlot *s=&r->slots[w];uint32_t channels=f->mChannelsPerFrame;
  if(!channels || f->mFormatID!=kAudioFormatLinearPCM){atomic_fetch_add(&r->dropped,frames);return 0;}
  double sum=0,energy=0,left=0,right=0;int32_t mode=atomic_load(&r->channel_mode);
  for(uint32_t i=0;i<frames;i++){
    float v=0;
    if(mode==1 || mode==2){uint32_t ch=(mode==2 && channels>1)?1:0;v=get(abl,f,i,ch);}
    else {for(uint32_t c=0;c<channels;c++)v+=get(abl,f,i,c);v/=channels;}
    s->samples[i]=isfinite(v)?v:0;
    if(channels==2){float l=get(abl,f,i,0),rr=get(abl,f,i,1);sum+=v*v;left+=l*l;right+=rr*rr;energy+=l*l+rr*rr;}
  }
  r->captured_channels=channels;
  if(r->diagnostic){for(uint32_t i=0;i<frames;i++){double mixed=0;for(uint32_t c=0;c<channels;c++){double x=get(abl,f,i,c);if(!isfinite(x))x=0;if(c<16)r->channel_energy[c]+=x*x;mixed+=x;}mixed/=channels;r->legacy_energy+=mixed*mixed;}r->captured_frames+=frames;}
  // Protect stereo speech against near-total phase cancellation.
  if(mode==0 && channels==2 && energy>1e-10 && sum<energy*.005){uint32_t c=left>=right?0:1;for(uint32_t i=0;i<frames;i++)s->samples[i]=get(abl,f,i,c);}
  s->frames=frames;s->rate=f->mSampleRate;s->host=(uint64_t)(host*r->nanos);
  atomic_store_explicit(&r->write,next,memory_order_release);return 1;
}
uint32_t lc_ring_read(LCRing *r,float *mono,uint32_t cap,double *rate,uint64_t *host){
  uint32_t rd=atomic_load_explicit(&r->read,memory_order_relaxed);
  if(rd==atomic_load_explicit(&r->write,memory_order_acquire))return 0;
  LCSlot *s=&r->slots[rd];uint32_t n=s->frames<cap?s->frames:cap;
  memcpy(mono,s->samples,n*sizeof(float));*rate=s->rate;*host=s->host;
  atomic_store_explicit(&r->read,(rd+1)%SLOTS,memory_order_release);return n;
}
uint64_t lc_ring_dropped(LCRing *r){return atomic_load(&r->dropped);}
