import Foundation
import AVFAudio
import Testing
import UnabletonCore
import UnabletonAudio
import UnabletonAI
@testable import Unableton

private enum ChatAttachmentFixtureError: Error { case timeout, unexpectedProviderCall }

private struct NoAttachmentNetworkAgent: MusicGenerating {
    func generate(song: Song, conversation: Conversation, selection: ProjectSelection, configuration: AgentConfiguration,
                  vocals: VocalSession?, preview: @escaping @Sendable (Song, Double, Double) async throws -> PreviewReport,
                  status: @escaping @Sendable (String) -> Void) async throws -> AgentResult {
        throw ChatAttachmentFixtureError.unexpectedProviderCall
    }
}

private struct NoAttachmentAudioInspector: ReferenceAudioInspecting {
    func inspect(audio: URL, question: String, budget: GenerationBudget) async throws -> String {
        throw ChatAttachmentFixtureError.unexpectedProviderCall
    }
}

private struct ChatAudioFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-Chat-Attachment-Test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func song(_ name: String, frequency: Double = 220) throws -> URL {
        let url = directory.appendingPathComponent(name + ".wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<16_000 { samples[frame] = Float(sin(Double(frame) * 2 * .pi * frequency / 16_000) * 0.1) }
        do { let writer = try AVAudioFile(forWriting: url, settings: format.settings); try writer.write(from: buffer) }
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private func waitForAttachment(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ChatAttachmentFixtureError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func attachmentSession() -> ProjectSession {
    ProjectSession(agent: NoAttachmentNetworkAgent(), keyProvider: { "attachment-fixture-key" }, mode: .superhuman)
}

@MainActor
struct ChatAttachmentTests {
    @Test func attachingCopiesAudioWithoutMusicalRevisionOrUndo() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let source = try fixture.song("Reference")
        let sourceBytes = try Data(contentsOf: source)
        let session = attachmentSession(); defer { session.close() }
        let original = session.file.song, undo = try #require(session.undoManager)
        session.attachSongs([source])
        try await waitForAttachment { !session.attachmentImporting }
        let attachment = try #require(session.file.attachments?.first)
        let owned = try #require(session.assetURLs[attachment.id])
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: owned) == sourceBytes)
        #expect(attachment.sha256 == SongAttachmentLimits.sha256(sourceBytes))
        #expect(attachment.duration == 1)
        #expect(session.file.song == original)
        #expect(!undo.canUndo)
        #expect(session.pendingAttachmentIDs == [attachment.id])
        #expect(session.currentConversation?.messages.isEmpty == true)
    }

    @Test func submittedOrderAndChatCutoffStayFrozenWhileMoreSongsAreAttached() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let first = try fixture.song("First"), second = try fixture.song("Second", frequency: 330)
        let later = try fixture.song("Later", frequency: 440), other = try fixture.song("Other chat", frequency: 550)
        let session = attachmentSession(); defer { session.close() }
        // Prevent queue execution: this test inspects frozen queue scopes without
        // opening provider sessions or touching the user's vocal credentials.
        session.generationTask = Task {}
        let firstChat = try #require(session.selectedConversationID)
        session.attachSongs([first, second])
        try await waitForAttachment { !session.attachmentImporting }
        let originalIDs = session.pendingAttachmentIDs
        #expect(originalIDs.count == 2)
        session.movePendingAttachment(originalIDs[1], by: -1)
        let submittedOrder = Array(originalIDs.reversed())
        session.composer = "Use the first song, then the second."; session.submitPrompt()
        let firstRequest = try #require(session.pendingPrompts.first)
        #expect(session.file.conversations.first(where: { $0.id == firstChat })?.messages.first?.attachmentIDs == submittedOrder)
        #expect(session.pendingAttachmentIDs.isEmpty)

        session.attachSongs([later])
        try await waitForAttachment { !session.attachmentImporting }
        let laterID = try #require(session.pendingAttachmentIDs.first)
        session.composer = "Use this next."; session.submitPrompt()
        let firstTools = try #require(session.referenceTools(for: firstRequest, budget: GenerationBudget(), openAIKey: "fixture-key"))
        #expect(firstTools.attachments.map(\.id) == submittedOrder)
        #expect(!firstTools.attachments.contains(where: { $0.id == laterID }))

