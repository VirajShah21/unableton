import Foundation
import AVFAudio
import Testing
import UnabletonCore
@testable import UnabletonAI
@testable import Unableton

private enum FixtureError: Error { case timeout, missingCall }

private actor ControlledAgent: MusicGenerating {
    struct Invocation: Sendable {
        var song: Song
        var conversation: Conversation
        var selection: ProjectSelection
        var budget: GenerationBudget?
    }
    private var invocations: [Invocation] = []
    private var pending: [Int: CheckedContinuation<AgentResult, any Error>] = [:]
    func generate(song: Song, conversation: Conversation, selection: ProjectSelection, configuration: AgentConfiguration,
                  vocals: VocalSession?,
                  preview: @escaping @Sendable (Song, Double, Double) async throws -> PreviewReport,
                  status: @escaping @Sendable (String) -> Void) async throws -> AgentResult {
        let index = invocations.count
        invocations.append(Invocation(song: song, conversation: conversation, selection: selection, budget: configuration.runBudget))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { pending[index] = continuation }
            }
        } onCancel: { Task { await self.cancel(index) } }
    }
    func calls() -> [Invocation] { invocations }
    func complete(_ index: Int, commands: [ProjectCommand] = [], summary: String = "Updated the song.", generatedAssets: [UUID: Data] = [:], generatedFiles: [UUID: URL] = [:], responseItems: [JSONValue]? = nil) throws {
        guard let continuation = pending.removeValue(forKey: index), invocations.indices.contains(index) else { throw FixtureError.missingCall }
        var draft = invocations[index].song
        do {
            try ProjectEditor.apply(commands, to: &draft)
            let items = responseItems ?? (invocations[index].conversation.responseItems + [.object(["fixture_call": .number(Double(index))])])
            continuation.resume(returning: AgentResult(song: draft, summary: summary, model: "test-model", inputTokens: 10, outputTokens: 5, responseItems: items, runID: UUID(), generatedAssets: generatedAssets, generatedFiles: generatedFiles))
        } catch { continuation.resume(throwing: error) }
    }
    private func cancel(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CancellationError()) }
}

@MainActor
private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard clock.now < deadline else { throw FixtureError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func makeSession(agent: ControlledAgent, file: ProjectFile = ProjectFile(), assets: [UUID: Data] = [:], mode: WorkspaceMode = .producer) -> ProjectSession {
    ProjectSession(file: file, assets: assets, agent: agent, keyProvider: { "fixture-key" }, mode: mode)
}

private struct VocalFixture {
    var asset: AudioAsset
    var data: Data
    var track: Track
    var clip: Clip
    var commands: [ProjectCommand] {
        [.init(op: .addTrack, track: track), .init(op: .addClip, trackID: track.id, clip: clip, asset: asset)]
    }
}

private func vocalFixture(sourceClip: Clip) throws -> VocalFixture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-Test-Vocal-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
    buffer.frameLength = 8000
    let channel = try #require(buffer.floatChannelData?[0])
    for frame in 0..<8000 { channel[frame] = Float(sin(Double(frame) * 2 * .pi * 220 / 16000) * 0.1) }
    do {
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
    }
    let score = try VocalScore.make(clip: sourceClip, tempo: 120, beatsPerBar: 4, lyrics: sourceClip.notes.map { _ in "Hey" })
    let asset = AudioAsset(fileName: "Generated Vocals.wav", duration: 0.5, sampleRate: 16000, channels: 1,
                           vocalTake: VocalTake(provider: "fixture", singerID: "test-singer", sourceClipID: sourceClip.id, score: score))
    let track = Track(name: "Vocals", kind: .audio)
    let clip = Clip(name: "Sung phrase", kind: .audio, startBeat: sourceClip.startBeat, lengthBeats: 1, assetID: asset.id)
    return VocalFixture(asset: asset, data: try Data(contentsOf: url), track: track, clip: clip)
}

private func melodyProject() -> ProjectFile {
    var file = ProjectFile(); file.song.tempo = 120
    file.song.tracks = [Track(name: "Melody", clips: [Clip(name: "Vocal melody", lengthBeats: 1, notes: [NoteEvent()])])]
    return file
}

