import Foundation
@preconcurrency import AVFAudio
import Testing
import UnabletonCore
import UnabletonAudio
import UnabletonAI
@testable import Unableton

private enum TranscriptionWorkflowFailure: LocalizedError {
    case timeout, missingCall, provider, analysis, unexpectedKey
    var errorDescription: String? {
        switch self {
        case .timeout: "Transcription fixture timed out."
        case .missingCall: "Missing transcription fixture call."
        case .provider: "Fixture provider failed."
        case .analysis: "Fixture analysis failed."
        case .unexpectedKey: "Faithful transcription requested a key unexpectedly."
        }
    }
}

private actor TranscriptionWorkflowGate<Input: Sendable, Output: Sendable> {
    private var inputs: [Input] = []
    private var pending: [Int: CheckedContinuation<Output, any Error>] = [:]
    func call(_ input: Input) async throws -> Output {
        let index = inputs.count; inputs.append(input)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { pending[index] = continuation }
            }
        } onCancel: { Task { await self.cancel(index) } }
    }
    func calls() -> [Input] { inputs }
    func pendingCount() -> Int { pending.count }
    func succeed(_ index: Int, _ result: Output) throws {
        guard let continuation = pending.removeValue(forKey: index) else { throw TranscriptionWorkflowFailure.missingCall }
        continuation.resume(returning: result)
    }
    func fail(_ index: Int, _ error: TranscriptionWorkflowFailure) throws {
        guard let continuation = pending.removeValue(forKey: index) else { throw TranscriptionWorkflowFailure.missingCall }
        continuation.resume(throwing: error)
    }
    private func cancel(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CancellationError()) }
}

private struct ControlledTranscriptionArranger: TranscriptionArranging {
    let gate: TranscriptionWorkflowGate<TranscriptionArrangementRequest, TranscriptionArrangementResult>
    func arrange(request: TranscriptionArrangementRequest, configuration: AgentConfiguration,
                 status: @escaping @Sendable (String) -> Void) async throws -> TranscriptionArrangementResult {
        try await gate.call(request)
    }
}

private struct NoTranscriptionAI: TranscriptionArranging {
    func arrange(request: TranscriptionArrangementRequest, configuration: AgentConfiguration,
                 status: @escaping @Sendable (String) -> Void) async throws -> TranscriptionArrangementResult {
        throw TranscriptionWorkflowFailure.provider
    }
}

private struct TranscriptionAudioFixture {
    var directory: URL
    var url: URL
    var data: Data
    var transcript: PerformanceTranscript
}

private func transcriptionAudioFixture() throws -> TranscriptionAudioFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-Transcription-Workflow-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("humming.wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 19_200))
    buffer.frameLength = 19_200
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<19_200 {
        let time = Double(index) / 16_000
        let offset = time - 0.2
        let envelope = min(1, max(0, min(offset / 0.005, (0.5 - offset) / 0.005)))
        samples[index] = Float(0.3 * sin(2 * .pi * 440 * offset) * envelope)
    }
    do {
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
    }
    return TranscriptionAudioFixture(directory: directory, url: url, data: try Data(contentsOf: url),
        transcript: PerformanceTranscript(mode: .humming, events: [
            .init(pitch: 69, startSeconds: 0.2, durationSeconds: 0.5, velocity: 0.8, confidence: 0.95)
        ], duration: 1.2))
}

private func transcriptionExistingProject() -> ProjectFile {
    var project = ProjectFile(); project.song.tempo = 120
    project.song.tracks = [Track(name: "Existing music", instrumentID: "synth.pad", volume: 0.3,
        clips: [Clip(name: "Keep this", startBeat: 4, lengthBeats: 4,
                     notes: [NoteEvent(pitch: 60, startBeat: 0.25, duration: 0.75, velocity: 72)])])]
    project.conversations[0].messages = [.init(role: "user", text: "Keep the existing melody.")]
    return project
}

