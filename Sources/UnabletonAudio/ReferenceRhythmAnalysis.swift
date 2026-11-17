import Foundation
@preconcurrency import AVFAudio

public struct ReferenceDropCandidate: Codable, Sendable, Equatable {
    public let timeSeconds: Double
    /// Detector quality, not a calibrated probability or a verified section label.
    public let quality: Double
    public let evidence: String
}

public struct ReferenceRhythmAnalysis: Codable, Sendable, Equatable {
    public let duration: Double
    public let tempo: Double?
    public let quality: Double
    public let beatTimesSeconds: [Double]
    public let dropCandidates: [ReferenceDropCandidate]
    public let warnings: [String]
}

extension ReferenceAudioProcessor {
    /// Bounded local measurements only. A rising bass-energy candidate is not
    /// proof of a musical drop; semantic interpretation stays with the agent.
    public static func analyze(url: URL) throws -> ReferenceRhythmAnalysis {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat, sampleRate = format.sampleRate
        let duration = Double(file.length) / sampleRate
        guard duration.isFinite, duration > 0, duration <= maximumDuration,
              (1...32).contains(format.channelCount), (8_000...192_000).contains(sampleRate) else {
            throw AudioError.unreadableAudio("Local song analysis supports up to ten minutes of audio.")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        let bucketFrames = max(1, Int((sampleRate * 0.02).rounded()))
        let stepSeconds = Double(bucketFrames) / sampleRate
        let coefficient = 1 - exp(-2 * Double.pi * 180 / sampleRate)
        var rms: [Double] = [], lowEnergy: [Double] = []
        rms.reserveCapacity(30_001); lowEnergy.reserveCapacity(30_001)
        var low = Array(repeating: 0.0, count: Int(format.channelCount))
        var squares = 0.0, lowSquares = 0.0, count = 0
        while file.framePosition < file.length {
            try Task<Never, Never>.checkCancellation()
            try file.read(into: buffer, frameCount: 8192)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                var frameSquares = 0.0, frameLowSquares = 0.0
                for channel in 0..<Int(format.channelCount) {
                    let value = Double(channels[channel][frame])
                    guard value.isFinite else { throw AudioError.unreadableAudio("The song contains invalid audio samples.") }
                    low[channel] += coefficient * (value - low[channel])
                    frameSquares += value * value; frameLowSquares += low[channel] * low[channel]
                }
                // Average channel energies instead of waveforms so opposite-phase
                // stereo material does not disappear from the measurements.
                squares += frameSquares / Double(format.channelCount)
                lowSquares += frameLowSquares / Double(format.channelCount); count += 1
                if count == bucketFrames {
                    rms.append(sqrt(squares / Double(count))); lowEnergy.append(sqrt(lowSquares / Double(count)))
                    squares = 0; lowSquares = 0; count = 0
                }
            }
        }
        if count > 0 { rms.append(sqrt(squares / Double(count))); lowEnergy.append(sqrt(lowSquares / Double(count))) }
        guard let peak = rms.max(), peak > 0.00001 else {
            return ReferenceRhythmAnalysis(duration: duration, tempo: nil, quality: 0,
                beatTimesSeconds: [], dropCandidates: [], warnings: ["No rhythmic evidence was detected in this silent or very quiet audio."])
        }
        var onsets = Array(repeating: 0.0, count: rms.count)
        for i in 1..<rms.count { onsets[i] = max(0, rms[i] - rms[i - 1]) }
        let totalEnergy = onsets.reduce(0) { $0 + $1 * $1 }
        var bestLag = 0, bestScore = 0.0
        if onsets.count >= 100, totalEnergy > 0.00000001 {
            let minimumLag = max(1, Int((60 / 300 / stepSeconds).rounded()))
            let maximumLag = min(onsets.count / 3, Int((60 / 30 / stepSeconds).rounded()))
            for lag in minimumLag...maximumLag {
                var correlation = 0.0, a = 0.0, b = 0.0
                for i in lag..<onsets.count {
                    correlation += onsets[i] * onsets[i - lag]
                    a += onsets[i] * onsets[i]; b += onsets[i - lag] * onsets[i - lag]
                }
                let tempo = 60 / (Double(lag) * stepSeconds)
                let score = correlation / max(0.000000001, sqrt(a * b))
                    * (1 - min(0.12, abs(log2(tempo / 120)) * 0.04))
                if score > bestScore { bestScore = score; bestLag = lag }
            }
        }
        let quality = min(1, max(0, bestScore))
        var beats: [Double] = [], tempo: Double?
        if bestLag > 0, quality >= 0.15 {
            tempo = 60 / (Double(bestLag) * stepSeconds)
            var bestPhase = 0, phaseScore = 0.0
            for phase in 0..<bestLag {
                var score = 0.0
                for i in stride(from: phase, to: onsets.count, by: bestLag) { score += onsets[i] }
                if score > phaseScore { phaseScore = score; bestPhase = phase }
            }
            beats = stride(from: bestPhase, to: onsets.count, by: bestLag).map { Double($0) * stepSeconds }
        }
        let window = max(1, Int((1 / stepSeconds).rounded()))
        var candidates: [ReferenceDropCandidate] = []
        if lowEnergy.count > window * 3 {
            var prefix = [0.0]; prefix.reserveCapacity(lowEnergy.count + 1)
            for value in lowEnergy { prefix.append(prefix.last! + value) }
            for i in stride(from: window * 2, to: lowEnergy.count - window, by: max(1, window / 4)) {
                let before = (prefix[i] - prefix[i - window * 2]) / Double(window * 2)
                let after = (prefix[i + window] - prefix[i]) / Double(window)
                let rise = (after - before) / max(0.000001, peak)
                guard after > before * 1.8, rise >= 0.02 else { continue }
                // Refine the boundary to a measured onset in the surrounding half-second.
                let lower = max(1, i - window / 2), upper = min(onsets.count, i + window / 2)
                let onset = (lower..<upper).max { onsets[$0] < onsets[$1] } ?? i
                let time = Double(onset) * stepSeconds
                let candidate = ReferenceDropCandidate(timeSeconds: time, quality: min(1, rise * 12),
                    evidence: "Low-frequency energy increased \(String(format: "%.1f", after / max(0.000001, before)))× after a quieter interval; timestamp follows a measured onset. This is an estimated transition, not a verified bass drop.")
                if let last = candidates.last, abs(last.timeSeconds - time) < 2 {
                    if candidate.quality > last.quality { candidates[candidates.count - 1] = candidate }
                } else { candidates.append(candidate) }
            }
        }
        let strongest = candidates.sorted { $0.quality > $1.quality }.prefix(8).sorted { $0.timeSeconds < $1.timeSeconds }
        var warnings = ["Tempo may have half/double-time ambiguity. Beat positions are estimates, not verified downbeats."]
        if tempo == nil { warnings.append("Insufficient consistent onset evidence to estimate a tempo.") }
        if strongest.isEmpty { warnings.append("No convincing low-frequency transition was detected. Ask for a timestamp if a drop is required.") }
        return ReferenceRhythmAnalysis(duration: duration, tempo: tempo, quality: quality,
            beatTimesSeconds: beats, dropCandidates: strongest, warnings: warnings)
    }
}
