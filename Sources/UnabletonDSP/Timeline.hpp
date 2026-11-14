#pragma once
#include "include/UnabletonDSP.h"
#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

struct UBSpan { UBEvent start; int64_t end = INT64_MAX; };
inline std::vector<UBSpan> ub_make_spans(const std::vector<UBEvent> &events) {
    std::vector<UBSpan> spans;
    std::vector<size_t> indices(events.size()+1, SIZE_MAX);
    for (const auto &event: events) {
        if (event.note >= indices.size()) continue;
        if (event.on) { indices[event.note] = spans.size(); spans.push_back({event, INT64_MAX}); }
        else if (indices[event.note] != SIZE_MAX) spans[indices[event.note]].end = event.frame;
    }
    return spans;
}

struct UBTimeline {
    double sampleRate;
    int64_t startFrame, loopStart, loopEnd;
    bool loop;
    double origin = NAN;
    std::atomic<int64_t> current{0};
    std::atomic<uint64_t> originHostTime{0};
    double secondsPerHostTick = 0;
    int64_t projectFrame(double engineFrame) const {
        int64_t frame = startFrame + static_cast<int64_t>(std::llround(engineFrame - origin));
        if (loop && loopEnd > loopStart && frame >= loopEnd)
            frame = loopStart + (frame - loopStart) % (loopEnd - loopStart);
        return frame;
    }
};
