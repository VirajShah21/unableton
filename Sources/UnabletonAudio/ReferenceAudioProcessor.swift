import Foundation
@preconcurrency import AVFAudio

public struct ReferenceAudioMetadata: Sendable, Equatable {
    public let duration: Double
    public let sampleRate: Double
    public let channels: Int
    public let byteCount: Int
}

/// File preparation runs on a worker task. It never opens an input device or
/// places work in a real-time callback; files are read and written in short blocks.
public enum ReferenceAudioProcessor {
    public static let maximumDuration: Double = 600
    public static let maximumSourceBytes = 100 * 1024 * 1024
    public static let maximumProviderBytes = 10_000_000

    public static func inspect(url: URL) throws -> ReferenceAudioMetadata {
        try metadata(url: url, maximumBytes: maximumSourceBytes)
    }

    /// Separated WAVs can be much larger than the compressed attachment. Inspect
    /// headers without decoding them, while keeping a separate derivative bound.
    public static func inspectDerived(url: URL) throws -> ReferenceAudioMetadata {
        try metadata(url: url, maximumBytes: 256 * 1024 * 1024)
    }

    private static func metadata(url: URL, maximumBytes: Int) throws -> ReferenceAudioMetadata {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let byteCount = attributes.fileSize, byteCount > 0, byteCount <= maximumBytes else {
            throw AudioError.unreadableAudio("The audio file is missing, is not a regular file, or exceeds its \(maximumBytes / 1024 / 1024) MiB size limit.")
        }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= maximumDuration,
              (1...32).contains(file.processingFormat.channelCount),
              (8_000...192_000).contains(file.processingFormat.sampleRate) else {
            throw AudioError.unreadableAudio("Attached songs must contain audio and be no longer than ten minutes.")
        }
        return ReferenceAudioMetadata(duration: duration, sampleRate: file.processingFormat.sampleRate,
                                      channels: Int(file.processingFormat.channelCount), byteCount: byteCount)
    }

