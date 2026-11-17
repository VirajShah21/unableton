import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private enum LocalFixtureMode: Sendable { case normal, vocalPolicy, fail, transcriptionFail, reconstructionFail, reconstructionRange, reconstructionWaiting, oversized, escape, waiting }
private actor LocalReferenceProviderStub: SongReferenceProcessing {
    nonisolated let separationIdentity = "demucs-fixture-v1:model-a"
    nonisolated let transcriptionIdentity = "basic-pitch-fixture-v1:model-b"
    let outside: URL
    var mode: LocalFixtureMode
    private var separationCalls = 0, transcriptionCalls = 0
    private var reconstructionCalls = 0
    private var allowance: Int64 = 0
    private var transcriptionInputs: [[String]] = []
    private var negativeReferences: [URL?] = []
    init(source: URL, mode: LocalFixtureMode = .normal) { outside = source; self.mode = mode }
    func setMode(_ mode: LocalFixtureMode) { self.mode = mode }
    func counts() -> (Int, Int) { (separationCalls, transcriptionCalls) }
    func reconstructionCount() -> Int { reconstructionCalls }
    func receivedAllowance() -> Int64 { allowance }
    func receivedTranscriptionInputs() -> [[String]] { transcriptionInputs }
    func receivedNegativeReferences() -> [URL?] { negativeReferences }
    func separate(preparedAudio: URL, into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceSeparation {
        separationCalls += 1; allowance = maximumScratchBytes
        if mode == .waiting { try await Task.sleep(for: .seconds(60)) }
        if mode == .fail { throw ReferenceProcessingFailure("Fixture local inference failed") }
        if mode == .escape { return ReferenceSeparation(audio: [.init(name: "vocals", url: outside)], model: separationIdentity) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = mode == .vocalPolicy ? "vocals" : "bass"
        let output = directory.appendingPathComponent("\(name).wav")
        try Data(repeating: 1, count: mode == .oversized ? 18 : 4).write(to: output)
        if mode == .vocalPolicy {
            let bass = directory.appendingPathComponent("bass.wav"); try Data(repeating: 1, count: 4).write(to: bass)
            return ReferenceSeparation(audio: [.init(name: "vocals", url: output), .init(name: "bass", url: bass)], model: separationIdentity)
        }
        return ReferenceSeparation(audio: [.init(name: name, url: output)], model: separationIdentity)
    }
    func transcribe(separation: ReferenceSeparation, into directory: URL, maximumScratchBytes: Int64) async throws -> [ReferenceArtifact] {
        transcriptionCalls += 1
        transcriptionInputs.append(separation.audio.map(\.name)); negativeReferences.append(separation.vocalReference)
        if mode == .transcriptionFail { throw ReferenceProcessingFailure("Fixture transcription failed") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if mode == .vocalPolicy {
            return try separation.audio.map { item in
                let output = directory.appendingPathComponent("\(item.name).mid")
                try Data("MThd".utf8).write(to: output)
                return ReferenceArtifact(name: item.name, url: output)
            }
        }
        let output = directory.appendingPathComponent("bass.mid")
        try Data("MThd".utf8).write(to: output)
        return [.init(name: "bass", url: output)]
    }
    func reconstruct(separation: ReferenceSeparation, startSeconds: Double, endSeconds: Double,
                     into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceArtifact {
        reconstructionCalls += 1
        if mode == .reconstructionWaiting { try await Task.sleep(for: .seconds(60)) }
        if mode == .reconstructionFail { throw ReferenceProcessingFailure("Fixture reconstruction failed") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("reconstruction.json")
        let result = ReferenceReconstruction(sourceStartSeconds: startSeconds,
            sourceEndSeconds: mode == .reconstructionRange ? endSeconds + 1 : endSeconds,
            parts: [.init(id: "bass", role: "bass", name: "Measured bass", notes: [
                .init(pitch: 40, startSeconds: startSeconds + 0.1, durationSeconds: 0.2, velocity: 90)
            ], relativeGain: 0.7, suggestedParameters: ["lfoDepth": 0])])
        try JSONEncoder().encode(result).write(to: output)
        return .init(name: "reconstruction", url: output)
    }
}

private actor ReferenceInspectionTransport: ReferenceHTTPTransport {
    private var requests: [URLRequest] = []
    private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        requests.append(request)
        if fails { throw ReferenceProcessingFailure("Fixture upload outcome is unknown") }
        return Data("{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"A possible bass entry at 0.5 seconds; uncertain.\"}}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":12}}".utf8)
    }
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws { throw ReferenceProcessingFailure("Audio inspection must not download a model or stem.") }
    func captured() -> [URLRequest] { requests }
}

private struct LocalReferenceFixture {
    let directory: URL
    let source: URL
    let cache: URL
    let hash = String(repeating: "a", count: 64)
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalReferenceTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.wav"); try Data([1, 2, 3]).write(to: source)
        cache = directory.appendingPathComponent("cache")
    }
    func processing(_ provider: LocalReferenceProviderStub, limit: Int64 = ReferenceProcessing.maximumScratchBytes) -> ReferenceProcessing {
        ReferenceProcessing(provider: provider, directory: cache, maximumCacheBytes: limit) { source, destination in
            try FileManager.default.copyItem(at: source, to: destination); return destination
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func excerpt() throws -> URL {
        let audio = directory.appendingPathComponent("excerpt.wav")
        var wav = Data("RIFF".utf8); wav.referenceLE32(36 + 16_000); wav.append(Data("WAVEfmt ".utf8)); wav.referenceLE32(16)
        wav.referenceLE16(1); wav.referenceLE16(1); wav.referenceLE32(8_000); wav.referenceLE32(16_000); wav.referenceLE16(2); wav.referenceLE16(16)
        wav.append(Data("data".utf8)); wav.referenceLE32(16_000); wav.append(Data(repeating: 0, count: 16_000)); try wav.write(to: audio)
        return audio
    }
}
private extension Data {
    mutating func referenceLE16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func referenceLE32(_ value: UInt32) { referenceLE16(UInt16(truncatingIfNeeded: value)); referenceLE16(UInt16(truncatingIfNeeded: value >> 16)) }
}

struct ReferenceProviderTests {
    @Test func vocalInclusionHasSeparateCacheIdentityAndNegativeEvidenceIsNeverTranscribed() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source, mode: .vocalPolicy), processing = fixture.processing(provider)
        let normal = try await processing.transcribe(source: fixture.source, sha256: fixture.hash)
        #expect(normal.map(\.name) == ["bass"])
        let explicit = try await processing.transcribe(source: fixture.source, sha256: fixture.hash, includeVocals: true)
        #expect(explicit.map(\.name) == ["vocals", "bass"])
        #expect(try await processing.transcribe(source: fixture.source, sha256: fixture.hash) == normal)
        #expect(try await processing.transcribe(source: fixture.source, sha256: fixture.hash, includeVocals: true) == explicit)
        #expect(await processing.cachedTranscription(sha256: fixture.hash) == normal)
        #expect(await processing.cachedTranscription(sha256: fixture.hash, includeVocals: true) == explicit)
        #expect(await provider.receivedTranscriptionInputs() == [["bass"], ["vocals", "bass"]])
        let references = await provider.receivedNegativeReferences()
        #expect(references.count == 2 && references[0]?.lastPathComponent == "vocals.wav" && references[1]?.lastPathComponent == "vocals.wav")
        #expect(await provider.counts().0 == 1)
        #expect(await provider.counts().1 == 2)
        #expect(try await processing.separate(source: fixture.source, sha256: fixture.hash).midi == normal)
    }

    @Test func reconstructionIsVersionedAndRangeScopedWithoutUsingRawMIDI() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source), processing = fixture.processing(provider)
        let first = try await processing.reconstruct(source: fixture.source, sha256: fixture.hash, startSeconds: 0, endSeconds: 3)
        #expect(first.profile == ReferenceReconstruction.currentProfile)
        #expect(first.parts.first?.suggestedParameters["lfoDepth"] == 0)
        #expect(try await processing.reconstruct(source: fixture.source, sha256: fixture.hash, startSeconds: 0, endSeconds: 3) == first)
        let next = try await processing.reconstruct(source: fixture.source, sha256: fixture.hash, startSeconds: 3, endSeconds: 6)
        #expect(next.sourceStartSeconds == 3 && next.sourceEndSeconds == 6)
        #expect(await provider.reconstructionCount() == 2)
        #expect(await provider.counts().0 == 1)
        #expect(await provider.counts().1 == 0)
    }

    @Test func reconstructionFailureAndInvalidRangeRequireExplicitRetryAndKeepStems() async throws {
        for mode in [LocalFixtureMode.reconstructionFail, .reconstructionRange] {
            let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
            let provider = LocalReferenceProviderStub(source: fixture.source, mode: mode), processing = fixture.processing(provider)
            for _ in 0..<2 {
                await #expect(throws: ReferenceProcessingFailure.self) {
                    _ = try await processing.reconstruct(source: fixture.source, sha256: fixture.hash, startSeconds: 0, endSeconds: 3)
                }
            }
            #expect(await provider.reconstructionCount() == 1)
            #expect(await provider.counts().0 == 1)
            let cachedFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)
            #expect(!cachedFiles.contains { $0.hasPrefix("Reconstruction-") })
            try await processing.retryFailed(sha256: fixture.hash)
            await provider.setMode(.normal)
            _ = try await processing.reconstruct(source: fixture.source, sha256: fixture.hash, startSeconds: 0, endSeconds: 3)
            #expect(await provider.reconstructionCount() == 2)
            #expect(await provider.counts().0 == 1)
        }
    }

    @Test func cancellationDuringReconstructionKeepsReusableStemOutputs() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source, mode: .reconstructionWaiting), processing = fixture.processing(provider)
        let task = Task { try await processing.reconstruct(source: fixture.source, sha256: fixture.hash, startSeconds: 0, endSeconds: 3) }
        for _ in 0..<1000 {
            if await provider.reconstructionCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await provider.reconstructionCount() == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let stems = try await processing.separate(source: fixture.source, sha256: fixture.hash)
        #expect(!stems.audio.isEmpty)
        #expect(await provider.counts().0 == 1)
        #expect(try Data(contentsOf: fixture.source) == Data([1, 2, 3]))
    }

    @Test func separationDoesNotTranscribeAndSuccessIsReusedAcrossAttempts() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source), processing = fixture.processing(provider)
        let budget = GenerationBudget()
        let first = try await processing.separate(source: fixture.source, sha256: fixture.hash, budget: budget)
        let second = try await processing.separate(source: fixture.source, sha256: fixture.hash, budget: budget)
        #expect(first == second && first.midi.isEmpty)
        #expect(first.model == provider.separationIdentity)
        let counts = await provider.counts()
        #expect(counts.0 == 1 && counts.1 == 0)
        #expect(await budget.snapshot().requests == 0)
        #expect(try Data(contentsOf: fixture.source) == Data([1, 2, 3]))
    }

    @Test func transcriptionIsExplicitAndKeepsExistingStemCache() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source), processing = fixture.processing(provider)
        let stems = try await processing.separate(source: fixture.source, sha256: fixture.hash)
        #expect(stems.midi.isEmpty)
        let notes = try await processing.transcribe(source: fixture.source, sha256: fixture.hash)
        #expect(try await processing.transcribe(source: fixture.source, sha256: fixture.hash) == notes)
        #expect(await processing.cachedTranscription(sha256: fixture.hash) == notes)
        let cached = try await processing.separate(source: fixture.source, sha256: fixture.hash)
        #expect(cached.audio == stems.audio && cached.midi == notes)
        let counts = await provider.counts()
        #expect(counts.0 == 1 && counts.1 == 1)
    }

    @Test func failedLocalWorkRequiresExplicitRetryWithoutDiscardingSuccess() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source, mode: .fail), processing = fixture.processing(provider)
        for _ in 0..<2 {
            await #expect(throws: ReferenceProcessingFailure.self) { _ = try await processing.separate(source: fixture.source, sha256: fixture.hash) }
        }
        #expect(await provider.counts().0 == 1)
        try await processing.retryFailed(sha256: fixture.hash)
        #expect(await provider.counts().0 == 1)
        await provider.setMode(.normal)
        let result = try await processing.separate(source: fixture.source, sha256: fixture.hash)
        try await processing.retryFailed(sha256: fixture.hash)
        #expect(try await processing.separate(source: fixture.source, sha256: fixture.hash) == result)
        #expect(await provider.counts().0 == 2)
    }

    @Test func cumulativeCacheAllowanceCleansOnlyTheOversizedResult() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source, mode: .oversized)
        let processing = fixture.processing(provider, limit: 20)
        await #expect(throws: ReferenceProcessingFailure.self) { _ = try await processing.separate(source: fixture.source, sha256: fixture.hash) }
        #expect(try await processing.cacheByteCount() == 3)
        #expect(await provider.receivedAllowance() == 17)
        #expect(try Data(contentsOf: fixture.source) == Data([1, 2, 3]))
    }

    @Test func transcriptionRetryRetainsSuccessfulStems() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source, mode: .transcriptionFail), processing = fixture.processing(provider)
        for _ in 0..<2 {
            await #expect(throws: ReferenceProcessingFailure.self) { _ = try await processing.transcribe(source: fixture.source, sha256: fixture.hash) }
        }
        let failedCounts = await provider.counts()
        #expect(failedCounts.0 == 1 && failedCounts.1 == 1)
        try await processing.retryFailed(sha256: fixture.hash)
        await provider.setMode(.normal)
        #expect(try await processing.transcribe(source: fixture.source, sha256: fixture.hash).count == 1)
        let finalCounts = await provider.counts()
        #expect(finalCounts.0 == 1 && finalCounts.1 == 2)
    }

    @Test func hostRejectedMIDIRetainsStemsAndRequiresExplicitRetry() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source), processing = fixture.processing(provider)
        let notes = try await processing.transcribe(source: fixture.source, sha256: fixture.hash)
        let audio = try await processing.separate(source: fixture.source, sha256: fixture.hash).audio
        try await processing.rejectTranscription(sha256: fixture.hash)
        let retained = try await processing.separate(source: fixture.source, sha256: fixture.hash)
        #expect(retained.audio == audio && retained.midi.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: notes[0].url.path))
        await #expect(throws: ReferenceProcessingFailure.self) { _ = try await processing.transcribe(source: fixture.source, sha256: fixture.hash) }
        try await processing.retryFailed(sha256: fixture.hash)
        #expect(try await processing.transcribe(source: fixture.source, sha256: fixture.hash).count == 1)
        let counts = await provider.counts()
        #expect(counts.0 == 1 && counts.1 == 2)
    }

    @Test func hostRejectedStemsAlsoInvalidateTheirMIDIAndRequireExplicitRetry() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source), processing = fixture.processing(provider)
        _ = try await processing.transcribe(source: fixture.source, sha256: fixture.hash)
        try await processing.rejectSeparation(sha256: fixture.hash)
        #expect(await processing.cachedTranscription(sha256: fixture.hash) == nil)
        #expect(try await processing.cacheByteCount() == 3)
        await #expect(throws: ReferenceProcessingFailure.self) { _ = try await processing.separate(source: fixture.source, sha256: fixture.hash) }
        try await processing.retryFailed(sha256: fixture.hash)
        #expect(try await processing.transcribe(source: fixture.source, sha256: fixture.hash).count == 1)
        let counts = await provider.counts()
        #expect(counts.0 == 2 && counts.1 == 2)
    }

    @Test func artifactsOutsideTheOwnedDirectoryCannotEnterTheCache() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source, mode: .escape), processing = fixture.processing(provider)
        await #expect(throws: ReferenceProcessingFailure.self) { _ = try await processing.separate(source: fixture.source, sha256: fixture.hash) }
        #expect(try await processing.cacheByteCount() == 3)
        #expect(try Data(contentsOf: fixture.source) == Data([1, 2, 3]))
    }

    @Test func cancellationStopsLocalWorkAndRetainsTheSource() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let provider = LocalReferenceProviderStub(source: fixture.source, mode: .waiting), processing = fixture.processing(provider)
        let task = Task { try await processing.separate(source: fixture.source, sha256: fixture.hash, budget: GenerationBudget()) }
        for _ in 0..<1000 {
            if await provider.counts().0 == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await provider.counts().0 == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await processing.cacheByteCount() == 3)
        #expect(try Data(contentsOf: fixture.source) == Data([1, 2, 3]))
    }

    @Test func audioHelperUsesExplicitModelAndSharedBudgetWithoutStoringAudio() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let audio = try fixture.excerpt(), transport = ReferenceInspectionTransport(), budget = GenerationBudget()
        let text = try await OpenAIAudioInspection(apiKey: "key", transport: transport).inspect(audio: audio, question: "Where does the bass enter?", budget: budget)
        #expect(text.contains("uncertain"))
        #expect(await budget.snapshot().requests == 1)
        let usage = await budget.snapshot()
        #expect(usage.inputTokens == 100 && usage.outputTokens == 12)
        let request = try #require(await transport.captured().first)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(body["model"]?.stringValue == "gpt-audio-1.5")
        #expect(body["store"] == .bool(false) && body["modalities"] == .array([.string("text")]))
    }

    @Test func disabledAudioInspectionSendsNoRequest() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let transport = ReferenceInspectionTransport(), audio = try fixture.excerpt()
        let inspector = OpenAIAudioInspection(apiKey: "key", transport: transport, authorize: {
            throw ReferenceProcessingFailure("OpenAI audio inspection is disabled")
        })
        await #expect(throws: ReferenceProcessingFailure.self) {
            _ = try await inspector.inspect(audio: audio, question: "What instruments?", budget: GenerationBudget())
        }
        #expect(await transport.captured().isEmpty)
    }

    @Test func audioInspectionFailureNeverRepeatsAPossiblyBilledRequest() async throws {
        let fixture = try LocalReferenceFixture(); defer { fixture.remove() }
        let transport = ReferenceInspectionTransport(fails: true), audio = try fixture.excerpt(), budget = GenerationBudget()
        await #expect(throws: ReferenceProcessingFailure.self) {
            _ = try await OpenAIAudioInspection(apiKey: "key", transport: transport).inspect(audio: audio, question: "Describe this excerpt", budget: budget)
        }
        #expect(await transport.captured().count == 1)
        #expect(await budget.snapshot().requests == 1)
        #expect(await budget.snapshot().retries == 0)
    }

    @Test func dependencyKindsShareOneWaitAllowanceAndKeepUsage() async throws {
        let clock = ReferenceBudgetClock()
        let budget = GenerationBudget(timeout: 100, maximumDependencyWait: 100, now: { clock.now() })
        try await budget.beginRequest(limit: 32)
        try await budget.recordUsage(inputTokens: 100, outputTokens: 20)
        try await budget.withDependencyWait { clock.advance(40) }
        try await budget.withDependencyWait(kind: .referenceProcessing) { clock.advance(40) }
        clock.advance(10)
        #expect(try await budget.remainingTime() == 90)
        let usage = await budget.snapshot()
        #expect(usage.requests == 1 && usage.outputTokens == 20)
        await #expect(throws: ReferenceProcessingFailure.self) { try await budget.withDependencyWait(kind: .referenceProcessing) { clock.advance(21) } }
    }

    @Test func networkURLValidationRejectsCredentialsAndLocalDestinations() {
        for text in ["http://example.com/file", "https://localhost/file", "https://machine.local/file", "https://127.0.0.1/file", "https://[::1]/file", "https://name:secret@example.com/file", "https://example.com:8080/file"] {
            #expect(!ReferenceHTTPValidation.isPublicHTTPS(URL(string: text)!))
        }
        #expect(ReferenceHTTPValidation.isPublicHTTPS(URL(string: "https://api.openai.com/v1/chat/completions")!))
    }
}

private final class ReferenceBudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ value: TimeInterval) { lock.withLock { time += value } }
}