@MainActor
private func waitForTranscription(_ predicate: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now + .seconds(5)
    while !(await predicate()) {
        guard clock.now < deadline else { throw TranscriptionWorkflowFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func transcriptionStore(_ project: ProjectSession, arranger: any TranscriptionArranging = NoTranscriptionAI(), mode: WorkspaceMode = .producer,
    analyze: @escaping @Sendable (URL, TranscriptionMode) async throws -> PerformanceTranscript = { try await PerformanceTranscriber.transcribe(url: $0, mode: $1) }) -> TranscriptionSession {
    project.setMode(mode, remember: false)
    let store = TranscriptionSession(project: project, arranger: arranger, analyze: analyze)
    project.transcription = store; store.configureMode(.humming)
    return store
}

@MainActor
private func seedTranscription(_ store: TranscriptionSession, fixture: TranscriptionAudioFixture, startBeat: Double = 8, tempo: Double = 120) {
    store.take = .init(url: fixture.url, startBeat: startBeat, tempo: tempo, duration: 1.2, sampleRate: 16_000, channels: 1)
    store.transcript = fixture.transcript; store.options.targetLengthBeats = 4; store.phase = .review
}

@MainActor
private func closeTranscriptionTest(_ project: ProjectSession, _ store: TranscriptionSession) {
    store.cancelWork()
    // Test fixtures must not create personal recovery files during teardown.
    store.take = nil
    project.close()
}

private func faithfulTimingResult(_ request: TranscriptionArrangementRequest) throws -> TranscriptionArrangementResult {
    let notes = try request.transcript.notes(tempo: request.song.tempo)
    let changes = request.options.timing == .preserve ? [] : notes.map {
        TranscriptionTimingChange(sourceEventID: $0.id, startBeat: $0.startBeat, duration: $0.duration)
    }
    return .init(plan: .init(timingChanges: changes, summary: "Matched the measured performance timing."),
                 model: "fixture-model", inputTokens: 8, outputTokens: 5)
}

@Suite(.serialized)
@MainActor
struct TranscriptionWorkflowTests {
    @Test func realImportedTakeInsertsOfflineAsOneUndoAndSurvivesPackageReopen() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = transcriptionExistingProject()
        let project = ProjectSession(file: original, keyProvider: { throw TranscriptionWorkflowFailure.unexpectedKey })
        let store = transcriptionStore(project, mode: .superhuman), undo = UndoManager()
        undo.groupsByEvent = false; project.undoManager = undo
        defer { closeTranscriptionTest(project, store) }
        project.audio.seek(to: 7.25)
        store.importTake(url: fixture.url)
        try await waitForTranscription { store.phase == .review && store.operation == nil }
        #expect(project.file == original && project.assetData.isEmpty)
        let transcript = try #require(store.transcript)
        #expect(transcript.events.map(\.pitch) == [69])
        #expect(store.take?.startBeat == 7.25)
        #expect(store.take?.url != fixture.url)
        store.setPerformanceLayerCount(2)
        store.options.layers[1].instrumentID = "synth.pluck"
        undo.beginUndoGrouping(); store.insert()
        try await waitForTranscription { store.operation == nil }
        undo.endUndoGrouping()
        #expect(store.error == nil && store.inserted)
        #expect(project.file.song.tracks.count == 3)
        #expect(project.file.song.tracks[0] == original.song.tracks[0])
        #expect(project.file.conversations == original.conversations && project.file.generations.isEmpty)
        let source = try #require(project.file.song.assets.first)
        #expect(source.transcriptionTake?.transcript == transcript)
        #expect(source.transcriptionTake?.recordedStartBeat == 7.25)
        #expect(source.transcriptionTake?.recordedTempo == 120)
        #expect(project.assetData[source.id] == fixture.data)
        let expected = try transcript.notes(tempo: 120)
        let added = Array(project.file.song.tracks.dropFirst())
        #expect(added.allSatisfy { $0.clips[0].startBeat == 7.25 && $0.clips[0].transcriptionAssetID == source.id })
        #expect(added.allSatisfy { $0.clips[0].notes.map(\.pitch) == expected.map(\.pitch) })
        #expect(added.allSatisfy { $0.clips[0].notes.map(\.startBeat) == expected.map(\.startBeat) })
        #expect(added.allSatisfy { $0.clips[0].notes.map(\.duration) == expected.map(\.duration) })
        #expect(Set(added.flatMap(\.clips).flatMap(\.notes).map(\.id)).count == expected.count * 2)
        let snapshot = try project.document.snapshot(contentType: .unabletonProject)
        let package = try ProjectArchive.encode(project: snapshot.project, assets: snapshot.assets)
        let packageURL = fixture.directory.appendingPathComponent("Transcribed.unableton")
        try package.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        let decoded = try ProjectArchive.decode(FileWrapper(url: packageURL, options: .immediate))
        let reopened = ProjectSession(file: decoded.project, assets: decoded.assets, keyProvider: { nil })
        defer { reopened.close() }
        #expect(reopened.file.song == project.file.song)
        #expect(reopened.assetData[source.id] == fixture.data)
        #expect(reopened.file.song.assets[0].transcriptionTake == source.transcriptionTake)
        #expect(FileManager.default.fileExists(atPath: try #require(reopened.assetURLs[source.id]).path))
        undo.undo()
        #expect(project.file.song.tracks == original.song.tracks && project.file.song.assets.isEmpty)
        #expect(project.assetData[source.id] == fixture.data)
        #expect(!undo.canUndo && undo.canRedo)
        undo.redo()
        #expect(project.file.song.tracks.dropFirst().map(\.id) == added.map(\.id))
        #expect(project.file.song.assets == [source])
    }

    @Test func correctedEventsAndChosenPositionKeepSourceCaptureMetadata() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = transcriptionExistingProject()
        let project = ProjectSession(file: original, keyProvider: { nil })
        let store = transcriptionStore(project); defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture, startBeat: 12.5, tempo: 100)
        let event = fixture.transcript.events[0]
        store.updateEvent(event.id, pitch: 72, start: 0.137, duration: 0.233)
        let corrected = try #require(store.transcript)
        store.updateEvent(event.id, start: -1)
        #expect(store.transcript == corrected)
        store.insertAtRecordedPosition = false; store.options.insertionBeat = 21.125
        let keptTrack = project.file.song.tracks[0]
        store.insert(); try await waitForTranscription { store.operation == nil }
        #expect(store.error == nil && store.inserted)
        #expect(project.file.song.tracks[0] == keptTrack)
        let clip = try #require(project.file.song.tracks.last?.clips.first)
        let note = try #require(clip.notes.first)
        #expect(clip.startBeat == 21.125 && note.pitch == 72)
        #expect(abs(note.startBeat - 0.274) < 1e-12 && abs(note.duration - 0.466) < 1e-12)
        #expect(project.file.song.assets[0].transcriptionTake?.recordedStartBeat == 12.5)
        #expect(project.file.song.assets[0].transcriptionTake?.recordedTempo == 100)
        #expect(project.file.song.assets[0].transcriptionTake?.transcript == corrected)
        #expect(project.file.conversations.map(\.messages) == original.conversations.map(\.messages))
    }

    @Test func failedReplacementAnalysisCannotPairOldNotesWithNewAudio() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = transcriptionExistingProject()
        let project = ProjectSession(file: original, keyProvider: { nil })
        let store = transcriptionStore(project, analyze: { _, _ in throw TranscriptionWorkflowFailure.analysis })
        defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture)
        store.recoverySaved = true
        let oldTake = store.take?.url
        store.importTake(url: fixture.url)
        try await waitForTranscription { store.operation == nil && store.error != nil }
        #expect(store.take?.url != oldTake)
        #expect(store.transcript == nil && store.prepared == nil)
        #expect(store.error?.contains("analysis failed") == true)
        let before = project.file
        store.insert()
        #expect(project.file == before && project.assetData.isEmpty)
        #expect(project.file.song.tracks.count == original.song.tracks.count)
    }

    @Test func cancelingAnalysisKeepsSongAndUninsertedSource() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = transcriptionExistingProject()
        let project = ProjectSession(file: original, keyProvider: { nil })
        let gate = TranscriptionWorkflowGate<TranscriptionMode, PerformanceTranscript>()
        let store = transcriptionStore(project, analyze: { _, mode in try await gate.call(mode) })
        defer { closeTranscriptionTest(project, store) }
        let before = project.file
        store.importTake(url: fixture.url)
        try await waitForTranscription { await gate.calls().count == 1 }
        store.cancelWork()
        try await waitForTranscription { await gate.pendingCount() == 0 }
        #expect(project.file == before && project.assetData.isEmpty && store.transcript == nil)
        let retainedTake = try #require(store.take?.url)
        #expect(FileManager.default.fileExists(atPath: retainedTake.path))
        #expect(project.file.song.tracks.count == original.song.tracks.count)
    }

    @Test func missingTakePayloadDoesNotInstallPartialTracksOrAssets() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(file: transcriptionExistingProject(), keyProvider: { nil })
        let store = transcriptionStore(project); defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture)
        try FileManager.default.removeItem(at: fixture.url)
        let before = project.file
        store.insert(); try await waitForTranscription { store.operation == nil }
        #expect(store.error != nil && !store.inserted)
        #expect(project.file == before && project.assetData.isEmpty && project.assetURLs.isEmpty)
    }

    @Test func providerFailureLeavesSongAndAssetsUnchanged() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(file: transcriptionExistingProject(), keyProvider: { "fixture-key" })
        let gate = TranscriptionWorkflowGate<TranscriptionArrangementRequest, TranscriptionArrangementResult>()
        let store = transcriptionStore(project, arranger: ControlledTranscriptionArranger(gate: gate))
        defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture); store.options.timing = .autoTime
        let before = project.file
        store.preview(); try await waitForTranscription { await gate.calls().count == 1 }
        try await gate.fail(0, .provider)
        try await waitForTranscription { store.operation == nil }
        #expect(store.error?.contains("provider failed") == true && store.prepared == nil)
        #expect(project.file == before && project.assetData.isEmpty && project.assetURLs.isEmpty)
    }

    @Test func canceledArrangementLeavesSongAndAssetsUnchanged() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(file: transcriptionExistingProject(), keyProvider: { "fixture-key" })
        let gate = TranscriptionWorkflowGate<TranscriptionArrangementRequest, TranscriptionArrangementResult>()
        let store = transcriptionStore(project, arranger: ControlledTranscriptionArranger(gate: gate))
        defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture); store.options.timing = .autoTime
        let before = project.file
        store.preview(); try await waitForTranscription { await gate.calls().count == 1 }
        store.cancelWork(); try await waitForTranscription { await gate.pendingCount() == 0 }
        #expect(project.file == before && project.assetData.isEmpty && project.assetURLs.isEmpty)
        #expect(store.phase == .review && store.prepared == nil && store.take != nil)
    }

    @Test func revisionConflictReplansOnceThenRejectsASecondChange() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(file: transcriptionExistingProject(), keyProvider: { "fixture-key" })
        let gate = TranscriptionWorkflowGate<TranscriptionArrangementRequest, TranscriptionArrangementResult>()
        let store = transcriptionStore(project, arranger: ControlledTranscriptionArranger(gate: gate))
        defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture); store.options.timing = .autoTime
        let keptTracks = project.file.song.tracks
        store.preview(); try await waitForTranscription { await gate.calls().count == 1 }
        project.setTempo(135)
        try await gate.succeed(0, faithfulTimingResult(try #require(await gate.calls().first)))
        try await waitForTranscription { await gate.calls().count == 2 }
        let calls = await gate.calls()
        #expect(calls[1].song.tempo == 135 && calls[1].song.revision == project.file.song.revision)
        project.setTempo(145)
        try await gate.succeed(1, faithfulTimingResult(calls[1]))
        try await waitForTranscription { store.operation == nil }
        #expect(store.error?.contains("changed again") == true)
        #expect(project.file.song.tempo == 145 && project.file.song.tracks == keptTracks)
        #expect(project.file.song.assets.isEmpty && project.assetData.isEmpty && project.file.generations.isEmpty)
        #expect(await gate.calls().count == 2)
    }

    @Test func preparedAIInsertionGroupsUndoAndPreservesConversationHistory() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = transcriptionExistingProject()
        let project = ProjectSession(file: original, keyProvider: { nil })
        let store = transcriptionStore(project), undo = UndoManager()
        undo.groupsByEvent = false; project.undoManager = undo
        defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture); store.options.timing = .autoTime
        let result = try faithfulTimingResult(.init(transcript: fixture.transcript, options: store.effectiveOptions, song: project.file.song))
        store.prepared = try store.makePrepared(plan: result.plan, snapshot: project.file.song, transcript: fixture.transcript, options: store.effectiveOptions, result: result)
        undo.beginUndoGrouping(); store.insert()
        try await waitForTranscription { store.operation == nil }; undo.endUndoGrouping()
        #expect(store.error == nil && store.inserted)
        #expect(project.file.song.tracks[0] == original.song.tracks[0])
        #expect(project.file.conversations.count == 2 && project.file.generations.count == 1)
        let messages = project.file.conversations.last?.messages
        #expect(messages?.count == 2)
        #expect(project.file.generations[0].model == "fixture-model")
        undo.undo()
        #expect(project.file.song.tracks.count == 1 && project.file.song.assets.isEmpty)
        #expect(project.file.generations[0].isUndone)
        #expect(project.file.conversations.last?.messages == messages)
        #expect(!undo.canUndo && undo.canRedo)
        undo.redo()
        #expect(project.file.song.tracks.count == 2 && !project.file.generations[0].isUndone)
    }

    @Test func stalePreparedAIInsertionCannotOverwriteManualChanges() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(file: transcriptionExistingProject(), keyProvider: { nil })
        let store = transcriptionStore(project); defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture); store.options.timing = .autoTime
        let result = try faithfulTimingResult(.init(transcript: fixture.transcript, options: store.effectiveOptions, song: project.file.song))
        store.prepared = try store.makePrepared(plan: result.plan, snapshot: project.file.song, transcript: fixture.transcript, options: store.effectiveOptions, result: result)
        project.setTempo(150)
        let before = project.file
        store.insert()
        #expect(store.error?.contains("before inserting") == true)
        #expect(project.file == before && project.assetData.isEmpty && project.assetURLs.isEmpty)
    }

    @Test func repeatedInsertionIsBlockedUntilPlacementChangesAndReusesSource() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(keyProvider: { throw TranscriptionWorkflowFailure.unexpectedKey })
        let store = transcriptionStore(project), undo = UndoManager()
        undo.groupsByEvent = false; project.undoManager = undo
        defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture)
        store.updateEvent(fixture.transcript.events[0].id, pitch: 72)
        store.setPerformanceLayerCount(2)
        undo.beginUndoGrouping(); store.insert()
        try await waitForTranscription { store.operation == nil }; undo.endUndoGrouping()
        #expect(store.error == nil && store.alreadyInserted)
        #expect(project.file.song.tracks.count == 2 && project.file.song.assets.count == 1)
        let firstFile = project.file
        let firstSource = try #require(project.file.song.assets.first)
        let firstData = project.assetData
        #expect(firstSource.transcriptionTake?.transcript.events.first?.pitch == 72)
        store.insert()
        #expect(store.operation == nil && store.alreadyInserted)
        #expect(project.file == firstFile && project.file.song.tracks.count == 2)
        #expect(project.assetData == firstData)

        store.insertAtRecordedPosition = false; store.options.insertionBeat = 16
        #expect(!store.alreadyInserted)
        undo.beginUndoGrouping(); store.insert()
        try await waitForTranscription { store.operation == nil }; undo.endUndoGrouping()
        #expect(store.error == nil && store.alreadyInserted)
        #expect(project.file.song.tracks.count == 4)
        #expect(project.file.song.tracks.prefix(2).map(\.id) == firstFile.song.tracks.map(\.id))
        #expect(project.file.song.tracks.suffix(2).allSatisfy { $0.clips[0].startBeat == 16 })
        #expect(project.file.song.assets == [firstSource] && project.assetData == firstData)
        #expect(project.file.song.tracks.allSatisfy { $0.clips[0].transcriptionAssetID == firstSource.id })
        #expect(project.assetData[firstSource.id] == fixture.data)

        undo.undo()
        #expect(project.file.song.tracks.count == 2 && project.file.song.assets == [firstSource])
        #expect(!store.alreadyInserted)
        undo.undo()
        #expect(project.file.song.tracks.isEmpty && project.file.song.assets.isEmpty)
        #expect(!undo.canUndo && project.assetData[firstSource.id] == fixture.data)
    }

    @Test func closingAfterUndoRecoversTakeMissingFromSavedSong() async throws {
        let fixture = try transcriptionAudioFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = ProjectSession(keyProvider: { nil })
        let store = transcriptionStore(project), undo = UndoManager()
        undo.groupsByEvent = false; project.undoManager = undo
        store.recoveryURL = fixture.directory.appendingPathComponent("RecoveredTakes", isDirectory: true)
        defer { closeTranscriptionTest(project, store) }
        seedTranscription(store, fixture: fixture)
        let source = project.cacheURL.appendingPathComponent("take.wav")
        try FileManager.default.copyItem(at: fixture.url, to: source)
        store.take?.url = source
        undo.beginUndoGrouping(); store.insert()
        try await waitForTranscription { store.operation == nil }; undo.endUndoGrouping()
        #expect(store.takeIsInProject)
        undo.undo()
        #expect(!store.takeIsInProject && project.file.song.assets.isEmpty)
        let snapshot = try project.document.snapshot(contentType: .unabletonProject)
        #expect(snapshot.project.song.assets.isEmpty)

        project.close()
        #expect(store.recoverySaved)
        #expect(!FileManager.default.fileExists(atPath: project.cacheURL.path))
        let recovered = try FileManager.default.contentsOfDirectory(at: store.recoveryURL, includingPropertiesForKeys: nil)
        let audio = try #require(recovered.first { $0.pathExtension == "wav" })
        #expect(try Data(contentsOf: audio) == fixture.data)
        let metadata = try Data(contentsOf: audio.appendingPathExtension("json"))
        let object = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        #expect(object["transcript"] != nil)
    }
}
