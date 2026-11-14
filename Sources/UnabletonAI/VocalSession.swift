import Foundation
import AVFAudio
import UnabletonCore

/// A prompt-scoped cache shared by model upgrades and revision replans. Nothing
/// here touches the live document. Completed renders are reused, not purchased twice.
public actor VocalSession {
    private let provider: any VocalGenerating
    private var catalog: [VocalSinger]?
    private var completed: [Data: GeneratedVocal] = [:]
    private var requested = Set<Data>()
    private var byteCount = 0
    public init(provider: any VocalGenerating) { self.provider = provider }

    public func singers() async throws -> [VocalSinger] {
        if let catalog { return catalog }
        do {
            let singers = try await provider.singers()
            try Task.checkCancellation()
            guard !singers.isEmpty, singers.count <= 512 else { throw ProjectError("The vocal provider returned no usable singers.") }
            catalog = singers
            return singers
        } catch is CancellationError { throw CancellationError() }
        catch { throw VocalRenderFailure(message: error.localizedDescription) }
    }

    public func render(score: VocalScore, singerID: String, sourceClipID: UUID,
                       status: @escaping @Sendable (String) -> Void) async throws -> GeneratedVocal {
        guard try await singers().contains(where: { $0.name == singerID }) else { throw AgentError.invalidTool("Choose a singer ID returned by get_vocal_singers.") }
        // MusicXML excludes arbitrary UUIDs, so the same phrase in a replanned
        // clip hits the same cache entry. The chosen voice is part of the key.
        let xml = try score.musicXML()
        let velocities = score.notes.map { String($0.velocity) }.joined(separator: ",")
        let key = Data((singerID + "\n" + velocities + "\n" + xml).utf8)
        if var cached = completed[key] {
            cached.asset.vocalTake = VocalTake(provider: provider.providerID, singerID: singerID, sourceClipID: sourceClipID, score: score,
                                               generatedAt: cached.asset.vocalTake?.generatedAt ?? Date())
            return cached
        }
        guard requested.count < 4 else { throw VocalRenderFailure(message: "This prompt reached its limit of four vocal renders. Generate a few phrases at a time.") }
        // Never blindly retry a possibly billed request after a lost response.
        guard requested.insert(key).inserted else { throw VocalRenderFailure(message: "This vocal request already failed. Send a new prompt to retry it.") }
        do {
            status("Rendering vocals with \(provider.providerID)…")
            let data = try await provider.render(score: score, singerID: singerID, status: status)
            try Task.checkCancellation()
            guard !data.isEmpty, data.count <= 32 * 1024 * 1024, byteCount + data.count <= 64 * 1024 * 1024 else {
                throw ProjectError("The vocal audio exceeded the size limit.")
            }
            let asset = try Self.inspect(data: data, score: score, provider: provider.providerID, singerID: singerID, sourceClipID: sourceClipID)
            let result = GeneratedVocal(asset: asset, data: data)
            completed[key] = result; byteCount += data.count
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw VocalRenderFailure(message: "Vocal generation failed: \(error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))). The song was not changed. A submitted provider job may still consume credits.") }
    }

    public func assets(for song: Song) -> [UUID: Data] {
        let ids = Set(song.assets.map(\.id))
        return Dictionary(completed.values.filter { ids.contains($0.asset.id) }.map { ($0.asset.id, $0.data) }, uniquingKeysWith: { first, _ in first })
    }

    private static func inspect(data: Data, score: VocalScore, provider: String, singerID: String, sourceClipID: UUID) throws -> AudioAsset {
        // Decode off the audio thread. Never trust service-supplied durations.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-vocal-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        let expected = score.lengthBeats * 60 / score.tempo
        guard rate.isFinite, rate >= 8_000, rate <= 192_000, (1...2).contains(Int(file.processingFormat.channelCount)),
              duration.isFinite, duration > 0, duration <= 70, duration >= expected - 0.25, duration <= expected + 5 else {
            throw ProjectError("The provider returned audio with an unexpected format or duration. Try a shorter phrase.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw ProjectError("Cannot decode the vocal audio.") }
        var peak: Float = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: 4096)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw ProjectError("The vocal WAV is incomplete.") }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = channels[channel][frame]
                    guard sample.isFinite else { throw ProjectError("The vocal audio contains invalid samples.") }
                    peak = max(peak, abs(sample))
                }
            }
        }
        guard peak > 0.00001 else { throw ProjectError("The vocal provider returned silent audio.") }
        return AudioAsset(fileName: "Generated Vocals.wav", duration: duration, sampleRate: rate, channels: Int(file.processingFormat.channelCount),
                          vocalTake: VocalTake(provider: provider, singerID: singerID, sourceClipID: sourceClipID, score: score))
    }
}

public struct GeneratedVocal: Sendable {
    public var asset: AudioAsset
    public var data: Data
    public init(asset: AudioAsset, data: Data) { self.asset = asset; self.data = data }
}

/// Provider failures must terminate the draft, rather than trigger an automatic
/// model upgrade that might spend additional synthesis credits.
public struct VocalRenderFailure: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}
