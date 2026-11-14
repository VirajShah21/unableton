#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <Block.h>
#include "Timeline.hpp"
#include <algorithm>
#include <vector>

struct SamplerSchedule {
    AUScheduleMIDIEventBlock send;
    std::vector<UBEvent> events;
    std::vector<UBSpan> spans;
    size_t cursor=0;
    int64_t previous=INT64_MIN;
    void midi(int64_t offset,uint8_t status,uint8_t pitch,uint8_t velocity) {
        uint8_t bytes[3]={status,pitch,velocity};
        send(AUEventSampleTimeImmediate+offset,0,3,bytes);
    }
    void reset(int64_t frame,int64_t offset) {
        midi(offset,0xb0,123,0);
        cursor=std::lower_bound(events.begin(),events.end(),frame,[](auto &e,int64_t f){return e.frame<f;})-events.begin();
        for(const auto &span: spans) if(span.start.frame<frame && span.end>frame) midi(offset,0x90,span.start.pitch,span.start.velocity);
    }
};
struct UBScheduler {
    AUAudioUnit *mixer;
    NSInteger token;
    UBTimeline *timeline;
    std::vector<SamplerSchedule> samplers;
    void render(double sampleTime,uint64_t hostTime,uint32_t frames) {
        ub_timeline_begin_render(timeline,sampleTime,hostTime,frames);
        for(auto &s:samplers) for(uint32_t i=0;i<frames;++i) {
            const int64_t frame=timeline->projectFrame(sampleTime+i);
            if(frame!=s.previous+1) s.reset(frame,i);
            while(s.cursor<s.events.size() && s.events[s.cursor].frame<=frame) {
                const auto &event=s.events[s.cursor++];
                s.midi(i,event.on?0x90:0x80,event.pitch,event.on?event.velocity:0);
            }
            s.previous=frame;
        }
    }
};
extern "C" {
UBScheduler *ub_scheduler_create(void *mixerAudioUnit,UBTimeline *timeline) {
    auto *scheduler=new UBScheduler;
    scheduler->mixer=(__bridge AUAudioUnit *)mixerAudioUnit;
    scheduler->timeline=timeline;
    scheduler->token=[scheduler->mixer tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags,const AudioTimeStamp *time,AUAudioFrameCount count,NSInteger bus) {
        if(flags & kAudioUnitRenderAction_PreRender) scheduler->render(time->mSampleTime,(time->mFlags & kAudioTimeStampHostTimeValid)?time->mHostTime:0,count);
    }];
    return scheduler;
}
int ub_scheduler_add_sampler(UBScheduler *scheduler,void *samplerAudioUnit,const UBEvent *events,uint32_t count) {
    AUAudioUnit *unit=(__bridge AUAudioUnit *)samplerAudioUnit;
    auto block=unit.scheduleMIDIEventBlock;
    if(!block) return 0;
    SamplerSchedule schedule; schedule.send=[block copy];
    if(count) schedule.events.assign(events,events+count);
    schedule.spans=ub_make_spans(schedule.events);
    scheduler->samplers.push_back(std::move(schedule));
    return 1;
}
void ub_scheduler_destroy(UBScheduler *scheduler) {
    if(!scheduler) return;
    [scheduler->mixer removeRenderObserver:scheduler->token];
    delete scheduler;
}
}
