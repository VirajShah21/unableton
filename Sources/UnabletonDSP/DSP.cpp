#include "Timeline.hpp"
#include <algorithm>
#include <array>
#include <memory>
#include <vector>
#include <mach/mach_time.h>

namespace {
constexpr double pi = 3.14159265358979323846;
double polyBlep(double t, double dt) {
    if (t < dt) { t /= dt; return t + t - t*t - 1; }
    if (t > 1-dt) { t = (t-1)/dt; return t*t + t + t + 1; }
    return 0;
}
double oscillator(double phase, double step, int waveform) {
    if (waveform == 0) return std::sin(phase * 2*pi);
    if (waveform == 1) return 2*phase - 1 - polyBlep(phase, step);
    if (waveform == 2) return (phase < .5 ? 1 : -1) + polyBlep(phase, step) - polyBlep(std::fmod(phase+.5,1.), step);
    return 2 * std::abs(2*phase - 1) - 1;
}
struct SampleData { std::vector<float> left, right; double rate; };
struct AudioClip { std::shared_ptr<SampleData> sample; int64_t start, end; double offset; };
struct Voice {
    bool active=false, released=false;
    uint64_t note=0;
    int pitch=60;
    double velocity=0, phase=0, phase2=0, envelope=0, releaseLevel=0, age=0, releaseAge=0;
    double filter1=0, filter2=0;
    uint32_t noise=1;
};
}
struct UBSample { std::shared_ptr<SampleData> data; };
struct UBTrack {
    UBTimeline *timeline;
    UBSynthParameters p;
    std::vector<UBEvent> events;
    std::vector<UBSpan> spans;
    std::vector<AudioClip> clips;
    std::array<Voice, 32> voices{};
    size_t cursor=0;
    int64_t previous=INT64_MIN;
    explicit UBTrack(UBTimeline *t, UBSynthParameters parameters): timeline(t), p(parameters) {}
    void event(const UBEvent &e) {
        if (!e.on) {
            for (auto &v: voices) if (v.active && v.note==e.note && !v.released) {
                v.released=true; v.releaseLevel=v.envelope; v.releaseAge=0;
            }
            return;
        }
        auto it=std::find_if(voices.begin(), voices.end(), [](auto &v){return !v.active;});
        if (it==voices.end()) it=std::min_element(voices.begin(),voices.end(),[](auto &a,auto &b){return a.envelope<b.envelope;});
        *it=Voice{}; it->active=true; it->note=e.note; it->pitch=e.pitch;
        it->velocity=double(e.velocity)/127.; it->noise=uint32_t(e.note*2654435761ULL+1);
    }
    void resetAt(int64_t frame) {
        voices={};
        cursor=std::lower_bound(events.begin(), events.end(), frame, [](auto &e,int64_t f){return e.frame<f;})-events.begin();
        // Chase notes spanning a seek/loop destination. The attack restarts intentionally.
        for (const auto &span: spans) if (span.start.frame < frame && span.end > frame) event(span.start);
    }
    double voice(Voice &v) {
        if (!v.active) return 0;
        const double rate=timeline->sampleRate, dt=1/rate;
        v.age+=dt;
        if (v.released) {
            v.releaseAge+=dt; v.envelope=v.releaseLevel*std::max(0.,1-v.releaseAge/std::max(.005,p.release));
            if (v.envelope<=.00001) {v.active=false;return 0;}
        } else if (v.age<p.attack) v.envelope=v.age/std::max(.001,p.attack);
        else if (v.age<p.attack+p.decay) v.envelope=1-(1-p.sustain)*(v.age-p.attack)/std::max(.001,p.decay);
        else v.envelope=p.sustain;
        double frequency=440*std::pow(2.,(v.pitch-69)/12.);
        double out;
        if (p.mode==1) {
            v.noise^=v.noise<<13;v.noise^=v.noise>>17;v.noise^=v.noise<<5;
            double noise=double(v.noise)/2147483648.-1;
            if (v.pitch==35 || v.pitch==36) {
                frequency=48+130*std::exp(-v.age*55);
                out=std::sin(v.phase*2*pi)*std::exp(-v.age*10);
            } else if (v.pitch==38 || v.pitch==40 || v.pitch==39) out=(noise*.8+std::sin(v.phase*2*pi)*.2)*std::exp(-v.age*19);
            else out=noise*std::exp(-v.age*(v.pitch==46?12:65))*.5;
            if (v.age>1.2) v.active=false;
        } else {
            double step=std::min(.45,frequency/rate), detune=std::pow(2.,p.detune/1200.);
            out=(oscillator(v.phase,step,p.waveform)+oscillator(v.phase2,std::min(.45,step*detune),p.waveform))*.5;
            v.phase2=std::fmod(v.phase2+step*detune,1.);
        }
        v.phase=std::fmod(v.phase+frequency/rate,1.);
        const double modulation=std::sin(v.age*p.lfoRate*2*pi)*p.lfoDepth;
        const double cutoff=std::clamp(p.cutoff*std::pow(2.,modulation*3),35.,rate*.4);
        const double coefficient=1-std::exp(-2*pi*cutoff/rate);
        const double feedback=std::clamp(p.resonance,0.,.95)*1.8;
        v.filter1+=coefficient*(out-feedback*v.filter2-v.filter1);
        v.filter2+=coefficient*(v.filter1-v.filter2);
        out=std::tanh(v.filter2*(1+p.drive*5));
        return out*v.envelope*v.velocity*.18;
    }
};
extern "C" {
UBTimeline *ub_timeline_create(double rate,int64_t start,int loop,int64_t ls,int64_t le) {
    auto *t=new UBTimeline; t->sampleRate=rate;t->startFrame=start;t->loop=loop;t->loopStart=ls;t->loopEnd=le;t->current.store(start);
    mach_timebase_info_data_t timebase;mach_timebase_info(&timebase);t->secondsPerHostTick=double(timebase.numer)/double(timebase.denom)*1e-9;
    return t;
}
void ub_timeline_destroy(UBTimeline *t) {delete t;}
int64_t ub_timeline_current_frame(const UBTimeline *t) {return t->current.load(std::memory_order_relaxed);}
void ub_timeline_begin_render(UBTimeline *t,double sampleTime,uint64_t hostTime,uint32_t frames) {
    if (std::isnan(t->origin)) t->origin=sampleTime;
    if(hostTime && !t->originHostTime.load(std::memory_order_relaxed)) {
        const double ticks=(sampleTime-t->origin)/(t->sampleRate*t->secondsPerHostTick);
        t->originHostTime.store(static_cast<uint64_t>(double(hostTime)-ticks),std::memory_order_release);
    }
    t->current.store(t->projectFrame(sampleTime+frames),std::memory_order_relaxed);
}
double ub_timeline_beat_for_host_time(const UBTimeline *t,uint64_t hostTime,double tempo) {
    const auto origin=t->originHostTime.load(std::memory_order_acquire);
    if(!origin || !hostTime) return NAN;
    double frame=t->startFrame+(double(hostTime)-double(origin))*t->secondsPerHostTick*t->sampleRate;
    if(t->loop && t->loopEnd>t->loopStart && frame>=t->loopEnd) frame=t->loopStart+std::fmod(frame-t->loopStart,double(t->loopEnd-t->loopStart));
    return frame/t->sampleRate*tempo/60;
}
UBTrack *ub_track_create(UBTimeline *t,UBSynthParameters p,const UBEvent *events,uint32_t count) {
    auto *track=new UBTrack(t,p); if (count) track->events.assign(events,events+count);track->spans=ub_make_spans(track->events);return track;
}
void ub_track_destroy(UBTrack *t) {delete t;}
void ub_track_render(UBTrack *t,double sampleTime,uint32_t frames,float *left,float *right) {
    if (std::isnan(t->timeline->origin)) {std::fill(left,left+frames,0);std::fill(right,right+frames,0);return;}
    for (uint32_t i=0;i<frames;++i) {
        const int64_t frame=t->timeline->projectFrame(sampleTime+i);
        if (frame!=t->previous+1) t->resetAt(frame);
        while(t->cursor<t->events.size() && t->events[t->cursor].frame<=frame) t->event(t->events[t->cursor++]);
        double l=0,r=0;
        for (auto &v:t->voices) {const double value=t->voice(v);l+=value;r+=value;}
        for (const auto &clip:t->clips) if (frame>=clip.start && frame<clip.end) {
            const double source=clip.offset+(frame-clip.start)*clip.sample->rate/t->timeline->sampleRate;
            const int64_t at=static_cast<int64_t>(source);
            if (at>=0 && at<static_cast<int64_t>(clip.sample->left.size())) {
                const double f=source-at;
                const auto next=std::min(at+1,static_cast<int64_t>(clip.sample->left.size())-1);
                l+=clip.sample->left[at]*(1-f)+clip.sample->left[next]*f;
                r+=clip.sample->right[at]*(1-f)+clip.sample->right[next]*f;
            }
        }
        left[i]=float(l);right[i]=float(r);t->previous=frame;
    }
}
UBSample *ub_sample_create(const float *left,const float *right,uint64_t frames,double rate) {
    auto *s=new UBSample;s->data=std::make_shared<SampleData>();s->data->rate=rate;
    s->data->left.assign(left,left+frames);s->data->right.assign(right,right+frames);return s;
}
void ub_sample_destroy(UBSample *s) {delete s;}
void ub_track_add_audio(UBTrack *t,UBSample *s,int64_t start,int64_t end,double offset) {
    t->clips.push_back({s->data,start,end,offset*s->data->rate});
}
}