    /// AAC at 96 kb/s keeps ten minutes comfortably below the provider's 10 MB cap.
    public static func prepareProviderAudio(source: URL, to output: URL) throws -> URL {
        let metadata = try inspect(url: source)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000]
        try render(sources: [source], to: output, startSeconds: 0, durationSeconds: metadata.duration,
                   rate: 1, settings: settings)
        let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= maximumProviderBytes else {
            try? FileManager.default.removeItem(at: output)
            throw AudioError.unreadableAudio("The prepared song exceeds the provider's 10 MB limit.")
        }
        return output
    }

    /// Both BPM values must be supplied to request a tempo change. Source timing
    /// is retained otherwise; no pitch change or key inference occurs here.
    public static func renderSegment(source: URL, to output: URL, startSeconds: Double,
                                     durationSeconds: Double, sourceTempo: Double? = nil,
                                     targetTempo: Double? = nil) throws -> ReferenceAudioMetadata {
        try renderMix(sources: [source], to: output, startSeconds: startSeconds,
                      durationSeconds: durationSeconds, sourceTempo: sourceTempo, targetTempo: targetTempo)
    }

    /// Mix only explicitly selected, aligned stems. AVAudioPlayerNode streams
    /// each source segment into one mixer before any shared tempo processing.
    /// Gain is explicit and defaults to unity. A mix that would clip is rejected,
    /// never silently normalized.
    public static func renderMix(sources: [URL], to output: URL, startSeconds: Double,
                                 durationSeconds: Double, sourceTempo: Double? = nil,
                                 targetTempo: Double? = nil, gain: Double = 1) throws -> ReferenceAudioMetadata {
        guard gain.isFinite, (0.001...1).contains(gain) else {
            throw AudioError.invalidSong("Mix gain must be between 0.001 and 1.")
        }
        var rate = 1.0
        if sourceTempo != nil || targetTempo != nil {
            guard let sourceTempo, let targetTempo, sourceTempo.isFinite, targetTempo.isFinite,
                  (30...300).contains(sourceTempo), (30...300).contains(targetTempo) else {
                throw AudioError.invalidSong("Supply a valid source and target tempo for tempo matching.")
            }
            rate = targetTempo / sourceTempo
            guard (0.5...2).contains(rate) else {
                throw AudioError.invalidSong("Tempo matching supports half to twice the original speed. Choose a closer tempo.")
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        try render(sources: sources, to: output, startSeconds: startSeconds,
                   durationSeconds: durationSeconds, rate: rate, settings: settings, gain: gain)
        let file = try AVAudioFile(forReading: output)
        return ReferenceAudioMetadata(duration: Double(file.length) / file.processingFormat.sampleRate,
            sampleRate: file.processingFormat.sampleRate, channels: Int(file.processingFormat.channelCount),
            byteCount: try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private static func render(sources: [URL], to output: URL, startSeconds: Double,
                               durationSeconds: Double, rate: Double, settings: [String: Any], gain: Double = 1) throws {
        guard (1...12).contains(sources.count),
              Set(sources.map(\.standardizedFileURL)).count == sources.count,
              sources.allSatisfy({ $0.standardizedFileURL != output.standardizedFileURL }) else {
            throw AudioError.unreadableAudio("Choose one to twelve distinct source stems and a separate output file.")
        }
        guard startSeconds.isFinite, durationSeconds.isFinite, startSeconds >= 0,
              durationSeconds > 0, durationSeconds <= maximumDuration else {
            throw AudioError.unreadableAudio("Choose a nonempty source range no longer than ten minutes.")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let engine = AVAudioEngine()
        let normalizer = AVAudioMixerNode()
        engine.attach(normalizer); normalizer.outputVolume = Float(gain); engine.mainMixerNode.outputVolume = 1
        var players: [AVAudioPlayerNode] = [], files: [AVAudioFile] = []
        for (index, source) in sources.enumerated() {
            try Task<Never, Never>.checkCancellation()
            let sourceFile = try AVAudioFile(forReading: source)
            let sourceRate = sourceFile.processingFormat.sampleRate
            let sourceDuration = Double(sourceFile.length) / sourceRate
            guard sourceDuration.isFinite, sourceDuration > 0,
                  (8_000...192_000).contains(sourceRate), (1...32).contains(sourceFile.processingFormat.channelCount),
                  startSeconds + durationSeconds <= sourceDuration + 1 / sourceRate else {
                throw AudioError.unreadableAudio("Choose a source range that exists in every selected stem.")
            }
            let startFrame = AVAudioFramePosition((startSeconds * sourceRate).rounded())
            let sourceFrames = min(sourceFile.length - startFrame, AVAudioFramePosition((durationSeconds * sourceRate).rounded()))
            guard sourceFrames > 0, sourceFrames <= Int64(UInt32.max) else {
                throw AudioError.unreadableAudio("The selected audio range is too large.")
            }
            let player = AVAudioPlayerNode(); player.volume = 1
            engine.attach(player)
            engine.connect(player, to: normalizer, fromBus: 0, toBus: AVAudioNodeBus(index), format: sourceFile.processingFormat)
            player.scheduleSegment(sourceFile, startingFrame: startFrame, frameCount: AVAudioFrameCount(sourceFrames), at: nil)
            players.append(player); files.append(sourceFile)
        }
        if abs(rate - 1) > 0.000001 {
            let timePitch = AVAudioUnitTimePitch(); timePitch.rate = Float(rate); timePitch.pitch = 0
            engine.attach(timePitch)
            engine.connect(normalizer, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        } else { engine.connect(normalizer, to: engine.mainMixerNode, format: format) }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".reference-\(UUID()).\(output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            try engine.start()
            // No render occurs between play calls, so all stems start on the
            // same offline sample clock and retain their original alignment.
            for player in players { player.play() }
            defer { for player in players { player.stop() }; engine.stop() }
            let total = Int64((durationSeconds / rate * 48_000).rounded())
            var written: Int64 = 0, stalls = 0
            while written < total {
                try Task<Never, Never>.checkCancellation()
                let result = try engine.renderOffline(AVAudioFrameCount(min(4096, total - written)), to: buffer)
                switch result {
                case .success:
                    guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw AudioError.render("Audio preparation returned an empty buffer.") }
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for index in 0..<Int(buffer.frameLength) {
                            let value = channels[channel][index]
                            guard value.isFinite else { throw AudioError.render("Audio preparation produced invalid samples.") }
                            if sources.count > 1, abs(value) > 1.00001 {
                                throw AudioError.invalidSong("The selected stems clip at mix_gain \(gain). Lower mix_gain and retry the local mix; no automatic gain change was applied.")
                            }
                        }
                    }
                    try file.write(from: buffer); written += Int64(buffer.frameLength); stalls = 0
                case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                    stalls += 1
                    guard stalls <= 128 else { throw AudioError.render("Audio preparation stalled.") }
                case .error: throw AudioError.render("Audio preparation failed.")
                @unknown default: throw AudioError.render("Audio preparation returned an unsupported result.")
                }
            }
        }
        withExtendedLifetime(files) {}
        try Task<Never, Never>.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: output) }
    }
}
