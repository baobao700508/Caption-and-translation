#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct LCRing LCRing;
LCRing *lc_ring_create(void);
// Diagnostic counters are read only after the capture producer has stopped.
void lc_ring_set_diagnostics(LCRing *ring, int enabled);
uint32_t lc_ring_capture_channels(LCRing *ring);
double lc_ring_capture_legacy_rms(LCRing *ring);
double lc_ring_capture_channel_rms(LCRing *ring, uint32_t channel);
void lc_ring_destroy(LCRing *ring);
void lc_ring_reset(LCRing *ring);
void lc_ring_set_channel_mode(LCRing *ring, int32_t mode);
int lc_ring_write(LCRing *ring, const AudioBufferList *buffers, const AudioStreamBasicDescription *format, uint32_t frames, uint64_t hostTime);
uint32_t lc_ring_read(LCRing *ring, float *mono, uint32_t capacity, double *rate, uint64_t *hostNanoseconds);
uint64_t lc_ring_dropped(LCRing *ring);
uint64_t lc_host_nanoseconds(void);
int lc_process_descends_from(int32_t pid, int32_t ancestor);
typedef struct LCNoise LCNoise;
LCNoise *lc_noise_create(void);
void lc_noise_destroy(LCNoise *processor);
int lc_noise_process(LCNoise *processor, float *mono480);
#ifdef __cplusplus
}
#endif
