import Foundation
import UnabletonCore

/// A project cache of local work, shared by composer upgrades and replans.
/// Model/version identities are included in every operation fingerprint.
public actor ReferenceProcessing {
    public static let maximumScratchBytes: Int64 = 4 * 1024 * 1024 * 1024
    public typealias PrepareAudio = @Sendable (_ source: URL, _ destination: URL) async throws -> URL
    private let provider: any SongReferenceProcessing
    private let directory: URL
    private let prepare: PrepareAudio
    private var prepared: [String: URL] = [:]
    private var separations: [String: ReferenceSeparation] = [:]
    private var transcriptions: [String: [ReferenceArtifact]] = [:]
    private var reconstructions: [String: ReferenceReconstruction] = [:]
    private var separationDirectories: [String: URL] = [:]
    private var transcriptionDirectories: [String: URL] = [:]
    private var reconstructionDirectories: [String: URL] = [:]
    private var requested = Set<String>()
    private var active: String?
    private let maximumCacheBytes: Int64

    public init(provider: any SongReferenceProcessing, directory: URL,
                maximumCacheBytes: Int64 = ReferenceProcessing.maximumScratchBytes,
                prepare: @escaping PrepareAudio = { source, _ in source }) {
        self.provider = provider; self.directory = directory; self.prepare = prepare
        self.maximumCacheBytes = max(1, min(Self.maximumScratchBytes, maximumCacheBytes))
    }

    public func separate(source: URL, sha256: String, budget: GenerationBudget? = nil) async throws -> ReferenceSeparation {
        try validate(sha256)
        let fingerprint = separationKey(sha256)
        if var result = separations[fingerprint] {
            try validateArtifacts(result.audio); try validateArtifacts(result.midi)
            result.midi = transcriptions[transcriptionKey(sha256, includeVocals: false)] ?? instrumentalArtifacts(result.midi)
            return result
        }
        try begin(fingerprint); defer { active = nil }
        let audio = try await preparedAudio(source: source, sha256: sha256)
        let allowance = try remainingBytes()
        try reserve(fingerprint)
        let output = directory.appendingPathComponent("Stems-\(UUID())", isDirectory: true)
        do {
            var result = try await dependency(budget) { [provider] in
                try await provider.separate(preparedAudio: audio, into: output, maximumScratchBytes: allowance)
            }
            try Task.checkCancellation()
            guard !result.audio.isEmpty else { throw ReferenceProcessingFailure("Local separation returned no audio stems.") }
            try validateArtifacts(result.audio, inside: output); try validateArtifacts(result.midi, inside: output)
            guard try cacheByteCount() <= maximumCacheBytes else { throw cacheFull() }
            result.vocalReference = nil
            result.midi = instrumentalArtifacts(result.midi)
            separations[fingerprint] = result
            separationDirectories[fingerprint] = output
            if !result.midi.isEmpty { transcriptions[transcriptionKey(sha256, includeVocals: false)] = result.midi }
            return result
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw CancellationError() }
            throw failure(error)
        }
    }

    public func transcribe(source: URL, sha256: String, includeVocals: Bool = false, budget: GenerationBudget? = nil) async throws -> [ReferenceArtifact] {
        try validate(sha256)
        let fingerprint = transcriptionKey(sha256, includeVocals: includeVocals)
        if let result = transcriptions[fingerprint] { try validateArtifacts(result); return result }
        var separation = try await separate(source: source, sha256: sha256, budget: budget)
        separation.vocalReference = separation.audio.first(where: { $0.name == "vocals" })?.url
        separation.audio = separation.audio.filter { ["bass", "other"].contains($0.name) || (includeVocals && $0.name == "vocals") }
        separation.midi = separation.midi.filter { ["bass", "other"].contains($0.name) || (includeVocals && $0.name == "vocals") }
        if let result = transcriptions[fingerprint] { try validateArtifacts(result); return result }
        try begin(fingerprint); defer { active = nil }
        let allowance = try remainingBytes()
        try reserve(fingerprint)
        let output = directory.appendingPathComponent("MIDI-\(UUID())", isDirectory: true)
        do {
            let selectedSeparation = separation
            let result = try await dependency(budget) { [provider] in
                try await provider.transcribe(separation: selectedSeparation, into: output, maximumScratchBytes: allowance)
            }
            try Task.checkCancellation()
            try validateArtifacts(result, inside: output)
            let selectedNames = Set(selectedSeparation.audio.map(\.name))
            guard result.allSatisfy({ selectedNames.contains($0.name) && (["bass", "other"].contains($0.name) || (includeVocals && $0.name == "vocals")) }) else {
                throw ReferenceProcessingFailure("Local transcription returned an unauthorized stem. Vocals stay as audio unless explicitly requested as instrumental notes.")
            }
            guard try cacheByteCount() <= maximumCacheBytes else { throw cacheFull() }
            transcriptions[fingerprint] = result
            transcriptionDirectories[fingerprint] = output
            return result
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw CancellationError() }
            throw failure(error)
        }
    }

    public func cachedTranscription(sha256: String, includeVocals: Bool = false) -> [ReferenceArtifact]? { transcriptions[transcriptionKey(sha256, includeVocals: includeVocals)] }

    /// Reconstruction has its own versioned score cache. Legacy raw MIDI is
    /// never treated as a cleaned instrumental reconstruction.
    public func reconstruct(source: URL, sha256: String, startSeconds: Double, endSeconds: Double,
                            budget: GenerationBudget? = nil) async throws -> ReferenceReconstruction {
        try validate(sha256)
        try validateRange(startSeconds, endSeconds)
        let fingerprint = reconstructionKey(sha256, startSeconds, endSeconds)
        if let result = reconstructions[fingerprint] { return result }
        guard reconstructions.count < 64 else {
            throw ReferenceProcessingFailure("This project has cached 64 reconstruction ranges. Close and reopen it to clear temporary processing results.")
        }
        let separation = try await separate(source: source, sha256: sha256, budget: budget)
        try begin(fingerprint); defer { active = nil }
        let allowance = min(try remainingBytes(), Int64(SongAttachmentLimits.maximumMetadataBytes))
        try reserve(fingerprint)
        let output = directory.appendingPathComponent("Reconstruction-\(UUID())", isDirectory: true)
        do {
            let artifact = try await dependency(budget) { [provider] in
                try await provider.reconstruct(separation: separation, startSeconds: startSeconds, endSeconds: endSeconds,
                    into: output, maximumScratchBytes: allowance)
            }
            try Task.checkCancellation()
            try validateArtifacts([artifact], inside: output)
            guard artifact.name == "reconstruction", try ReferenceFileValidation.size(artifact.url) <= allowance else { throw cacheFull() }
            let data = try Data(contentsOf: artifact.url)
            guard data.count <= SongAttachmentLimits.maximumMetadataBytes else { throw cacheFull() }
            let result = try JSONDecoder().decode(ReferenceReconstruction.self, from: data)
            try result.validate(maximumDuration: endSeconds)
            guard result.profile == ReferenceReconstruction.currentProfile,
                  abs(result.sourceStartSeconds - startSeconds) < 0.000_001,
                  abs(result.sourceEndSeconds - endSeconds) < 0.000_001 else {
                throw ReferenceProcessingFailure("The local reconstruction does not match the requested source range or processing version.")
            }
            guard try cacheByteCount() <= maximumCacheBytes else { throw cacheFull() }
            reconstructions[fingerprint] = result
            reconstructionDirectories[fingerprint] = output
            return result
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw CancellationError() }
            throw failure(error)
        }
    }

    /// The host calls this when audio-header or alignment validation rejects
    /// returned files. Rejected work requires an explicit retry.
    public func rejectSeparation(sha256: String) throws {
        try validate(sha256)
        let separation = separationKey(sha256)
        guard active == nil else { throw rejectionDuringWork() }
        try rejectTranscription(sha256: sha256)
        for key in reconstructionDirectories.keys.filter({ $0.hasPrefix(reconstructionPrefix(sha256)) }) {
            reconstructions.removeValue(forKey: key)
            if let output = reconstructionDirectories.removeValue(forKey: key) { try? FileManager.default.removeItem(at: output) }
            requested.insert(key)
        }
        separations.removeValue(forKey: separation)
        if let output = separationDirectories.removeValue(forKey: separation) { try? FileManager.default.removeItem(at: output) }
        requested.insert(separation)
    }

    /// A malformed MIDI result must not discard good separated audio. MIDI
    /// from legacy injected processors may share the stem output directory.
    public func rejectTranscription(sha256: String) throws {
        try validate(sha256)
        let separation = separationKey(sha256)
        let keys = [false, true].map { transcriptionKey(sha256, includeVocals: $0) }
        guard active != separation, !keys.contains(where: { active == $0 }) else { throw rejectionDuringWork() }
        var artifacts: [ReferenceArtifact] = []
        for key in keys {
            artifacts += transcriptions.removeValue(forKey: key) ?? []
            if let output = transcriptionDirectories.removeValue(forKey: key) { try? FileManager.default.removeItem(at: output) }
            requested.insert(key)
        }
        if var result = separations[separation] { result.midi = []; separations[separation] = result }
        let audioURLs = Set(separations.values.flatMap(\.audio).map(\.url))
        for artifact in artifacts where !audioURLs.contains(artifact.url) { try? FileManager.default.removeItem(at: artifact.url) }
    }

    /// Explicit retry clears failed local fingerprints without running work.
    /// Successful stems and measured notes remain cached.
    public func retryFailed(sha256: String) throws {
        try validate(sha256)
        let separation = separationKey(sha256)
        if separations[separation] == nil, active != separation { requested.remove(separation) }
        for transcription in [false, true].map({ transcriptionKey(sha256, includeVocals: $0) }) {
            if transcriptions[transcription] == nil, active != transcription { requested.remove(transcription) }
        }
        for key in requested.filter({ $0.hasPrefix(reconstructionPrefix(sha256)) })
            where reconstructions[key] == nil && active != key { requested.remove(key) }
    }

    public func cacheByteCount() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw ReferenceProcessingFailure("Could not inspect the local song-processing cache.")
        }
        var total: Int64 = 0
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ReferenceProcessingFailure("The local processing cache contains an unsupported link.") }
            if values.isDirectory == true { continue }
            let size = try ReferenceFileValidation.size(url)
            guard size <= Int64.max - total else { throw cacheFull() }
            total += size
        }
        return total
    }

    private func preparedAudio(source: URL, sha256: String) async throws -> URL {
        if let url = prepared[sha256] { return url }
        guard try ReferenceFileValidation.size(source) > 0 else { throw ReferenceProcessingFailure("The attached song is empty.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try remainingBytes()
        let destination = directory.appendingPathComponent("Prepared-\(sha256).wav")
        do {
            let result = try await prepare(source, destination)
            try Task.checkCancellation()
            guard try ReferenceFileValidation.size(result) > 0, try cacheByteCount() <= maximumCacheBytes else { throw cacheFull() }
            prepared[sha256] = result
            return result
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    private func separationKey(_ hash: String) -> String { "separate:\(hash):\(provider.separationIdentity)" }
    private func transcriptionKey(_ hash: String, includeVocals: Bool) -> String { "transcribe:\(hash):\(provider.separationIdentity):\(provider.transcriptionIdentity):vocal-policy-v1:\(includeVocals)" }
    private func instrumentalArtifacts(_ artifacts: [ReferenceArtifact]) -> [ReferenceArtifact] {
        artifacts.filter { ["bass", "other"].contains($0.name) }
    }
    private func reconstructionPrefix(_ hash: String) -> String { "reconstruct:\(hash):" }
    private func reconstructionKey(_ hash: String, _ start: Double, _ end: Double) -> String {
        reconstructionPrefix(hash) + "\(provider.separationIdentity):\(provider.transcriptionIdentity):\(ReferenceReconstruction.currentProfile):\(start.bitPattern):\(end.bitPattern)"
    }
    private func validateRange(_ start: Double, _ end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= 600 else {
            throw ReferenceProcessingFailure("Choose a valid reconstruction source range within ten minutes.")
        }
    }
    private func remainingBytes() throws -> Int64 {
        let remaining = maximumCacheBytes - (try cacheByteCount())
        guard remaining > 0 else { throw cacheFull() }
        return remaining
    }
    private func validateArtifacts(_ artifacts: [ReferenceArtifact], inside output: URL? = nil) throws {
        guard artifacts.count <= 64, Set(artifacts.map(\.name)).count == artifacts.count else {
            throw ReferenceProcessingFailure("Local processing returned duplicate or too many artifacts.")
        }
        for artifact in artifacts {
            guard !artifact.name.isEmpty, artifact.name.utf8.count <= 120,
                  try ReferenceFileValidation.size(artifact.url) > 0 else { throw ReferenceProcessingFailure("Local processing returned an invalid artifact.") }
            if let output {
                let prefix = output.standardizedFileURL.path + "/"
                guard artifact.url.standardizedFileURL.path.hasPrefix(prefix), artifact.url.resolvingSymlinksInPath().path.hasPrefix(output.resolvingSymlinksInPath().path + "/") else {
                    throw ReferenceProcessingFailure("A local processing artifact is outside its output directory.")
                }
            }
        }
    }
    private func begin(_ fingerprint: String) throws {
        guard active == nil else { throw ReferenceProcessingFailure("Another local song-processing operation is still running. Wait for it to finish.") }
        active = fingerprint
    }
    private func cacheFull() -> ReferenceProcessingFailure {
        ReferenceProcessingFailure("The local song-processing cache reached its 4 GiB limit. Existing results were kept. Close this song to clear temporary files, or use shorter excerpts.")
    }
    private func rejectionDuringWork() -> ReferenceProcessingFailure {
        ReferenceProcessingFailure("Wait for local processing to finish before rejecting its cached result.")
    }
    private func validate(_ hash: String) throws {
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw ReferenceProcessingFailure("The attached song has no verified content hash.") }
    }
    private func reserve(_ fingerprint: String) throws {
        guard requested.insert(fingerprint).inserted else { throw ReferenceProcessingFailure("This local processing attempt failed earlier. Use Retry Failed Processing on the attachment, then send your prompt again.") }
    }
    private func dependency<T: Sendable>(_ budget: GenerationBudget?, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if let budget { return try await budget.withDependencyWait(kind: .referenceProcessing, operation) }
        return try await operation()
    }
    private func failure(_ error: any Error) -> ReferenceProcessingFailure {
        if let error = error as? ReferenceProcessingFailure { return error }
        return ReferenceProcessingFailure("Local song processing failed: \(error.localizedDescription). The arrangement was not changed.")
    }
}
