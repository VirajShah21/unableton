import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private actor ReferenceAgentTransport: ResponsesTransport {
    private var responses: [JSONValue]
    private var requests: [JSONValue] = []
    init(_ responses: [JSONValue]) { self.responses = responses }
    func send(body: JSONValue, apiKey: String, status: @escaping @Sendable (String) -> Void) async throws -> JSONValue {
        requests.append(body)
        guard !responses.isEmpty else { throw AgentError.transport("Unexpected additional composition request") }
        return .object(["status": .string("completed"), "model": body["model"] ?? .string("test"),
            "output": .array([responses.removeFirst()]), "usage": .object(["input_tokens": .number(10), "output_tokens": .number(5)])])
    }
    func captured() -> [JSONValue] { requests }
}
private actor ReferenceAgentCalls {
    var calls = 0
    var entered = false
    func record() { calls += 1; entered = true }
    func count() -> Int { calls }
    func hasEntered() -> Bool { entered }
}
private func referenceCall(_ name: String, arguments: JSONValue = .object([:])) throws -> JSONValue {
    .object(["type": .string("function_call"), "name": .string(name), "call_id": .string("reference-call"),
             "arguments": .string(String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))])
}
private func referenceAnswer() -> JSONValue {
    .object(["type": .string("message"), "role": .string("assistant"),
        "content": .array([.object(["type": .string("output_text"), "text": .string("Finished with the attached song.")])])])
}

struct ReferenceAgentTests {
    private func attachment() -> SongAttachment {
        SongAttachment(fileName: "Song one.mp3", duration: 10, sampleRate: 48_000, channels: 2, byteCount: 3,
                       sha256: String(repeating: "a", count: 64), analysis: .object(["private-analysis": .string("PRIVATE_ANALYSIS_DO_NOT_DUMP")]),
                       midi: MIDIImport(parts: [.init(id: "private-midi-id", name: "PRIVATE_MIDI_DO_NOT_DUMP", channel: 0, program: 0, isPercussion: false,
                           notes: [.init(pitch: 60, startSeconds: 1, durationSeconds: 1, velocity: 80)])], duration: 10, initialTempo: 120))
    }
    private func conversation(_ attachment: SongAttachment) -> Conversation {
        var chat = Conversation()
        chat.messages = [ChatMessage(role: "user", text: "Recreate the attached song", attachmentIDs: [attachment.id])]
        return chat
    }

