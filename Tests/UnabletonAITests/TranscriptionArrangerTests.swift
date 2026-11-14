import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private actor TranscriptionTransport: ResponsesTransport {
    enum Step: Sendable { case response(JSONValue), failure(AgentError), wait }
    private var steps: [Step]
    private var requests: [JSONValue] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(body: JSONValue, apiKey: String, status: @escaping @Sendable (String) -> Void) async throws -> JSONValue {
        requests.append(body)
        guard !steps.isEmpty else { throw AgentError.transport("Unexpected transcription request.") }
        switch steps.removeFirst() {
        case .response(let value): return value
        case .failure(let error): throw error
        case .wait: try await Task.sleep(for: .seconds(60)); throw CancellationError()
        }
    }
    func captured() -> [JSONValue] { requests }
}

private let transcriptionConfiguration = AgentConfiguration(model: "fixture-model", apiKey: "fixture-key")

private func arrangementRequest(timing: TranscriptionTiming = .preserve) -> TranscriptionArrangementRequest {
    let transcript = PerformanceTranscript(mode: .humming, events: [
        TranscribedEvent(pitch: 60, startSeconds: 0.1, durationSeconds: 0.4, velocity: 0.8, confidence: 0.95),
        TranscribedEvent(pitch: 64, startSeconds: 0.7, durationSeconds: 0.2, velocity: 0.7, confidence: 0.9)
    ], duration: 1)
    var song = Song(); song.tempo = 120
    let layers = [TranscriptionLayer(name: "My melody"), TranscriptionLayer(name: "Drums", instrumentID: "drums.electronic", role: .drums)]
    let options = TranscriptionOptions(timing: timing, adjustment: .minor, targetLengthBeats: 4, insertionBeat: 8, layers: layers)
    return TranscriptionArrangementRequest(transcript: transcript, options: options, song: song)
}

private func arrangementArguments(_ request: TranscriptionArrangementRequest, changes: [JSONValue] = [], includeLayers: Bool = true) -> JSONValue {
    .object([
        "timing_changes": .array(changes),
        "layers": .array(includeLayers ? request.options.layers.filter { $0.role != .performance }.map { layer in
            .object(["layer_id": .string(layer.id.uuidString), "notes": .array([
                .object(["pitch": .number(36), "start_beat": .number(0), "duration": .number(0.25), "velocity": .number(95)])
            ])])
        } : []),
        "summary": .string("Kept the detected melody and added the requested accompaniment.")
    ])
}

private func timingArguments(_ request: TranscriptionArrangementRequest, onsetShift: Double = 0.1) throws -> [JSONValue] {
    try request.transcript.notes(tempo: request.song.tempo).map { note in
        .object(["source_event_id": .string(note.id.uuidString), "start_beat": .number(note.startBeat + onsetShift), "duration": .number(note.duration)])
    }
}

private func arrangementResponse(_ arguments: JSONValue, model: String = "fixture-model", callCount: Int = 1, callStatus: String = "completed") throws -> JSONValue {
    let encoded = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
    let call: JSONValue = .object(["type": .string("function_call"), "name": .string("arrange_transcription"),
        "call_id": .string("call-fixture"), "status": .string(callStatus), "arguments": .string(encoded)])
    return .object(["status": .string("completed"), "model": .string(model), "output": .array(Array(repeating: call, count: callCount)),
        "usage": .object(["input_tokens": .number(10), "output_tokens": .number(5)])])
}

struct TranscriptionArrangerTests {
    @Test func revisionReplansShareRequestsAndCumulativeUsage() async throws {
        let request = arrangementRequest(), value = try arrangementResponse(arrangementArguments(request))
        let transport = TranscriptionTransport([.response(value), .response(value), .response(value)])
        let budget = GenerationBudget(maximumRequests: 2)
        var configuration = transcriptionConfiguration; configuration.runBudget = budget
        let arranger = TranscriptionArranger(transport: transport)
        let first = try await arranger.arrange(request: request, configuration: configuration)
        let second = try await arranger.arrange(request: request, configuration: configuration)
        #expect(first.inputTokens == 10 && first.outputTokens == 5)
        #expect(second.inputTokens == 20 && second.outputTokens == 10)
        #expect(second.generationRequests == 2 && second.transientRetries == 0)
        #expect(second.attemptedModels == ["fixture-model", "fixture-model"])
        await #expect(throws: AgentError.self) { _ = try await arranger.arrange(request: request, configuration: configuration) }
        #expect(await transport.captured().count == 2)
        #expect(await budget.snapshot().requests == 2)
    }

