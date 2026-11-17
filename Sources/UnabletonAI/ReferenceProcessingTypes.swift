import Foundation

public struct ReferenceDescription: Codable, Sendable, Equatable {
    public var description: String
    public var instruments: [String]
    public var genres: [String]
    public var tags: [String]
    public init(description: String, instruments: [String] = [], genres: [String] = [], tags: [String] = []) {
        self.description = description; self.instruments = instruments; self.genres = genres; self.tags = tags
    }
}

/// Local paths are resolved by the host and never returned to the composer.
public struct ReferenceArtifact: Sendable, Equatable {
    public var name: String
    public var url: URL
    public init(name: String, url: URL) { self.name = name; self.url = url }
}

public struct ReferenceSeparation: Sendable, Equatable {
    public var audio: [ReferenceArtifact]
    public var midi: [ReferenceArtifact]
    public var model: String
    /// Excluded vocal stem used only as negative evidence for instrumental notes.
    public var vocalReference: URL?
    public init(audio: [ReferenceArtifact], midi: [ReferenceArtifact] = [], model: String = "local-reference-v1", vocalReference: URL? = nil) {
        self.audio = audio; self.midi = midi; self.model = model; self.vocalReference = vocalReference
    }
}

/// Separation and transcription are independent so an audio remix never pays
/// the local compute cost of extracting notes it will not use.
public protocol SongReferenceProcessing: Sendable {
    var separationIdentity: String { get }
    var transcriptionIdentity: String { get }
    func separate(preparedAudio: URL, into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceSeparation
    func transcribe(separation: ReferenceSeparation, into directory: URL, maximumScratchBytes: Int64) async throws -> [ReferenceArtifact]
    func reconstruct(separation: ReferenceSeparation, startSeconds: Double, endSeconds: Double,
                     into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceArtifact
}

extension SongReferenceProcessing {
    public var separationIdentity: String { String(reflecting: Self.self) + ":separation-v1" }
    public var transcriptionIdentity: String { String(reflecting: Self.self) + ":transcription-v1" }
    public func transcribe(separation: ReferenceSeparation, into directory: URL, maximumScratchBytes: Int64) async throws -> [ReferenceArtifact] {
        separation.midi
    }
    public func reconstruct(separation: ReferenceSeparation, startSeconds: Double, endSeconds: Double,
                            into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceArtifact {
        throw ReferenceProcessingFailure("This local processor does not support instrument reconstruction. Update the app and local processing setup.")
    }
}

/// Source compatibility for existing injected processors. Production local
/// engines override both identities with pinned engine/model versions.
public typealias SongDescribingAndSeparating = SongReferenceProcessing

public enum ReferenceFileValidation {
    public static func size(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
            throw ReferenceProcessingFailure("A processing artifact is not a regular file.")
        }
        return Int64(size)
    }
}
