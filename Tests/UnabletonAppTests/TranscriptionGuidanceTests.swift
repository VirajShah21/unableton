import Foundation
@preconcurrency import AVFAudio
import Testing
import UnabletonCore
import UnabletonAudio
import UnabletonAI
@testable import Unableton

private enum GuidanceFailure: LocalizedError {
    case timeout, provider, unexpectedAI
    var errorDescription: String? {
        switch self {
        case .timeout: "Transcription guidance fixture timed out."
        case .provider: "The fixture arranger could not complete this take."
        case .unexpectedAI: "Faithful Add unexpectedly requested AI."
        }
    }
}

private actor GuidanceArranger: TranscriptionArranging {
    private let shouldFail: Bool
    private var requests: [TranscriptionArrangementRequest] = []
    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
    func arrange(request: TranscriptionArrangementRequest, configuration: AgentConfiguration,
                 status: @escaping @Sendable (String) -> Void) async throws -> TranscriptionArrangementResult {
        requests.append(request)
        if shouldFail { throw GuidanceFailure.provider }
        let source = try request.transcript.notes(tempo: request.song.tempo)
        let changes = request.options.timing == .preserve ? [] : source.map {
            TranscriptionTimingChange(sourceEventID: $0.id, startBeat: $0.startBeat, duration: $0.duration)
        }
        return .init(plan: .init(timingChanges: changes, summary: "Aligned the measured phrase."),
                     model: "guidance-fixture", inputTokens: 11, outputTokens: 7)
    }
    func count() -> Int { requests.count }
}

private struct GuidanceFixture {
    let directory: URL
    let url: URL
    let bytes: Data
    let duration: Double
    let transcript: PerformanceTranscript?
}

private func guidanceFixture(empty: Bool = false) throws -> GuidanceFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-Guidance-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("whistle.wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    do {
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        if !empty {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0..<16_000 {
                let time = Double(frame) / 16_000
                samples[frame] = (0.1..<0.5).contains(time) ? Float(0.2 * sin(2 * .pi * 523.25 * time)) : 0
            }
            try writer.write(from: buffer)
        }
    }
    let transcript: PerformanceTranscript? = empty ? nil : .init(mode: .whistle, events: [
        .init(pitch: 72, startSeconds: 0.1, durationSeconds: 0.4, velocity: 0.8, confidence: 0.95)
    ], duration: 1)
    return GuidanceFixture(directory: directory, url: url, bytes: try Data(contentsOf: url),
                           duration: empty ? 0 : 1, transcript: transcript)
}

private func guidanceProject() -> ProjectFile {
    var file = ProjectFile(); file.song.tempo = 120
    file.song.tracks = [Track(name: "Existing music", instrumentID: "synth.pad", clips: [
        Clip(name: "Keep this phrase", startBeat: 4, lengthBeats: 4, notes: [NoteEvent(pitch: 60, duration: 1)])
    ])]
    return file
}

@MainActor
private func seedGuidance(_ store: TranscriptionSession, fixture: GuidanceFixture, at start: Double = 196.5) throws {
    store.configureMode(.whistle)
    store.take = .init(url: fixture.url, startBeat: start, tempo: 120, duration: fixture.duration, sampleRate: 16_000, channels: 1)
    store.transcript = try #require(fixture.transcript)
    store.options.targetLengthBeats = 4
    store.phase = .review
}

@MainActor
private func guidanceStore(_ project: ProjectSession, arranger: any TranscriptionArranging = GuidanceArranger()) -> TranscriptionSession {
    let store = TranscriptionSession(project: project, arranger: arranger)
    project.transcription = store
    return store
}

@MainActor
private func closeGuidance(_ project: ProjectSession, _ store: TranscriptionSession) {
    store.cancelWork(); store.take = nil
    project.close()
}

