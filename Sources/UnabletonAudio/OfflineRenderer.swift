import Foundation
@preconcurrency import AVFAudio
import UnabletonCore

public enum OfflineRenderer {
    public static func render(song: Song, assets: [UUID: URL], to url: URL, fromBeat: Double = 0, lengthBeats: Double? = nil, resources: InstrumentResources = .empty) throws -> RenderReport {
        try ProjectEditor.validate(song)
        guard song.tempo.isFinite, song.tempo > 0 else { throw AudioError.invalidSong("The tempo must be positive.") }
        let length = lengthBeats ?? max(0, song.lengthBeats - fromBeat)
        guard length.isFinite, length > 0, fromBeat.isFinite, fromBeat >= 0 else { throw AudioError.render("Select a nonempty range to export.") }
        // Stop source material at the selection end, then render only its release/effect tails.
        let endBeat = fromBeat + length
        var exportSong = song
        var audioEnvelopes: [UUID: ClipAudioEnvelope] = [:]
        for track in exportSong.tracks.indices {
            exportSong.tracks[track].clips = exportSong.tracks[track].clips.compactMap { clip in
                guard clip.startBeat < endBeat else { return nil }
                var trimmed = clip
                if clip.kind == .audio {
                    audioEnvelopes[clip.id] = ClipAudioEnvelope(fadeInBeats: clip.fadeInBeats ?? 0,
                        fadeOutBeats: clip.fadeOutBeats ?? 0, endBeat: clip.startBeat + clip.lengthBeats)
                    // The schedule stops at the selected end, but its envelope
                    // retains the full clip's anchors rather than moving the fade.
                    trimmed.fadeInBeats = nil; trimmed.fadeOutBeats = nil
                }
                trimmed.lengthBeats = min(clip.lengthBeats, endBeat - clip.startBeat)
                trimmed.notes.removeAll { $0.startBeat >= trimmed.lengthBeats }
                return trimmed
            }
        }
        let graph = try NativeGraph(song: exportSong, assets: assets, fromBeat: fromBeat, resources: resources, audioEnvelopes: audioEnvelopes)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 1024)
        let tail = min(10, max(2, song.tracks.map { $0.effectiveParameters["release", default: 0.3] + 2 }.max() ?? 2))
        let duration = length * 60 / song.tempo + tail
        let totalFrames = Int64((duration * 48_000).rounded())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".unableton-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let report: RenderReport
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 1024)!
            try graph.engine.start()
            defer { graph.engine.stop() }
            var rendered: Int64 = 0, stalled = 0, clipped = 0
            var peak = 0.0, sumSquares = 0.0, samples = 0
            while rendered < totalFrames {
                if Task<Never, Never>.isCancelled { throw CancellationError() }
                let count = AVAudioFrameCount(min(1024, totalFrames - rendered))
                let status = try graph.engine.renderOffline(count, to: buffer)
                switch status {
                case .success:
                    stalled = 0
                    guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw AudioError.render("The audio engine returned an empty render buffer.") }
                    for channel in 0..<2 {
                        for frame in 0..<Int(buffer.frameLength) {
                            let value = Double(channels[channel][frame])
                            guard value.isFinite else { throw AudioError.render("An instrument produced invalid audio samples.") }
                            peak = max(peak, abs(value)); sumSquares += value * value; samples += 1
                            if abs(value) >= 1 { clipped += 1 }
                        }
                    }
                    try file.write(from: buffer)
                    rendered += Int64(buffer.frameLength)
                case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                    stalled += 1
                    if stalled > 128 { throw AudioError.render("The audio engine could not finish rendering.") }
                case .error: throw AudioError.render("The audio engine failed while exporting.")
                @unknown default: throw AudioError.render("The audio engine returned an unsupported rendering state.")
                }
            }
            report = RenderReport(duration: Double(rendered) / 48_000, peak: peak, rms: sqrt(sumSquares / Double(max(1, samples))), clippedSamples: clipped, silent: peak < 0.00001)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: url) }
        return report
    }
}