    @Test func authoritativeManifestContainsOnlyBoundedPublicMetadata() async throws {
        let attachment = attachment(), transport = ReferenceAgentTransport([referenceAnswer()])
        var configuration = AgentConfiguration(model: "test", apiKey: "key")
        configuration.references = ReferenceTools(attachments: [attachment], execute: { _, _, _ in
            throw ReferenceProcessingFailure("No processing should be needed for this test")
        }, assets: { _ in [:] })
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(attachment), selection: .init(), configuration: configuration)
        let first = try #require(await transport.captured().first)
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(encoded.contains(attachment.id.uuidString))
        #expect(encoded.contains("Song one.mp3"))
        #expect(encoded.contains("song_number"))
        #expect(!encoded.contains("PRIVATE_ANALYSIS_DO_NOT_DUMP"))
        #expect(!encoded.contains("PRIVATE_MIDI_DO_NOT_DUMP"))
        #expect(!encoded.contains(attachment.sha256))
        #expect(!encoded.contains("input_audio"))
        #expect(encoded.contains("not authorized for this prompt"))
        #expect(encoded.contains("keep vocals as audio"))
        #expect(result.generatedFiles.isEmpty)
        let tools = first["tools"]?.arrayValue ?? []
        #expect(tools.contains { $0["name"]?.stringValue == "insert_reference_audio" })
        #expect(!tools.contains { $0["name"]?.stringValue == "inspect_reference_audio" })
        #expect(first["store"] == .bool(false))
        #expect(first["parallel_tool_calls"] == .bool(false))
    }

    @Test func audioInspectionIsExposedOnlyWithExplicitOptIn() async throws {
        let attachment = attachment(), transport = ReferenceAgentTransport([referenceAnswer()])
        var configuration = AgentConfiguration(model: "test", apiKey: "key")
        configuration.references = ReferenceTools(attachments: [attachment], allowsAudioInspection: true, execute: { _, _, _ in
            throw ReferenceProcessingFailure("No audio inspection was requested")
        }, assets: { _ in [:] })
        _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(attachment), selection: .init(), configuration: configuration)
        let first = try #require(await transport.captured().first)
        let tools = first["tools"]?.arrayValue ?? []
        #expect(tools.contains { $0["name"]?.stringValue == "inspect_reference_audio" })
        #expect(tools.contains { $0["name"]?.stringValue == "inspect_reference" })
        #expect((try JSONEncoder().encode(first)).range(of: Data("input_audio".utf8)) == nil)
    }

    @Test func trustedCommandsAndStagedURLsStayOutsideModelContinuation() async throws {
        let attachment = attachment(), asset = AudioAsset(fileName: "host-generated.wav", duration: 1, sampleRate: 48_000, channels: 2)
        let clip = Clip(kind: .audio, lengthBeats: 2, assetID: asset.id)
        let track = Track(name: "Original vocal", kind: .audio, clips: [clip])
        let privateURL = URL(fileURLWithPath: "/private/unableton-reference-test/DO_NOT_SEND.wav")
        let transport = ReferenceAgentTransport([try referenceCall("insert_reference_audio"), referenceAnswer()])
        var configuration = AgentConfiguration(model: "test", apiKey: "key")
        configuration.references = ReferenceTools(attachments: [attachment], execute: { _, _, _ in
            ReferenceToolResult(output: .object(["asset_id": .string(asset.id.uuidString)]), commands: [
                ProjectCommand(op: .addAsset, asset: asset), ProjectCommand(op: .addTrack, track: track)
            ])
        }, assets: { song in song.assets.contains(where: { $0.id == asset.id }) ? [asset.id: privateURL] : [:] })
        let original = Song()
        let result = try await MusicAgent(transport: transport).generate(song: original, conversation: conversation(attachment), selection: .init(), configuration: configuration)
        #expect(original.tracks.isEmpty && original.assets.isEmpty)
        #expect(result.song.assets == [asset])
        #expect(result.song.tracks == [track])
        #expect(result.generatedFiles[asset.id] == privateURL)
        let history = String(decoding: try JSONEncoder().encode(result.responseItems), as: UTF8.self)
        #expect(!history.contains("DO_NOT_SEND"))
        #expect(!history.contains("/private/"))
        #expect(history.contains(asset.id.uuidString))
    }

    @Test func dependencyFailureStopsWithoutRepairRetryOrAutomaticUpgrade() async throws {
        let attachment = attachment(), calls = ReferenceAgentCalls()
        let transport = ReferenceAgentTransport([try referenceCall("inspect_reference")])
        let budget = GenerationBudget()
        var configuration = AgentConfiguration(apiKey: "key", runBudget: budget)
        configuration.references = ReferenceTools(attachments: [attachment], execute: { _, _, _ in
            await calls.record(); throw ReferenceProcessingFailure("Local inference failed")
        }, assets: { _ in [:] })
        await #expect(throws: ReferenceProcessingFailure.self) {
            _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(attachment), selection: .init(), configuration: configuration)
        }
        #expect(await transport.captured().count == 1)
        #expect(await calls.count() == 1)
        #expect(await budget.snapshot().attemptedModels == [ModelRouting.economicalModel])
        #expect(await budget.snapshot().routingReason == nil)
        #expect(await budget.snapshot().retries == 0)
    }

    @Test func cancellationDuringReferenceToolNeverReturnsAStagedDraft() async throws {
        let attachment = attachment(), calls = ReferenceAgentCalls()
        let transport = ReferenceAgentTransport([try referenceCall("inspect_reference")])
        var configuration = AgentConfiguration(model: "test", apiKey: "key")
        configuration.references = ReferenceTools(attachments: [attachment], execute: { _, _, _ in
            await calls.record(); try await Task.sleep(for: .seconds(60)); return ReferenceToolResult(output: .null)
        }, assets: { _ in [:] })
        let configured = configuration, chat = conversation(attachment)
        let task = Task { try await MusicAgent(transport: transport).generate(song: Song(), conversation: chat, selection: .init(), configuration: configured) }
        for _ in 0..<1000 {
            if await calls.hasEntered() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await calls.hasEntered())
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.captured().count == 1)
        #expect(await calls.count() == 1)
    }
}