@MainActor
private func waitForGuidance(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw GuidanceFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite(.serialized)
@MainActor
struct TranscriptionGuidanceTests {
    @Test func captureFailureExitsStartingAndRecordingWithoutChangingTheSong() {
        let project = ProjectSession(file: guidanceProject(), keyProvider: { nil }, mode: .superhuman)
        let store = guidanceStore(project)
        defer { closeGuidance(project, store) }
        let original = project.file
        for phase in [TranscriptionSession.Phase.starting, .recording] {
            store.phase = phase
            let previousOperation = store.operationID
            store.captureFailed("The microphone returned no audio samples.")
            #expect(store.phase == .ready && !store.isCapturing && !store.isWorking)
            #expect(store.error?.contains("no audio samples") == true)
            #expect(store.status.contains("Check the input"))
            #expect(store.operation == nil && store.operationID != previousOperation)
            #expect(project.file == original && project.assetData.isEmpty)
        }
        store.phase = .review; store.error = nil
        store.captureFailed("An unrelated output error.")
        #expect(store.phase == .review && store.error == nil)
    }

    @Test func emptyImportedWAVExplainsMissingSamplesInsteadOfTheDurationLimit() async throws {
        let fixture = try guidanceFixture(empty: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(file: guidanceProject(), keyProvider: { nil }, mode: .superhuman)
        let store = guidanceStore(project)
        defer { closeGuidance(project, store) }
        let original = project.file
        store.importTake(url: fixture.url)
        try await waitForGuidance { store.operation == nil }
        #expect(store.error?.contains("no audio samples") == true)
        #expect(store.error?.contains("60 seconds") == false)
        #expect(store.status.contains("Could not open this recording"))
        #expect(store.phase == .ready && store.take == nil && store.transcript == nil)
        #expect(project.file == original && project.assetData.isEmpty)
    }

    @Test func emptyCapturedWAVLeavesTheOriginalAvailableWithAnActionableError() async throws {
        let fixture = try guidanceFixture(empty: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(file: guidanceProject(), keyProvider: { nil }, mode: .superhuman)
        let store = guidanceStore(project)
        defer { closeGuidance(project, store) }
        let original = project.file
        store.take = .init(url: fixture.url, startBeat: 0, tempo: 120, duration: 0, sampleRate: 16_000, channels: 1)
        store.analyzeTake()
        try await waitForGuidance { store.operation == nil }
        #expect(store.error?.contains("no audio samples") == true)
        #expect(store.error?.contains("60 seconds") == false)
        #expect(store.status.contains("Nothing was added"))
        #expect(store.phase == .ready && store.transcript == nil && store.take?.url == fixture.url)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(project.file == original && project.assetData.isEmpty)
    }

    @Test func faithfulAddCommitsOnceAndRevealsTheFirstAddedTrack() async throws {
        let fixture = try guidanceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = guidanceProject()
        let project = ProjectSession(file: original, keyProvider: { throw GuidanceFailure.unexpectedAI }, mode: .superhuman)
        let store = guidanceStore(project), undo = UndoManager()
        undo.groupsByEvent = false; project.undoManager = undo
        defer { closeGuidance(project, store) }
        try seedGuidance(store, fixture: fixture)
        undo.beginUndoGrouping(); store.addToSong()
        try await waitForGuidance { store.operation == nil }; undo.endUndoGrouping()
        #expect(store.error == nil && store.alreadyInserted)
        #expect(project.file.song.revision == original.song.revision + 1)
        #expect(project.file.song.tracks.count == 2 && project.file.song.tracks[0] == original.song.tracks[0])
        let added = try #require(project.file.song.tracks.last)
        let reveal = try #require(project.arrangementReveal)
        #expect(reveal.trackID == added.id && reveal.beat == 196.5)
        #expect(project.selection.trackID == added.id && project.selection.clipID == added.clips.first?.id)
        #expect(added.clips.first?.notes.map(\.pitch) == [72])
        #expect(project.file.generations.isEmpty && project.previewPlayer == nil)
        let inserted = project.file
        store.addToSong()
        #expect(project.file == inserted && store.operation == nil)
        store.revealInSong()
        #expect(project.arrangementReveal?.id != reveal.id && project.arrangementReveal?.trackID == added.id)
        #expect(project.file == inserted)
        undo.undo()
        #expect(project.file.song.tracks == original.song.tracks && project.file.song.assets.isEmpty)
        #expect(!store.alreadyInserted && !undo.canUndo && undo.canRedo)
        undo.redo()
        #expect(store.alreadyInserted && project.file.song.tracks.last?.id == added.id)
    }

    @Test func AIAddPreparesAndCommitsFromASingleActionWithoutPlayingAPreview() async throws {
        let fixture = try guidanceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = guidanceProject(), arranger = GuidanceArranger()
        let project = ProjectSession(file: original, keyProvider: { "fixture-key" }, mode: .superhuman)
        let store = guidanceStore(project, arranger: arranger), undo = UndoManager()
        undo.groupsByEvent = false; project.undoManager = undo
        defer { closeGuidance(project, store) }
        try seedGuidance(store, fixture: fixture)
        store.options.timing = .autoTime
        undo.beginUndoGrouping(); store.addToSong()
        try await waitForGuidance { store.operation == nil }; undo.endUndoGrouping()
        #expect(await arranger.count() == 1)
        #expect(store.error == nil && store.alreadyInserted && store.phase == .review)
        #expect(project.file.song.tracks.count == 2 && project.file.song.revision == original.song.revision + 1)
        #expect(project.file.generations.count == 1 && project.file.generations[0].model == "guidance-fixture")
        #expect(project.arrangementReveal?.trackID == project.file.song.tracks.last?.id)
        #expect(project.previewPlayer == nil)
        let messages = project.file.conversations.last?.messages
        undo.undo()
        #expect(project.file.song.tracks == original.song.tracks && !undo.canUndo)
        #expect(project.file.generations[0].isUndone && project.file.conversations.last?.messages == messages)
        undo.redo()
        #expect(project.file.song.tracks.count == 2 && !project.file.generations[0].isUndone)
    }

    @Test func successfulPreviewPreparesAnAuditionWithoutCommittingMusic() async throws {
        let fixture = try guidanceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = guidanceProject(), arranger = GuidanceArranger()
        let project = ProjectSession(file: original, keyProvider: { "fixture-key" }, mode: .superhuman)
        let store = guidanceStore(project, arranger: arranger)
        defer { closeGuidance(project, store) }
        try seedGuidance(store, fixture: fixture)
        store.options.timing = .autoTime
        store.preview(autoplay: false)
        try await waitForGuidance { store.operation == nil }
        #expect(await arranger.count() == 1)
        #expect(store.error == nil && store.isPrepared && store.previewReady && !store.alreadyInserted)
        #expect(project.file == original && project.assetData.isEmpty && project.arrangementReveal == nil)
        #expect(project.previewPlayer == nil)
        let rendered = try #require(store.renderedPreviewURL)
        #expect(FileManager.default.fileExists(atPath: rendered.path))
        let audio = try AVAudioFile(forReading: rendered)
        #expect(audio.length > 0)
    }

    @Test func failedAIAddKeepsTheSongAndTakeForRetry() async throws {
        let fixture = try guidanceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = guidanceProject(), arranger = GuidanceArranger(shouldFail: true)
        let project = ProjectSession(file: original, keyProvider: { "fixture-key" }, mode: .superhuman)
        let store = guidanceStore(project, arranger: arranger)
        defer { closeGuidance(project, store) }
        try seedGuidance(store, fixture: fixture)
        let transcript = store.transcript
        store.options.timing = .autoTime
        store.addToSong(); try await waitForGuidance { store.operation == nil }
        #expect(await arranger.count() == 1)
        #expect(store.error == GuidanceFailure.provider.errorDescription && store.phase == .review)
        #expect(project.file == original && project.assetData.isEmpty && project.arrangementReveal == nil)
        #expect(store.take?.url == fixture.url && store.transcript == transcript && !store.alreadyInserted)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(store.prepared == nil && !store.previewReady && project.previewPlayer == nil)
    }
}
