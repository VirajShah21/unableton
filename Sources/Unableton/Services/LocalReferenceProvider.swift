import Foundation
import UnabletonAI
import UnabletonAudio

/// Only local model jobs cross this boundary. The composer receives named
/// artifacts and measured notes, never helper paths or an audio upload URL.
struct LocalReferenceProvider: SongReferenceProcessing {
    let engine: LocalReferenceEngine
    let status: @Sendable (String) -> Void
    var separationIdentity: String { LocalReferenceEngine.separationIdentity }
    var transcriptionIdentity: String { LocalReferenceEngine.transcriptionIdentity }

    static func makeEngine() -> LocalReferenceEngine {
        let resources = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("LocalProcessing", isDirectory: true)
        return LocalReferenceEngine(resourcesDirectory: resources)
    }
    func separate(preparedAudio: URL, into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceSeparation {
        let files = try await engine.separate(source: preparedAudio, into: directory, maximumOutputBytes: maximumScratchBytes, status: status)
        return ReferenceSeparation(audio: files.map { ReferenceArtifact(name: $0.name, url: $0.url) }, midi: [], model: separationIdentity)
    }
    func transcribe(separation: ReferenceSeparation, into directory: URL, maximumScratchBytes: Int64) async throws -> [ReferenceArtifact] {
        let stems = separation.audio.map { LocalReferenceArtifact(name: $0.name, url: $0.url) }
        let files = try await engine.transcribe(stems: stems, into: directory, includeVocals: stems.contains { $0.name == "vocals" }, vocalReference: separation.vocalReference, maximumOutputBytes: maximumScratchBytes, status: status)
        return files.map { ReferenceArtifact(name: $0.name, url: $0.url) }
    }
    func reconstruct(separation: ReferenceSeparation, startSeconds: Double, endSeconds: Double,
                     into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceArtifact {
        let stems = separation.audio.map { LocalReferenceArtifact(name: $0.name, url: $0.url) }
        let score = try await engine.reconstruct(stems: stems, startSeconds: startSeconds, endSeconds: endSeconds,
            into: directory, maximumOutputBytes: maximumScratchBytes, status: status)
        return ReferenceArtifact(name: "reconstruction", url: score)
    }
}
