#include "include/UnabletonDSP.h"
#include <atomic>
#include <cstring>
#include <vector>

struct UBRecordingRing {
    uint32_t channels, maximumFrames, slots;
    std::vector<float> samples;
    std::vector<uint32_t> lengths;
    std::atomic<uint64_t> write{0},read{0};
    std::atomic<bool> interrupted{false};
    std::atomic<uint64_t> firstHostTime{0};
};
extern "C" {
UBRecordingRing *ub_record_ring_create(uint32_t channels,uint32_t maximumFrames,uint32_t slots) {
    auto *ring=new UBRecordingRing;
    ring->channels=channels;ring->maximumFrames=maximumFrames;ring->slots=slots;
    ring->samples.resize(uint64_t(channels)*maximumFrames*slots);ring->lengths.resize(slots);
    return ring;
}
void ub_record_ring_destroy(UBRecordingRing *ring) {delete ring;}
int ub_record_ring_push(UBRecordingRing *ring,const float *left,const float *right,uint32_t frames) {
    if(ring->interrupted.load(std::memory_order_relaxed)) return 0;
    const auto write=ring->write.load(std::memory_order_relaxed);
    if(frames>ring->maximumFrames || write-ring->read.load(std::memory_order_acquire)>=ring->slots) {
        ring->interrupted.store(true,std::memory_order_release);return 0;
    }
    const uint64_t slot=write%ring->slots;
    float *destination=ring->samples.data()+slot*ring->maximumFrames*ring->channels;
    std::memcpy(destination,left,frames*sizeof(float));
    if(ring->channels==2) std::memcpy(destination+ring->maximumFrames,right,frames*sizeof(float));
    ring->lengths[slot]=frames;
    ring->write.store(write+1,std::memory_order_release);
    return 1;
}
int ub_record_ring_pop(UBRecordingRing *ring,float *left,float *right,uint32_t *frames) {
    const auto read=ring->read.load(std::memory_order_relaxed);
    if(read==ring->write.load(std::memory_order_acquire)) return 0;
    const uint64_t slot=read%ring->slots;
    *frames=ring->lengths[slot];
    const float *source=ring->samples.data()+slot*ring->maximumFrames*ring->channels;
    std::memcpy(left,source,*frames*sizeof(float));
    if(ring->channels==2) std::memcpy(right,source+ring->maximumFrames,*frames*sizeof(float));
    ring->read.store(read+1,std::memory_order_release);
    return 1;
}
int ub_record_ring_overflowed(const UBRecordingRing *ring) {return ring->interrupted.load(std::memory_order_acquire)?1:0;}
void ub_record_ring_abort(UBRecordingRing *ring) {ring->interrupted.store(true,std::memory_order_release);}
void ub_record_ring_set_first_host_time(UBRecordingRing *ring,uint64_t hostTime) {
    uint64_t expected=0;
    if(hostTime) ring->firstHostTime.compare_exchange_strong(expected,hostTime,std::memory_order_release,std::memory_order_relaxed);
}
uint64_t ub_record_ring_first_host_time(const UBRecordingRing *ring) {return ring->firstHostTime.load(std::memory_order_acquire);}
}
