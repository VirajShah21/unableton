import Foundation
@preconcurrency import AVFAudio
import UnabletonDSP

/// The tap is a single producer; only the writer queue consumes the preallocated ring.
final class RecordingWriter: @unchecked Sendable {
    let url: URL
    let format: AVAudioFormat
    let startBeat: Double
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "app.unableton.recording-writer", qos: .userInitiated)
    private let ring: OpaquePointer
    private let buffer: AVAudioPCMBuffer
    private let timeline: NativeTimeline?
    private let tempo: Double
    private let maximumFrames: Int64?
    private var timer: DispatchSourceTimer?
    private var frames: Int64 = 0
    private var inputLevel: Double = 0
    private var problem: String?

    init(url: URL, format inputFormat: AVAudioFormat, startBeat: Double, timeline: NativeTimeline? = nil, tempo: Double = 120, maximumDuration: Double? = nil) throws {
        self.url = url; self.startBeat = startBeat
        self.timeline = timeline; self.tempo = tempo
        if let maximumDuration {
            guard maximumDuration.isFinite, maximumDuration > 0 else { throw AudioError.recording("The recording duration must be positive.") }
            let limit = (maximumDuration * inputFormat.sampleRate).rounded(.down)
            guard limit.isFinite, limit >= 1, limit < Double(Int64.max) else { throw AudioError.recording("The recording duration is outside the supported range.") }
            maximumFrames = Int64(limit)
        } else { maximumFrames = nil }
        format = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: min(2, inputFormat.channelCount))!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        ring = ub_record_ring_create(format.channelCount, 16_384, 64)!
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)!
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel(); ub_record_ring_destroy(ring) }
    var isInterrupted: Bool { ub_record_ring_overflowed(ring) == 1 }
    /// Read only off the render thread. All writer counters remain queue-owned.
    var progress: (duration: Double, reachedLimit: Bool, frames: Int64, inputLevel: Double) {
        queue.sync { (Double(frames) / format.sampleRate, maximumFrames.map { frames >= $0 } ?? false, frames, inputLevel) }
    }
    func enqueue(_ input: AVAudioPCMBuffer, hostTime: UInt64 = 0) {
        guard input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved,
              input.format.sampleRate == format.sampleRate, let data = input.floatChannelData else {
            ub_record_ring_abort(ring); return
        }
        ub_record_ring_set_first_host_time(ring, hostTime)
        _ = ub_record_ring_push(ring, data[0], data[input.format.channelCount > 1 ? 1 : 0], input.frameLength)
    }
    private func drain() {
        guard let data = buffer.floatChannelData else { return }
        var count: UInt32 = 0
        while ub_record_ring_pop(ring, data[0], data[format.channelCount > 1 ? 1 : 0], &count) == 1 {
            let remaining = maximumFrames.map { max(0, $0 - frames) } ?? Int64(count)
            let writable = min(Int64(count), remaining)
            guard writable > 0 else { continue }
            buffer.frameLength = AVAudioFrameCount(writable)
            if let file {
                do {
                    try file.write(from: buffer); frames += writable
                    // This work belongs to the writer queue, not the input tap.
                    var peak: Float = 0
                    for index in 0..<Int(writable) {
                        peak = max(peak, abs(data[0][index]))
                        if format.channelCount > 1 { peak = max(peak, abs(data[1][index])) }
                    }
                    inputLevel = min(1, Double(peak))
                }
                catch { problem = error.localizedDescription; ub_record_ring_abort(ring); self.file = nil }
            }
        }
        if ub_record_ring_overflowed(ring) == 1 {
            problem = problem ?? "Recording was interrupted because the input format changed or the disk writer fell behind. The audio captured before the interruption was saved."
            file = nil
        }
    }
    func finish() -> (RecordedAudio, String?) {
        timer?.cancel(); timer = nil
        return queue.sync {
            drain(); file = nil
            let timedBeat = timeline.map { ub_timeline_beat_for_host_time($0.pointer, ub_record_ring_first_host_time(ring), tempo) } ?? .nan
            let failure = problem ?? (frames == 0 ? "No microphone audio reached the recorder. Check the macOS input device and microphone permission, then record again." : nil)
            return (RecordedAudio(url: url, duration: Double(frames) / format.sampleRate, sampleRate: format.sampleRate, channels: Int(format.channelCount), startBeat: timedBeat.isFinite ? max(0, timedBeat) : startBeat), failure)
        }
    }
}
