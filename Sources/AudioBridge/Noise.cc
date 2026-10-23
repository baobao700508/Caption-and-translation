#include "AudioBridge.h"
#include "api/audio/audio_processing.h"
#include <new>
struct LCNoise { rtc::scoped_refptr<webrtc::AudioProcessing> apm; };
LCNoise *lc_noise_create(void) {
  auto *p=new(std::nothrow) LCNoise;
  if(!p)return nullptr;
  p->apm=webrtc::AudioProcessingBuilder().Create();
  if(!p->apm){delete p;return nullptr;}
  webrtc::AudioProcessing::Config c;
  c.noise_suppression.enabled=true;
  c.noise_suppression.level=webrtc::AudioProcessing::Config::NoiseSuppression::kLow;
  c.echo_canceller.enabled=false;c.gain_controller1.enabled=false;c.gain_controller2.enabled=false;
  c.high_pass_filter.enabled=false;
  p->apm->ApplyConfig(c);
  if(p->apm->Initialize()!=0){delete p;return nullptr;}
  return p;
}
void lc_noise_destroy(LCNoise *p){delete p;}
int lc_noise_process(LCNoise *p,float *mono){
  if(!p)return -1;
  const float *in[]={mono};float *out[]={mono};webrtc::StreamConfig stream(48000,1);
  return p->apm->ProcessStream(in,stream,stream,out);
}