        session.newConversation()
        let otherChat = try #require(session.selectedConversationID)
        #expect(session.pendingAttachmentIDs.isEmpty)
        session.attachSongs([other])
        try await waitForAttachment { !session.attachmentImporting }
        let otherID = try #require(session.pendingAttachmentIDs.first)
        session.composer = "Inspect only this song."; session.submitPrompt()
        let otherRequest = try #require(session.pendingPrompts.last)
        let otherTools = try #require(session.referenceTools(for: otherRequest, budget: GenerationBudget(), openAIKey: "fixture-key"))
        #expect(otherRequest.conversationID == otherChat)
        #expect(otherTools.attachments.map(\.id) == [otherID])
        #expect(session.pendingPrompts.count == 3)
        #expect(session.file.song.revision == 0)
    }

    @Test func vocalConversionPermissionUsesOnlySubmittedMessageAtItsQueueCutoff() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let session = attachmentSession(); defer { session.close() }
        session.generationTask = Task {}
        session.attachSongs([try fixture.song("Convert Vocals Into Piano")])
        try await waitForAttachment { !session.attachmentImporting }
        session.composer = "Please convert the vocals into instrument notes."; session.submitPrompt()
        let explicit = try #require(session.pendingPrompts.last)
        session.composer = "Make the instrumental sound more like the original. Keep vocals as audio."; session.submitPrompt()
        let normal = try #require(session.pendingPrompts.last)
        let explicitTools = try #require(session.referenceTools(for: explicit, budget: GenerationBudget(), openAIKey: "fixture-key"))
        let normalTools = try #require(session.referenceTools(for: normal, budget: GenerationBudget(), openAIKey: "fixture-key"))
        #expect(explicitTools.allowsVocalNoteConversion)
        #expect(!normalTools.allowsVocalNoteConversion)
        #expect(explicitTools.attachments.map(\.id) == normalTools.attachments.map(\.id))
        #expect(session.file.song.revision == 0)
    }

    @Test func pendingSongsRemainWithTheirOriginatingConversation() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let session = attachmentSession(); defer { session.close() }
        let firstChat = try #require(session.selectedConversationID)
        session.attachSongs([try fixture.song("First")])
        try await waitForAttachment { !session.attachmentImporting }
        let firstID = try #require(session.pendingAttachmentIDs.first)
        session.newConversation()
        #expect(session.pendingAttachmentIDs.isEmpty)
        session.attachSongs([try fixture.song("Second")])
        try await waitForAttachment { !session.attachmentImporting }
        let secondID = try #require(session.pendingAttachmentIDs.first)
        session.selectedConversationID = firstChat
        #expect(session.pendingAttachmentIDs == [firstID])
        session.removePendingAttachment(firstID)
        #expect(session.pendingAttachmentIDs.isEmpty)
        #expect(session.composerAttachments.values.contains([secondID]))
        #expect(session.file.song.tracks.isEmpty)
    }

    @Test func sourcesAndMeasuredMidiSurviveDocumentSaveAndReopen() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let session = attachmentSession(); defer { session.close() }
        session.attachSongs([try fixture.song("Saved reference")])
        try await waitForAttachment { !session.attachmentImporting }
        let id = try #require(session.pendingAttachmentIDs.first)
        let midi = MIDIImport(parts: [.init(id: "lead", name: "Lead", channel: 0, program: 0, isPercussion: false,
            notes: [.init(pitch: 60, startSeconds: 0.1, durationSeconds: 0.2, velocity: 95)], referenceStem: "other")], duration: 0.5, initialTempo: 120)
        session.file.attachments?[0].midi = midi
        session.file.conversations[0].messages.append(ChatMessage(role: "user", text: "Recreate this.", attachmentIDs: [id]))
        let snapshot = try session.document.snapshot(contentType: .unabletonProject)
        let blobs = try #require(snapshot.blobs)
        let package = try ProjectArchive.encode(project: snapshot.project, blobURLs: blobs.urls, lease: blobs.lease)
        let url = fixture.directory.appendingPathComponent("Song.unableton")
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
        let reopenedDocument = UnabletonDocument()
        let store = try #require(reopenedDocument.blobStore)
        let decoded = try ProjectArchive.decodeFiles(FileWrapper(url: url, options: []), into: store)
        try reopenedDocument.install(files: decoded.assets)
        reopenedDocument.project = decoded.project
        let reopened = ProjectSession(document: reopenedDocument, agent: NoAttachmentNetworkAgent(), keyProvider: { nil })
        defer { reopened.close() }
        #expect(reopened.file.song == session.file.song)
        #expect(reopened.file.attachments?.first?.midi == midi)
        #expect(reopened.file.conversations[0].messages.first?.attachmentIDs == [id])
        #expect(try SongAttachmentLimits.sha256(file: #require(reopened.assetURLs[id])) == session.attachment(id)?.sha256)
        #expect(reopened.file.song.assets.isEmpty)
    }

    @Test func invalidOversizedAndTooManySourcesNeverEnterTheArrangement() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let session = attachmentSession(); defer { session.close() }
        let invalid = fixture.directory.appendingPathComponent("Invalid.mp3")
        try Data("This is not audio.".utf8).write(to: invalid)
        session.attachSongs([invalid])
        try await waitForAttachment { !session.attachmentImporting }
        #expect(session.file.attachments?.isEmpty != false)
        #expect(session.errorMessage != nil)
        let oversized = fixture.directory.appendingPathComponent("Too big.wav")
        #expect(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(SongAttachmentLimits.maximumSourceBytes + 1)); try handle.close()
        session.attachSongs([oversized])
        try await waitForAttachment { !session.attachmentImporting }
        #expect(session.file.attachments?.isEmpty != false)
        session.errorMessage = nil
        session.attachSongs(Array(repeating: try fixture.song("Valid"), count: 5))
        #expect(!session.attachmentImporting)
        #expect(session.errorMessage?.contains("four") == true)
        #expect(session.file.song.revision == 0 && session.file.song.tracks.isEmpty)
        #expect(session.pendingAttachmentIDs.isEmpty)
    }

    @Test func cancellationAndClosePreventLateAttachmentPublication() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let source = try fixture.song("Canceled")
        let session = attachmentSession(); defer { session.close() }
        session.attachSongs([source]); session.attachmentImportTask?.cancel()
        try await waitForAttachment { !session.attachmentImporting }
        #expect(session.pendingAttachmentIDs.isEmpty)
        #expect(session.file.attachments?.isEmpty != false)
        session.attachSongs([source]); session.close()
        try await waitForAttachment { !session.attachmentImporting }
        #expect(session.closed)
        #expect(session.pendingAttachmentIDs.isEmpty)
        #expect(session.file.attachments?.isEmpty != false)
        #expect(session.file.song.revision == 0)
    }

    @Test func cachedMeasuredNotesInsertWithoutCloudAndRejectIncompatibleSounds() async throws {
        let fixture = try ChatAudioFixture(); defer { fixture.remove() }
        let source = try fixture.song("Measured")
        let bytes = try Data(contentsOf: source)
        let score = MIDIImport(parts: [.init(id: "lead", name: "Lead", channel: 0, program: 0, isPercussion: false,
            notes: [.init(pitch: 60, startSeconds: 0.1, durationSeconds: 0.2, velocity: 95)], referenceStem: "other")], duration: 0.5, initialTempo: 120)
        let attachment = SongAttachment(fileName: "Measured.wav", duration: 1, sampleRate: 16_000, channels: 1,
            byteCount: bytes.count, sha256: SongAttachmentLimits.sha256(bytes), midi: score)
        let runtime = SongReferenceRuntime(attachments: [attachment], sources: [attachment.id: source],
            directory: fixture.directory.appendingPathComponent("Draft"), budget: GenerationBudget(),
            processor: { throw ChatAttachmentFixtureError.unexpectedProviderCall }, inspector: NoAttachmentAudioInspector(), lease: nil,
            update: { _, _, _ in }, status: { _, _ in })
        var song = Song(); song.tempo = 120
        var fields: [String: JSONValue] = ["attachment_id": .string(attachment.id.uuidString), "part_id": .string("lead"),
            "instrument_id": .string("synth.lead"), "source_start_seconds": .number(0), "source_end_seconds": .number(0.5),
            "start_beat": .number(4), "track_name": .string("Extracted lead"), "target_track_id": .null]
        let result = try await runtime.execute("insert_reference_notes", arguments: .object(fields), song: song)
        #expect(song.tracks.isEmpty)
        try ProjectEditor.apply(result.commands, to: &song)
        let clip = try #require(song.tracks.first?.clips.first)
        #expect(clip.referenceAttachmentID == attachment.id)
        #expect(clip.startBeat == 4 && clip.lengthBeats == 1)
        #expect(clip.notes.first?.startBeat == 0.2)
        #expect(abs((clip.notes.first?.duration ?? 0) - 0.4) < 0.000001)
        #expect(clip.notes.first?.pitch == 60)
        fields["instrument_id"] = .string("sampled.bass")
        await #expect(throws: AgentError.self) { try await runtime.execute("insert_reference_notes", arguments: .object(fields), song: Song()) }
    }
}
