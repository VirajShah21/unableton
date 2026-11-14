#ifndef UNABLETON_DSP_H
#define UNABLETON_DSP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct UBTimeline UBTimeline;
typedef struct UBTrack UBTrack;
typedef struct UBSample UBSample;
typedef struct UBScheduler UBScheduler;
typedef struct UBRecordingRing UBRecordingRing;
typedef struct { int64_t frame; uint64_t note; uint8_t pitch, velocity, on; } UBEvent;
typedef struct {
    int mode, waveform;
    double attack, decay, sustain, release, cutoff, resonance, detune, lfoRate, lfoDepth, drive;
} UBSynthParameters;
UBTimeline *ub_timeline_create(double sampleRate, int64_t startFrame, int loop, int64_t loopStart, int64_t loopEnd);
void ub_timeline_destroy(UBTimeline *timeline);
int64_t ub_timeline_current_frame(const UBTimeline *timeline);
void ub_timeline_begin_render(UBTimeline *timeline, double sampleTime, uint64_t hostTime, uint32_t frames);
double ub_timeline_beat_for_host_time(const UBTimeline *timeline, uint64_t hostTime, double tempo);
UBTrack *ub_track_create(UBTimeline *timeline, UBSynthParameters parameters, const UBEvent *events, uint32_t count);
void ub_track_destroy(UBTrack *track);
void ub_track_render(UBTrack *track, double sampleTime, uint32_t frames, float *left, float *right);
UBSample *ub_sample_create(const float *left, const float *right, uint64_t frames, double sampleRate);
void ub_sample_destroy(UBSample *sample);
void ub_track_add_audio(UBTrack *track, UBSample *sample, int64_t startFrame, int64_t endFrame, double offsetSeconds);
UBScheduler *ub_scheduler_create(void *mixerAudioUnit, UBTimeline *timeline);
int ub_scheduler_add_sampler(UBScheduler *scheduler, void *samplerAudioUnit, const UBEvent *events, uint32_t count);
void ub_scheduler_destroy(UBScheduler *scheduler);
UBRecordingRing *ub_record_ring_create(uint32_t channels, uint32_t maximumFrames, uint32_t slots);
void ub_record_ring_destroy(UBRecordingRing *ring);
int ub_record_ring_push(UBRecordingRing *ring, const float *left, const float *right, uint32_t frames);
int ub_record_ring_pop(UBRecordingRing *ring, float *left, float *right, uint32_t *frames);
int ub_record_ring_overflowed(const UBRecordingRing *ring);
void ub_record_ring_abort(UBRecordingRing *ring);
void ub_record_ring_set_first_host_time(UBRecordingRing *ring, uint64_t hostTime);
uint64_t ub_record_ring_first_host_time(const UBRecordingRing *ring);
#ifdef __cplusplus
}
#endif
#endif
