import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private actor ReconstructionTransport: ResponsesTransport {
    var count = 0
    let repeated: Bool
    init(repeated: Bool = false) { self.repeated = repeated }
    func send(body: JSONValue, apiKey: String, status: @escaping @Sendable (String) -> Void) async throws -> JSONValue {
        count += 1
        let item: JSONValue
        if count == 1 || repeated {
            let arguments: JSONValue = .object(["attachment_id": .string("fixture"), "source_start_seconds": .number(10),
                "source_end_seconds": .number(14), "start_beat": .number(8)])
            item = .object(["type": .string("function_call"), "name": .string("reconstruct_reference"),
                "call_id": .string("reconstruct-\(count)"), "arguments": .string(String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))])
        } else {
            item = .object(["type": .string("message"), "role": .string("assistant"),
                "content": .array([.object(["type": .string("output_text"), "text": .string("Reconstructed measured instruments.")])])])
        }
        return .object(["status": .string("completed"), "model": .string("fixture"), "output": .array([item]),
            "usage": .object(["input_tokens": .number(10), "output_tokens": .number(5)])])
    }
}

private actor ReconstructionPreviewCalls {
    var count = 0
    func record() { count += 1 }
}

struct ReferenceReconstructionAgentTests {
    private func configuration() -> AgentConfiguration {
        let attachment = SongAttachment(fileName: "reference.wav", duration: 20, sampleRate: 48_000, channels: 2,
            byteCount: 100, sha256: String(repeating: "a", count: 64))
        var configuration = AgentConfiguration(model: "fixture", apiKey: "fixture")
        configuration.references = ReferenceTools(attachments: [attachment], execute: { _, _, song in
            let track = Track(name: "Measured bass", instrumentID: "synth.bass", parameters: ["oscillator": 0, "lfoDepth": 0], clips: [
                Clip(startBeat: 8, lengthBeats: 8, notes: [.init(pitch: 43, startBeat: 0, duration: 1, velocity: 80)])
            ])
            return ReferenceToolResult(output: .object(["ok": .bool(true)]), commands: [.init(op: .addTrack, track: track)])
        }, assets: { _ in [:] })
        return configuration
    }

    private var conversation: Conversation {
        var chat = Conversation(); chat.messages = [.init(role: "user", text: "Closely replicate the attached instrumental.")]
        return chat
    }

    @Test func reconstructionRendersCandidateBeforeReturningTheDraft() async throws {
        let calls = ReconstructionPreviewCalls(), original = Song()
        let result = try await MusicAgent(transport: ReconstructionTransport()).generate(song: original,
            conversation: conversation, selection: .init(), configuration: configuration(), preview: { candidate, start, length in
                #expect(candidate.tracks.count == 1)
                #expect(start == 8 && length > 0)
                await calls.record()
                return PreviewReport(duration: 4, peak: 0.3, rms: 0.1)
            })
        #expect(original.tracks.isEmpty)
        #expect(result.song.tracks.count == 1)
        #expect(await calls.count == 1)
        let outputs = result.responseItems.compactMap { $0["output"]?.stringValue }
        #expect(outputs.contains { $0.contains("rendered_preview") })
    }

    @Test func repeatedClippingNeverReturnsAnAcceptedReconstruction() async throws {
        let original = Song(), calls = ReconstructionPreviewCalls()
        await #expect(throws: AgentError.self) {
            _ = try await MusicAgent(transport: ReconstructionTransport(repeated: true)).generate(song: original,
                conversation: conversation, selection: .init(), configuration: configuration(), preview: { candidate, _, _ in
                    #expect(candidate.tracks.count == 1) // A rejected candidate was never assigned to the draft.
                    await calls.record()
                    return PreviewReport(duration: 4, peak: 1.2, rms: 0.5, clippedSamples: 25)
                })
        }
        #expect(await calls.count == 3)
        #expect(original.tracks.isEmpty)
    }

    @Test func cancellationDuringPreviewLeavesOriginalIntact() async throws {
        let calls = ReconstructionPreviewCalls(), original = Song(), configuration = configuration(), chat = conversation
        let task = Task {
            try await MusicAgent(transport: ReconstructionTransport()).generate(song: original,
                conversation: chat, selection: .init(), configuration: configuration, preview: { _, _, _ in
                    await calls.record()
                    try await Task.sleep(for: .seconds(60))
                    return PreviewReport(duration: 4)
                })
        }
        for _ in 0..<1000 {
            if await calls.count > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await calls.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(original.tracks.isEmpty)
    }
}
