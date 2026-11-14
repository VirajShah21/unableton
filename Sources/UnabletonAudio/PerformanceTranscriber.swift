import Foundation
import Accelerate
@preconcurrency import AVFAudio
import UnabletonCore

/// Offline monophonic melody and percussion analysis. No recording leaves the Mac.
/// The pitch estimator implements the difference function and cumulative-mean
/// normalization described by de Cheveigné and Kawahara, JASA 111 (2002),
/// https://doi.org/10.1121/1.1458024 . This is an independent implementation.
public enum PerformanceTranscriber {
    private static let analysisRate = 16_000.0

    public static func transcribe(url: URL, mode: TranscriptionMode) async throws -> PerformanceTranscript {
        let work = Task.detached(priority: .userInitiated) {
            let audio = try read(url)
            return try analyze(samples: audio.samples, duration: audio.duration, mode: mode)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func read(_ url: URL) throws -> (samples: [Float], duration: Double) {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = file.processingFormat
        let duration = Double(file.length) / source.sampleRate
        guard source.sampleRate.isFinite, (8_000...192_000).contains(source.sampleRate), (1...8).contains(source.channelCount) else {
            throw TranscriptionError.invalidAudio("Use audio with one to eight channels at 8–192 kHz.")
        }
        guard duration > 0 else { throw TranscriptionError.invalidAudio("This recording contains no audio samples. Check the microphone input and record another take.") }
        guard duration.isFinite, duration <= PerformanceTranscript.maximumDuration else { throw TranscriptionError.durationLimit }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: analysisRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw TranscriptionError.invalidAudio("This recording's audio format cannot be converted.")
        }
        converter.primeMethod = .none
        var failure: Error?
        var values: [Float] = []
        values.reserveCapacity(Int(duration * analysisRate) + 64)
        var emptyOutputs = 0
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                do {
                    try Task.checkCancellation()
                    guard file.framePosition < file.length else { state.pointee = .endOfStream; return nil }
                    let remaining = AVAudioFrameCount(min(Int64(input.frameCapacity), file.length - file.framePosition))
                    input.frameLength = 0
                    try file.read(into: input, frameCount: min(requested, remaining))
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    failure = error; state.pointee = .endOfStream; return nil
                }
            }
            if let failure { throw failure }
            if let conversionError { throw conversionError }
            guard status != .error, let data = output.floatChannelData?[0] else { throw TranscriptionError.invalidAudio("The recording could not be decoded.") }
            let count = Int(output.frameLength)
            for index in 0..<count {
                let value = data[index]
                guard value.isFinite else { throw TranscriptionError.invalidAudio("The recording contains invalid audio samples.") }
                values.append(value)
            }
            guard values.count <= Int(analysisRate * PerformanceTranscript.maximumDuration) + 4096 else { throw TranscriptionError.durationLimit }
            if status == .endOfStream { break }
            emptyOutputs = count == 0 ? emptyOutputs + 1 : 0
            guard emptyOutputs < 8 else { throw TranscriptionError.invalidAudio("The audio decoder stopped producing samples.") }
        }
        let expected = Int((duration * analysisRate).rounded())
        if values.count > expected { values.removeLast(values.count - expected) }
        guard !values.isEmpty else { throw TranscriptionError.noSound }
        return (values, duration)
    }

    private static func analyze(samples: [Float], duration: Double, mode: TranscriptionMode) throws -> PerformanceTranscript {
        let hop = mode == .beatboxing ? 80 : 160
        let energy = rmsBins(samples, hop: hop)
        let maximum = energy.max() ?? 0
        guard maximum >= 0.003 else { throw TranscriptionError.noSound }
        let floor = energy.sorted()[min(energy.count - 1, energy.count / 5)]
        let gate = max(0.0025, min(maximum * 0.12, floor * 3))
        let events = try mode == .beatboxing
            ? percussion(samples, energy: energy, gate: gate, maximum: maximum, duration: duration)
            : melody(samples, energy: energy, gate: gate, maximum: maximum, duration: duration, mode: mode)
        guard !events.isEmpty else { throw TranscriptionError.noNotes }
        var warnings: [String] = []
        if mode == .singing { warnings.append("Singing mode extracts a single sung melody, not lyrics or a generated voice.") }
        if mode == .beatboxing { warnings.append("Beatbox drum labels are estimated from energy and frequency bands. Review kick, snare and hi-hat assignments before inserting.") }
        let uncertain = events.filter { $0.confidence < 0.8 }.count
        if uncertain > 0 { warnings.append("Review \(uncertain) event\(uncertain == 1 ? "" : "s") with lower detector confidence.") }
        let result = PerformanceTranscript(mode: mode, events: events, duration: duration, warnings: warnings)
        try result.validate()
        return result
    }

    private static func rmsBins(_ samples: [Float], hop: Int) -> [Double] {
        stride(from: 0, to: samples.count, by: hop).map { start in
            let end = min(samples.count, start + hop)
            var sum = 0.0
            for index in start..<end { sum += Double(samples[index]) * Double(samples[index]) }
            return sqrt(sum / Double(end - start))
        }
    }

    private struct PitchFrame {
        var pitch: Int?
        var confidence: Double = 0
    }

    private static func melody(_ samples: [Float], energy: [Double], gate: Double, maximum: Double, duration: Double, mode: TranscriptionMode) throws -> [TranscribedEvent] {
        let minimumFrequency = mode == .whistle ? 250.0 : 55.0
        let maximumFrequency = mode == .whistle ? 3500.0 : mode == .humming ? 1100.0 : 1800.0
        var yin = PitchDetector(minimumFrequency: minimumFrequency, maximumFrequency: maximumFrequency)
        var frames = [PitchFrame](repeating: PitchFrame(), count: energy.count)
        for index in frames.indices where energy[index] >= gate {
            if index % 16 == 0 { try Task.checkCancellation() }
            if let estimate = yin.estimate(samples, center: index * 160 + 80) {
                frames[index] = PitchFrame(pitch: estimate.pitch, confidence: estimate.confidence)
            }
        }
        // Repair only brief detector dropouts with audible energy and matching
        // neighboring pitches. Actual silent gaps are never filled.
        if frames.count > 2 {
            for index in 1..<(frames.count - 1) where energy[index] >= gate {
                if let previous = frames[index - 1].pitch, previous == frames[index + 1].pitch,
                   frames[index].pitch != previous {
                    frames[index].pitch = previous
                    frames[index].confidence = min(frames[index - 1].confidence, frames[index + 1].confidence)
                }
            }
        }
        var events: [TranscribedEvent] = []
        var index = 0
        while index < frames.count {
            guard let pitch = frames[index].pitch else { index += 1; continue }
            let start = index
            index += 1
            while index < frames.count, frames[index].pitch == pitch {
                let attack = index - start >= 8 && energy[index - 1] < maximum * 0.6 && energy[index] > max(gate * 2, energy[index - 1] * 1.9)
                if attack { break }
                index += 1
            }
            guard index - start >= 5 else { continue }
            var first = start
            while first > 0, start - first < 2, frames[first - 1].pitch == nil, energy[first - 1] >= gate { first -= 1 }
            var last = index
            while last < frames.count, last - index < 2, frames[last].pitch == nil, energy[last] >= gate { last += 1 }
            let previousEnd = events.last.map { $0.startSeconds + $0.durationSeconds } ?? 0
            let startTime = max(previousEnd, Double(first) * 0.01)
            let endTime = min(duration, Double(last) * 0.01)
            guard endTime > startTime else { continue }
            let confidence = frames[start..<index].reduce(0) { $0 + $1.confidence } / Double(index - start)
            let loudness = energy[first..<last].max() ?? gate
            events.append(TranscribedEvent(pitch: pitch, startSeconds: startTime, durationSeconds: endTime - startTime,
                                            velocity: min(1, max(0.05, sqrt(loudness / maximum) * 0.9)), confidence: confidence))
        }
        return events
    }

    private static func percussion(_ samples: [Float], energy: [Double], gate: Double, maximum: Double, duration: Double) throws -> [TranscribedEvent] {
        var onsets: [Int] = []
        for index in energy.indices where energy[index] >= gate {
            if index % 32 == 0 { try Task.checkCancellation() }
            let previous = index == 0 ? 0 : energy[index - 1]
            let attack = previous < gate || energy[index] > max(gate * 2, previous * 1.8)
            if attack, onsets.last.map({ index - $0 >= 9 }) ?? true { onsets.append(index) }
        }
        var events: [TranscribedEvent] = []
        for (number, bin) in onsets.enumerated() {
            try Task.checkCancellation()
            let next = number + 1 < onsets.count ? onsets[number + 1] : energy.count
            var end = min(bin + 100, next)
            if bin + 2 < end {
                for candidate in (bin + 2)..<end where energy[candidate] < gate { end = candidate; break }
            }
            let startTime = Double(bin) * 0.005
            let endTime = min(duration, max(startTime + 0.025, Double(end) * 0.005))
            let classification = percussionClass(samples, start: bin * 80)
            let loudness = energy[bin..<max(bin + 1, end)].max() ?? gate
            events.append(TranscribedEvent(pitch: classification.pitch, startSeconds: startTime, durationSeconds: endTime - startTime,
                                            velocity: min(1, max(0.05, sqrt(loudness / maximum) * 0.95)), confidence: classification.confidence))
        }
        return events
    }

    /// Deliberately small, reviewable heuristic; this is not a learned beatbox
    /// recognizer. Band energy separates low kicks, noisy snares and high hats.
    private static func percussionClass(_ samples: [Float], start: Int) -> (pitch: Int, confidence: Double) {
        let lowAlpha = 1 - exp(-2 * .pi * 400 / analysisRate)
        let midAlpha = 1 - exp(-2 * .pi * 1500 / analysisRate)
        var low = 0.0, mid = 0.0, lowEnergy = 0.0, midEnergy = 0.0, highEnergy = 0.0
        var previous = 0.0, crossings = 0, count = 0
        for index in start..<min(samples.count, start + 960) {
            let value = Double(samples[index])
            low += lowAlpha * (value - low); mid += midAlpha * (value - mid)
            lowEnergy += low * low; midEnergy += (mid - low) * (mid - low); highEnergy += (value - mid) * (value - mid)
            if value * previous < 0 { crossings += 1 }
            previous = value; count += 1
        }
        let total = max(1e-12, lowEnergy + midEnergy + highEnergy)
        let lowRatio = lowEnergy / total, highRatio = highEnergy / total
        if lowRatio > 0.5 { return (36, min(0.95, 0.55 + lowRatio * 0.4)) }
        if highRatio > 0.6, Double(crossings) / Double(max(1, count)) > 0.55 { return (42, min(0.9, highRatio)) }
        return (38, 0.65)
    }

    private struct PitchDetector {
        let minimumFrequency: Double
        let maximumFrequency: Double
        let minimumLag: Int
        let maximumLag: Int
        var window = [Float](repeating: 0, count: 1024)
        var normalized: [Float]
        init(minimumFrequency: Double, maximumFrequency: Double) {
            self.minimumFrequency = minimumFrequency; self.maximumFrequency = maximumFrequency
            minimumLag = max(2, Int(analysisRate / maximumFrequency))
            maximumLag = min(450, Int(ceil(analysisRate / minimumFrequency)) + 1)
            normalized = [Float](repeating: 1, count: maximumLag + 1)
        }
        mutating func estimate(_ samples: [Float], center: Int) -> (pitch: Int, confidence: Double)? {
            let start = center - window.count / 2
            for index in window.indices {
                let source = start + index
                window[index] = source >= 0 && source < samples.count ? samples[source] : 0
            }
            let comparisonCount = window.count - maximumLag
            var cumulative: Float = 0
            window.withUnsafeBufferPointer { buffer in
                let base = buffer.baseAddress!
                for lag in 1...maximumLag {
                    var difference: Float = 0
                    vDSP_distancesq(base, 1, base.advanced(by: lag), 1, &difference, vDSP_Length(comparisonCount))
                    cumulative += difference
                    normalized[lag] = cumulative > 1e-12 ? difference * Float(lag) / cumulative : 1
                }
            }
            var candidate: Int?
            var lag = minimumLag
            while lag < maximumLag {
                if normalized[lag] < 0.2 {
                    while lag + 1 <= maximumLag, normalized[lag + 1] < normalized[lag] { lag += 1 }
                    candidate = lag; break
                }
                lag += 1
            }
            if candidate == nil {
                let best = (minimumLag...maximumLag).min { normalized[$0] < normalized[$1] }!
                if normalized[best] < 0.3 { candidate = best }
            }
            // A minimum still falling at the search boundary is not a measured
            // period. Reject it instead of inventing a note at the range limit.
            guard let candidate, candidate < maximumLag else { return nil }
            var period = Double(candidate)
            if candidate > 1, candidate < maximumLag {
                let left = Double(normalized[candidate - 1]), middle = Double(normalized[candidate]), right = Double(normalized[candidate + 1])
                let divisor = left - 2 * middle + right
                if abs(divisor) > 1e-9 { period += min(0.5, max(-0.5, 0.5 * (left - right) / divisor)) }
            }
            let frequency = analysisRate / period
            guard frequency >= minimumFrequency * 0.98, frequency <= maximumFrequency * 1.02 else { return nil }
            let pitch = Int((69 + 12 * log2(frequency / 440)).rounded())
            guard (0...127).contains(pitch) else { return nil }
            return (pitch, min(1, max(0, 1 - Double(normalized[candidate]))))
        }
    }
}