    @Test func revisionReplansDoNotResetDeadlineOrRetryAllowance() async throws {
        let request = arrangementRequest(), value = try arrangementResponse(arrangementArguments(request))
        let failure = AgentError.provider(status: 503, message: "Temporary")
        let transport = TranscriptionTransport([.failure(failure), .failure(failure), .response(value), .failure(failure), .response(value)])
        let budget = GenerationBudget()
        var configuration = transcriptionConfiguration; configuration.runBudget = budget
        let arranger = TranscriptionArranger(transport: transport)
        _ = try await arranger.arrange(request: request, configuration: configuration)
        await #expect(throws: AgentError.self) { _ = try await arranger.arrange(request: request, configuration: configuration) }
        #expect(await budget.snapshot().retries == 2)
        #expect(await transport.captured().count == 4)

        let timedTransport = TranscriptionTransport([.response(value), .wait])
        configuration.runBudget = GenerationBudget(timeout: 0.1)
        let timed = TranscriptionArranger(transport: timedTransport)
        _ = try await timed.arrange(request: request, configuration: configuration)
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: AgentError.self) { _ = try await timed.arrange(request: request, configuration: configuration) }
        #expect(await timedTransport.captured().count == 1)
    }

    @Test func revisionReplansRetainTheFrontierUpgrade() async throws {
        let request = arrangementRequest()
        let transport = TranscriptionTransport([
            .response(try arrangementResponse(arrangementArguments(request, includeLayers: false), model: "gpt-6-luna")),
            .response(try arrangementResponse(arrangementArguments(request), model: "gpt-6-astra")),
            .response(try arrangementResponse(arrangementArguments(request), model: "gpt-6-astra"))
        ])
        var configuration = AgentConfiguration(apiKey: "fixture"); configuration.runBudget = GenerationBudget()
        let arranger = TranscriptionArranger(transport: transport)
        _ = try await arranger.arrange(request: request, configuration: configuration)
        let result = try await arranger.arrange(request: request, configuration: configuration)
        #expect(result.attemptedModels == ["gpt-6-luna", "gpt-6-astra", "gpt-6-astra"])
        #expect(result.routingReason?.contains("transcription constraints") == true)
        #expect(result.inputTokens == 30 && result.outputTokens == 15)
        #expect(await transport.captured()[2]["model"]?.stringValue == "gpt-6-astra")
    }

    @Test func revisionReplansShareTheRemainingOutputBudget() async throws {
        let request = arrangementRequest()
        var large = try arrangementResponse(arrangementArguments(request))
        if case .object(var fields) = large {
            fields["usage"] = .object(["input_tokens": .number(10), "output_tokens": .number(65_530)])
            large = .object(fields)
        }
        let value = try arrangementResponse(arrangementArguments(request))
        let transport = TranscriptionTransport([.response(large), .response(value), .response(value)])
        var configuration = transcriptionConfiguration; configuration.runBudget = GenerationBudget()
        let arranger = TranscriptionArranger(transport: transport)
        _ = try await arranger.arrange(request: request, configuration: configuration)
        let second = try await arranger.arrange(request: request, configuration: configuration)
        #expect(second.outputTokens == 65_535)
        await #expect(throws: AgentError.self) { _ = try await arranger.arrange(request: request, configuration: configuration) }
        let bodies = await transport.captured()
        #expect(bodies[1]["max_output_tokens"]?.doubleValue == 6)
        #expect(bodies[2]["max_output_tokens"]?.doubleValue == 1)
        #expect(await configuration.runBudget?.snapshot().outputTokens == 65_540)
    }

    @Test func strictRequestContainsMeasuredNotesAndNoRecordingData() async throws {
        var request = arrangementRequest()
        let asset = AudioAsset(fileName: "Private-recording.wav", duration: 1, sampleRate: 16000, channels: 1)
        request.song.assets = [asset]
        request.song.tracks = [Track(name: "Private-track-name", clips: [Clip(name: "Private-clip-name", startBeat: 8, lengthBeats: 4, notes: [NoteEvent()])])]
        let original = request
        let transport = TranscriptionTransport([.response(try arrangementResponse(arrangementArguments(request)))])
        let result = try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
        #expect(result.plan.timingChanges.isEmpty)
        #expect(result.plan.layers.count == 1)
        #expect(result.plan.layers[0].layerID == request.options.layers[1].id)
        #expect(result.plan.layers[0].notes[0].pitch == 36)
        #expect(result.inputTokens == 10 && result.outputTokens == 5)
        #expect(request.song == original.song && request.transcript == original.transcript)
        let bodies = await transport.captured(), body = try #require(bodies.first)
        #expect(body["store"] == .bool(false))
        #expect(body["parallel_tool_calls"] == .bool(false))
        #expect(body["tool_choice"]?["name"]?.stringValue == "arrange_transcription")
        let tool = try #require(body["tools"]?.arrayValue?.first)
        #expect(tool["strict"] == .bool(true))
        #expect(tool["parameters"]?["additionalProperties"] == .bool(false))
        #expect(tool["parameters"]?["properties"]?["timing_changes"]?["maxItems"] == .number(0))
        let payloadText = try #require(body["input"]?.arrayValue?.first?["content"]?.stringValue)
        #expect(!payloadText.contains("Private-"))
        #expect(!payloadText.contains("assetID") && !payloadText.contains("input_audio"))
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(payloadText.utf8))
        let first = try #require(payload["source_events"]?.arrayValue?.first)
        #expect(first["source_event_id"]?.stringValue == request.transcript.events[0].id.uuidString)
        #expect(first["pitch"] == .number(60))
        #expect(first["start_beat"] == .number(0.2))
        #expect(payload["insertion_beat"] == .number(8))
        #expect(payload["requested_ai_layers"]?.arrayValue?.count == 1)
    }

    @Test func minorTimingRetainsEverySourceIdentityAndSupportsNoAccompaniment() async throws {
        var request = arrangementRequest(timing: .autoTime)
        request.options.layers.removeLast()
        let changes = try timingArguments(request)
        let transport = TranscriptionTransport([.response(try arrangementResponse(arrangementArguments(request, changes: changes)))])
        let result = try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
        #expect(result.plan.layers.isEmpty)
        #expect(result.plan.timingChanges.map(\.sourceEventID) == request.transcript.events.map(\.id))
        #expect(abs(result.plan.timingChanges[0].startBeat - 0.3) < 1e-12)
        let body = try #require(await transport.captured().first)
        #expect(body["tools"]?.arrayValue?.first?["parameters"]?["properties"]?["layers"]?["maxItems"] == .number(0))
    }

    @Test func preserveTimeRejectsAnyTimingEditWithoutChangingTheRequest() async throws {
        let request = arrangementRequest(), original = arrangementRequest()
        let changes = try timingArguments(request)
        let transport = TranscriptionTransport([.response(try arrangementResponse(arrangementArguments(request, changes: changes)))])
        await #expect(throws: AgentError.self) {
            try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
        }
        #expect(request.transcript.events[0].startSeconds == original.transcript.events[0].startSeconds)
        #expect(await transport.captured().count == 1)
    }

    @Test func missingOrUnrequestedLayersAreRejected() async throws {
        let request = arrangementRequest()
        let missing = arrangementArguments(request, includeLayers: false)
        var unknown = arrangementArguments(request)
        if case .object(var root) = unknown, case .object(var layer) = root["layers"]?.arrayValue?.first {
            layer["layer_id"] = .string(UUID().uuidString); root["layers"] = .array([.object(layer)]); unknown = .object(root)
        }
        for invalid in [missing, unknown] {
            let transport = TranscriptionTransport([.response(try arrangementResponse(invalid))])
            await #expect(throws: AgentError.self) {
                try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
            }
            #expect(await transport.captured().count == 1)
        }
    }

    @Test func automaticUpgradeUsesOriginalRequestAndAggregatesUsage() async throws {
        let request = arrangementRequest()
        let transport = TranscriptionTransport([
            .response(try arrangementResponse(arrangementArguments(request, includeLayers: false), model: "gpt-6-luna")),
            .response(try arrangementResponse(arrangementArguments(request), model: "gpt-6-astra"))
        ])
        let result = try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: .init(apiKey: "fixture"))
        #expect(result.model == "gpt-6-astra")
        #expect(result.attemptedModels == ["gpt-6-luna", "gpt-6-astra"])
        #expect(result.routingReason?.contains("transcription constraints") == true)
        #expect(result.inputTokens == 20 && result.outputTokens == 10)
        let bodies = await transport.captured()
        #expect(bodies.count == 2)
        #expect(bodies[0]["input"] == bodies[1]["input"])
    }

    @Test func automaticUpgradeHappensOnlyOnceAndFixedModelsNeverUpgrade() async throws {
        let request = arrangementRequest(), invalid = arrangementArguments(arrangementRequest(), includeLayers: false)
        for configuration in [AgentConfiguration(apiKey: "fixture"), transcriptionConfiguration] {
            let transport = TranscriptionTransport([.response(try arrangementResponse(invalid)), .response(try arrangementResponse(invalid))])
            await #expect(throws: AgentError.self) {
                try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: configuration)
            }
            #expect(await transport.captured().count == (configuration.autoUpgrade ? 2 : 1))
        }
    }

    @Test func incompleteAndParallelCallsAreNeverAccepted() async throws {
        let request = arrangementRequest(), args = arrangementArguments(request)
        for response in [try arrangementResponse(args, callCount: 2), try arrangementResponse(args, callStatus: "in_progress")] {
            let transport = TranscriptionTransport([.response(response)])
            await #expect(throws: AgentError.self) {
                try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
            }
        }
    }

    @Test func malformedIDsAndAdditionalFieldsAreRejected() async throws {
        var request = arrangementRequest(timing: .autoTime); request.options.layers.removeLast()
        let validChanges = try timingArguments(request)
        for rawID in ["not-a-uuid", request.transcript.events[0].id.uuidString] {
            var changes = validChanges
            if case .object(var fields) = changes[0] {
                fields["source_event_id"] = .string(rawID)
                if rawID != "not-a-uuid" { fields["pitch"] = .number(72) }
                changes[0] = .object(fields)
            }
            let transport = TranscriptionTransport([.response(try arrangementResponse(arrangementArguments(request, changes: changes)))])
            await #expect(throws: AgentError.self) {
                try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
            }
        }
    }

    @Test func unsupportedPerformanceInstrumentFailsBeforeNetworking() async throws {
        var request = arrangementRequest(); request.options.layers[0].instrumentID = "sampled.bass"
        let transport = TranscriptionTransport([])
        await #expect(throws: AgentError.self) {
            try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
        }
        #expect(await transport.captured().isEmpty)
    }

    @Test func transientRetriesAreSharedAndBounded() async throws {
        let request = arrangementRequest()
        let transport = TranscriptionTransport([
            .failure(.provider(status: 503, message: "Temporary")), .failure(.provider(status: 429, message: "Temporary")),
            .failure(.provider(status: 502, message: "Temporary")), .response(try arrangementResponse(arrangementArguments(request)))
        ])
        await #expect(throws: AgentError.self) {
            try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
        }
        #expect(await transport.captured().count == 3)
    }

    @Test func requestBudgetIncludesTransientAttempts() async throws {
        let request = arrangementRequest()
        let transport = TranscriptionTransport([.failure(.provider(status: 503, message: "Temporary"))])
        var configuration = transcriptionConfiguration; configuration.maximumSteps = 1
        await #expect(throws: AgentError.self) {
            try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: configuration)
        }
        #expect(await transport.captured().count == 1)
    }

    @Test func cancellationAndTimeoutCancelInflightWorkWithoutRetry() async throws {
        let request = arrangementRequest(), transport = TranscriptionTransport([.wait])
        let task = Task { try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await transport.captured().isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(await transport.captured().count == 1)

        let timedTransport = TranscriptionTransport([.wait])
        var configuration = transcriptionConfiguration; configuration.timeout = 0.03
        let start = ContinuousClock.now
        do {
            _ = try await TranscriptionArranger(transport: timedTransport).arrange(request: request, configuration: configuration)
            Issue.record("Expected timeout")
        } catch let error as AgentError {
            if case .limit = error {} else { Issue.record("Unexpected timeout error: \(error)") }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await timedTransport.captured().count == 1)
    }

    @Test func existingSongContextIsBounded() async throws {
        var request = arrangementRequest()
        let notes = (0..<700).map { NoteEvent(pitch: 60, startBeat: Double($0) / 1000, duration: 0.001) }
        request.song.tracks = [Track(clips: [Clip(startBeat: 8, lengthBeats: 4, notes: notes)])]
        let transport = TranscriptionTransport([.response(try arrangementResponse(arrangementArguments(request)))])
        _ = try await TranscriptionArranger(transport: transport).arrange(request: request, configuration: transcriptionConfiguration)
        let body = try #require(await transport.captured().first)
        let text = try #require(body["input"]?.arrayValue?.first?["content"]?.stringValue)
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(payload["song_context"]?["context_truncated"] == .bool(true))
        let sent = payload["song_context"]?["tracks"]?.arrayValue?.first?["clips"]?.arrayValue?.first?["notes"]?.arrayValue
        #expect(sent?.count == 512)
    }
}