@MainActor
struct ProjectGenerationTests {
    @Test func referenceFilesCommitAsOneUndoAndRemainPackagedAfterSourceDeletion() async throws {
        var original = melodyProject(), fixture = try vocalFixture(sourceClip: original.song.tracks[0].clips[0])
        let source = SongAttachment(fileName: "Source.wav", duration: 0.5, sampleRate: 16_000, channels: 1,
            byteCount: fixture.data.count, sha256: SongAttachmentLimits.sha256(fixture.data))
        original.attachments = [source]
        fixture.asset.vocalTake = nil
        fixture.asset.referenceDerivation = ReferenceAudioDerivation(attachmentID: source.id, stem: "vocals", sourceStartSeconds: 0, sourceEndSeconds: 0.5)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Reference-Generation-\(UUID()).wav")
        try fixture.data.write(to: fileURL); defer { try? FileManager.default.removeItem(at: fileURL) }
        let agent = ControlledAgent(), session = makeSession(agent: agent, file: original, assets: [source.id: fixture.data])
        defer { session.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        session.setPendingAttachments([source.id], conversationID: try #require(session.selectedConversationID))
        undo.beginUndoGrouping()
        session.composer = "Use the original vocals."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        try await agent.complete(0, commands: fixture.commands, generatedFiles: [fixture.asset.id: fileURL])
        try await waitUntil { session.generationTask == nil }
        undo.endUndoGrouping()
        try FileManager.default.removeItem(at: fileURL)
        #expect(session.file.song.assets == [fixture.asset])
        #expect(session.file.generations.count == 1 && session.file.generations[0].appliedRevision == session.file.song.revision)
        let saved = try session.document.snapshot(contentType: .unabletonProject)
        let reopened = try ProjectArchive.decode(ProjectArchive.encode(project: saved.project, blobURLs: saved.blobs?.urls ?? [:], lease: saved.blobs?.lease))
        #expect(reopened.assets[fixture.asset.id] == fixture.data && reopened.assets[source.id] == fixture.data)
        #expect(reopened.project.song.assets.first?.referenceDerivation == fixture.asset.referenceDerivation)
        undo.undo()
        #expect(session.file.song == original.song || session.file.song.tracks == original.song.tracks)
        #expect(!undo.canUndo && undo.canRedo)
        #expect(session.assetData[fixture.asset.id] == fixture.data)
        undo.redo()
        #expect(session.file.song.assets == [fixture.asset])
        let names = try FileManager.default.contentsOfDirectory(atPath: session.cacheURL.path)
        #expect(!names.contains(where: { $0.hasPrefix("Generated-") || $0.hasPrefix("ReferenceDraft-") }))
    }

    @Test func oversizedCompletedMetadataRejectsAndRollsBackFileAssets() async throws {
        let original = melodyProject(), fixture = try vocalFixture(sourceClip: original.song.tracks[0].clips[0])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rejected-Reference-\(UUID()).wav")
        try fixture.data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let agent = ControlledAgent(), session = makeSession(agent: agent, file: original)
        defer { session.close() }
        session.composer = "Add audio."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        try await agent.complete(0, commands: fixture.commands, generatedFiles: [fixture.asset.id: url],
            responseItems: [.string(String(repeating: "x", count: SongAttachmentLimits.maximumMetadataBytes))])
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.song == original.song && session.file.generations.isEmpty)
        #expect(session.file.conversations[0].responseItems.isEmpty)
        #expect(session.document.blobStore?.snapshot().urls[fixture.asset.id] == nil)
        #expect(session.errorMessage?.contains("metadata") == true)
        let saved = try session.document.snapshot(contentType: .unabletonProject)
        _ = try ProjectArchive.encode(project: saved.project, blobURLs: saved.blobs?.urls ?? [:], lease: saved.blobs?.lease)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.cacheURL.path).isEmpty)
    }

    @Test func vocalAssetsCommitAsOneUndoAndSurviveSaveReopen() async throws {
        let original = melodyProject(), agent = ControlledAgent(), undo = UndoManager()
        let fixture = try vocalFixture(sourceClip: original.song.tracks[0].clips[0])
        let session = makeSession(agent: agent, file: original)
        undo.groupsByEvent = false; session.undoManager = undo
        defer { session.close() }
        undo.beginUndoGrouping()
        session.composer = "Sing this melody."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        #expect(session.assetData.isEmpty)
        #expect(session.file.song == original.song)
        try await agent.complete(0, commands: fixture.commands, summary: "Added vocals.", generatedAssets: [fixture.asset.id: fixture.data])
        try await waitUntil { session.generationTask == nil }
        undo.endUndoGrouping()
        #expect(session.file.song.tracks[0] == original.song.tracks[0])
        #expect(session.file.song.tracks.last?.clips == [fixture.clip])
        #expect(session.file.song.assets == [fixture.asset])
        #expect(session.assetData[fixture.asset.id] == fixture.data)
        let cached = try #require(session.assetURLs[fixture.asset.id])
        #expect(try Data(contentsOf: cached) == fixture.data)
        #expect((session.waveforms[fixture.asset.id]?.max() ?? 0) > 0.05)
        let messages = session.file.conversations[0].messages
        let responseItems = session.file.conversations[0].responseItems
        let snapshot = try session.document.snapshot(contentType: .unabletonProject)
        let archive = try ProjectArchive.encode(project: snapshot.project, assets: snapshot.assets)
        let packageURL = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-Vocal-Reopen-\(UUID()).unableton")
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try archive.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        let decoded = try ProjectArchive.decode(FileWrapper(url: packageURL, options: .immediate))
        let reopened = makeSession(agent: agent, file: decoded.project, assets: decoded.assets)
        defer { reopened.close() }
        #expect(reopened.file.song == session.file.song)
        #expect(reopened.file.song.assets[0].vocalTake == fixture.asset.vocalTake)
        #expect(reopened.assetData[fixture.asset.id] == fixture.data)
        #expect((reopened.waveforms[fixture.asset.id]?.max() ?? 0) > 0.05)
        undo.undo()
        #expect(session.file.song.tracks == original.song.tracks)
        #expect(session.file.song.assets.isEmpty)
        #expect(session.file.generations[0].isUndone)
        #expect(session.file.conversations[0].messages == messages)
        #expect(session.file.conversations[0].responseItems == responseItems)
        #expect(session.assetData[fixture.asset.id] == fixture.data)
        #expect(FileManager.default.fileExists(atPath: cached.path))
        #expect(!undo.canUndo)
        #expect(undo.canRedo)
        undo.redo()
        #expect(session.file.song.tracks.last?.clips == [fixture.clip])
        #expect(session.file.song.assets == [fixture.asset])
        #expect(session.assetData[fixture.asset.id] == fixture.data)
        #expect(!session.file.generations[0].isUndone)
    }

    @Test func rejectedVocalDraftsNeverLeakAssetsAcrossRevisionReplans() async throws {
        let original = melodyProject(), agent = ControlledAgent()
        let first = try vocalFixture(sourceClip: original.song.tracks[0].clips[0])
        let second = try vocalFixture(sourceClip: original.song.tracks[0].clips[0])
        let session = makeSession(agent: agent, file: original)
        defer { session.close() }
        session.composer = "Add a sung melody."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        session.setTempo(150)
        try await agent.complete(0, commands: first.commands, generatedAssets: [first.asset.id: first.data])
        try await waitUntil { await agent.calls().count == 2 }
        #expect(session.assetData.isEmpty)
        #expect(session.assetURLs.isEmpty)
        #expect(session.waveforms.isEmpty)
        #expect(session.file.song.assets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: session.cacheURL.appendingPathComponent("\(first.asset.id)-Generated.wav").path))
        session.setTempo(160)
        try await agent.complete(1, commands: second.commands, generatedAssets: [second.asset.id: second.data])
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.song.tempo == 160)
        #expect(session.file.song.tracks == original.song.tracks)
        #expect(session.file.song.assets.isEmpty)
        #expect(session.assetData.isEmpty)
        #expect(session.assetURLs.isEmpty)
        #expect(session.waveforms.isEmpty)
        #expect(session.file.generations.isEmpty)
        #expect(session.file.conversations[0].responseItems.isEmpty)
        #expect(session.errorMessage?.contains("changed again") == true)
        #expect(!FileManager.default.fileExists(atPath: session.cacheURL.appendingPathComponent("\(second.asset.id)-Generated.wav").path))
    }

    @Test func missingVocalPayloadCleansStagedFilesAndPreservesExistingAssets() async throws {
        var original = melodyProject()
        let source = original.song.tracks[0].clips[0], agent = ControlledAgent()
        let existing = try vocalFixture(sourceClip: source), staged = try vocalFixture(sourceClip: source), missing = try vocalFixture(sourceClip: source)
        try ProjectEditor.apply(existing.commands, to: &original.song)
        let session = makeSession(agent: agent, file: original, assets: [existing.asset.id: existing.data])
        defer { session.close() }
        let originalURLs = session.assetURLs, originalWaveforms = session.waveforms
        session.composer = "Add two vocal phrases."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        try await agent.complete(0, commands: staged.commands + missing.commands, generatedAssets: [staged.asset.id: staged.data])
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.song == original.song)
        #expect(session.assetData == [existing.asset.id: existing.data])
        #expect(session.assetURLs == originalURLs)
        #expect(session.waveforms == originalWaveforms)
        #expect(session.file.generations.isEmpty)
        #expect(session.file.conversations[0].responseItems.isEmpty)
        #expect(session.errorMessage?.contains("audio data is missing") == true)
        #expect(!FileManager.default.fileExists(atPath: session.cacheURL.appendingPathComponent("\(staged.asset.id)-Generated.wav").path))
        #expect(!FileManager.default.fileExists(atPath: session.cacheURL.appendingPathComponent("\(missing.asset.id)-Generated.wav").path))
        let snapshot = try session.document.snapshot(contentType: .unabletonProject)
        let decoded = try ProjectArchive.decode(ProjectArchive.encode(project: snapshot.project, assets: snapshot.assets))
        #expect(decoded.project.song == original.song)
        #expect(decoded.assets == [existing.asset.id: existing.data])
    }

    @Test func requestsRunFIFOAcrossChatsAndUseLatestSong() async throws {
        let agent = ControlledAgent(), session = makeSession(agent: agent)
        defer { session.close() }
        let firstID = try #require(session.selectedConversationID)
        session.composer = "Make the first part."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        session.newConversation()
        let secondID = try #require(session.selectedConversationID)
        session.composer = "Refine this song in another chat."; session.submitPrompt()
        #expect(session.queuedCount == 1)
        #expect(await agent.calls().count == 1)
        try await agent.complete(0, commands: [.init(op: .setTempo, value: 150)])
        try await waitUntil { await agent.calls().count == 2 }
        let calls = await agent.calls()
        #expect(calls[0].conversation.id == firstID)
        #expect(calls[1].conversation.id == secondID)
        #expect(calls[1].song.tempo == 150)
        #expect(calls[1].song.revision == 1)
        #expect(calls[1].conversation.responseItems.isEmpty)
        #expect(calls[0].budget != nil)
        #expect(calls[0].budget !== calls[1].budget)
        try await agent.complete(1, commands: [.init(op: .setKey, text: "D minor")])
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.song.tempo == 150)
        #expect(session.file.song.key == "D minor")
        #expect(session.file.generations.count == 2)
        #expect(session.file.conversations.allSatisfy { $0.messages.count == 2 })
    }

    @Test func queuedFollowupDoesNotLeakIntoEarlierPrompt() async throws {
        let agent = ControlledAgent(), session = makeSession(agent: agent)
        defer { session.close() }
        session.composer = "First request"; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        session.composer = "Followup request"; session.submitPrompt()
        try await agent.complete(0, commands: [.init(op: .setTempo, value: 145)])
        try await waitUntil { await agent.calls().count == 2 }
        let calls = await agent.calls()
        #expect(calls[0].conversation.messages.map(\.text) == ["First request"])
        #expect(calls[1].conversation.messages.filter { $0.role == "user" }.map(\.text) == ["First request", "Followup request"])
        #expect(calls[1].conversation.responseItems == [.object(["fixture_call": .number(0)])])
        try await agent.complete(1)
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.conversations[0].responseItems.count == 2)
    }

    @Test func aLiveEditTriggersOneReplanAgainstCurrentRevision() async throws {
        let agent = ControlledAgent(), session = makeSession(agent: agent)
        defer { session.close() }
        session.composer = "Change the harmony."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        session.setTempo(150)
        try await agent.complete(0, commands: [.init(op: .setTempo, value: 180)])
        try await waitUntil { await agent.calls().count == 2 }
        let calls = await agent.calls()
        #expect(calls[1].song.tempo == 150)
        #expect(calls[1].song.revision == session.file.song.revision)
        #expect(calls[0].budget != nil)
        #expect(calls[0].budget === calls[1].budget)
        try await agent.complete(1, commands: [.init(op: .setKey, text: "D minor")])
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.song.tempo == 150)
        #expect(session.file.song.key == "D minor")
        #expect(session.file.generations.count == 1)
        #expect(session.file.generations[0].baseRevision == 1)
    }

    @Test func aSecondConflictStopsWithoutOverwritingEitherLiveEdit() async throws {
        let agent = ControlledAgent(), session = makeSession(agent: agent)
        defer { session.close() }
        session.composer = "Change the harmony."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        session.setTempo(150)
        try await agent.complete(0, commands: [.init(op: .setTempo, value: 180)])
        try await waitUntil { await agent.calls().count == 2 }
        session.setTempo(160)
        try await agent.complete(1, commands: [.init(op: .setTempo, value: 190), .init(op: .setKey, text: "D minor")])
        try await waitUntil { session.generationTask == nil }
        #expect(await agent.calls().count == 2)
        #expect(session.file.song.tempo == 160)
        #expect(session.file.song.key == "C major")
        #expect(session.file.generations.isEmpty)
        #expect(session.file.conversations[0].responseItems.isEmpty)
        #expect(session.errorMessage?.contains("changed again") == true)
    }

    @Test func cancellationDropsDraftAndQueuedWork() async throws {
        let agent = ControlledAgent(), session = makeSession(agent: agent)
        defer { session.close() }
        let original = session.file.song
        session.composer = "Make music."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        session.composer = "Another pending request."; session.submitPrompt()
        session.cancelGeneration()
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.song == original)
        #expect(session.file.generations.isEmpty)
        #expect(session.queuedCount == 0)
        #expect(await agent.calls().count == 1)
        #expect(session.file.conversations[0].messages.last?.text.contains("canceled") == true)
    }

    @Test func anAnswerWithoutEditsDoesNotRegisterUndoOrChangeRevision() async throws {
        let agent = ControlledAgent(), session = makeSession(agent: agent), undo = UndoManager()
        session.undoManager = undo
        defer { session.close() }
        let original = session.file.song
        session.composer = "What key is this?"; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        try await agent.complete(0, summary: "C major.")
        try await waitUntil { session.generationTask == nil }
        #expect(session.file.song == original)
        #expect(!undo.canUndo)
        #expect(session.file.generations.count == 1)
        #expect(session.file.generations[0].appliedRevision == nil)
        #expect(session.file.conversations[0].messages.last?.text == "C major.")
    }

    @Test func aWholeAIEditIsOneUndoAndRetainsConversationHistory() async throws {
        let agent = ControlledAgent(), session = makeSession(agent: agent, mode: .superhuman), undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        defer { session.close() }
        undo.beginUndoGrouping()
        session.composer = "Change tempo and key."; session.submitPrompt()
        try await waitUntil { await agent.calls().count == 1 }
        let pendingSong = session.file.song
        session.setMode(.producer, remember: false)
        session.setMode(.superhuman, remember: false)
        #expect(session.isGenerating && session.file.song == pendingSong)
        #expect(await agent.calls().count == 1)
        try await agent.complete(0, commands: [.init(op: .setTempo, value: 155), .init(op: .setKey, text: "G minor")])
        try await waitUntil { session.generationTask == nil }
        undo.endUndoGrouping()
        #expect(session.file.song.tempo == 155)
        #expect(session.file.song.key == "G minor")
        #expect(undo.canUndo)
        let messages = session.file.conversations[0].messages
        let responseItems = session.file.conversations[0].responseItems
        undo.undo()
        #expect(session.file.song.tempo == 140)
        #expect(session.file.song.key == "C major")
        #expect(session.file.generations[0].isUndone)
        #expect(session.file.conversations[0].messages == messages)
        #expect(session.file.conversations[0].responseItems == responseItems)
        #expect(!undo.canUndo)
        #expect(undo.canRedo)
        let snapshot = try session.document.snapshot(contentType: .unabletonProject)
        let archive = try ProjectArchive.encode(project: snapshot.project, assets: snapshot.assets)
        let decoded = try ProjectArchive.decode(archive)
        let reopened = ProjectSession(file: decoded.project, assets: decoded.assets, agent: agent, keyProvider: { "fixture-key" })
        defer { reopened.close() }
        #expect(reopened.file.song.tempo == 140)
        #expect(reopened.file.generations[0].isUndone)
        #expect(reopened.file.conversations[0].messages.map(\.id) == messages.map(\.id))
        #expect(reopened.file.conversations[0].messages.map(\.text) == messages.map(\.text))
        #expect(reopened.file.conversations[0].messages.map(\.runID) == messages.map(\.runID))
        #expect(reopened.file.conversations[0].responseItems == responseItems)
        undo.redo()
        #expect(session.file.song.tempo == 155)
        #expect(session.file.song.key == "G minor")
        #expect(!session.file.generations[0].isUndone)
    }
}
