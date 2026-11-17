import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private final class MusicAgentTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ interval: TimeInterval) { lock.withLock { time += interval } }
}

private actor MockTransport: ResponsesTransport {
    enum Step: Sendable { case response(JSONValue), failure(AgentError), wait }
    private var steps: [Step]
    private var requests: [JSONValue] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(body: JSONValue, apiKey: String, status: @escaping @Sendable (String) -> Void) async throws -> JSONValue {
        requests.append(body)
        guard !steps.isEmpty else { throw AgentError.transport("Unexpected request") }
        switch steps.removeFirst() {
        case .response(let value): status("Composing…"); return value
        case .failure(let error): throw error
        case .wait: try await Task.sleep(for: .seconds(60)); throw CancellationError()
        }
    }
    func captured() -> [JSONValue] { requests }
}

private func response(_ output: [JSONValue], model: String = "test-model") -> JSONValue {
    .object(["status": .string("completed"), "model": .string(model), "output": .array(output), "usage": .object(["input_tokens": .number(10), "output_tokens": .number(5)])])
}
private func tool(_ name: String, _ args: JSONValue, id: String = "call_1") throws -> JSONValue {
    .object(["type": .string("function_call"), "name": .string(name), "call_id": .string(id), "arguments": .string(String(data: try JSONEncoder().encode(args), encoding: .utf8)!)])
}
private func answer(_ text: String = "Updated the music.") -> JSONValue {
    .object(["type": .string("message"), "role": .string("assistant"), "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])
}
private func conversation() -> Conversation { var c = Conversation(); c.messages = [ChatMessage(role: "user", text: "Write an energetic melody.")]; return c }
private let configuration = AgentConfiguration(model: "test-model", apiKey: "test-key")

private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

struct MusicAgentTests {
    @Test func revisionReplansKeepRequestAllowanceAndCumulativeUsage() async throws {
        let transport = MockTransport([
            .response(response([answer()])),
            .response(response([answer()])),
            .response(response([answer()]))
        ])
        let budget = GenerationBudget(maximumRequests: 2)
        var config = configuration; config.runBudget = budget
        let agent = MusicAgent(transport: transport)
        let first = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        let second = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        #expect(first.inputTokens == 10 && first.outputTokens == 5)
        #expect(second.inputTokens == 20 && second.outputTokens == 10)
        #expect(first.runID == second.runID)
        #expect(second.attemptedModels == ["test-model", "test-model"])
        await #expect(throws: AgentError.self) {
            _ = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        }
        #expect(await transport.captured().count == 2)
        #expect(await budget.snapshot().requests == 2)
    }

    @Test func revisionReplanDoesNotRestartTheDeadline() async throws {
        let transport = MockTransport([.response(response([answer()])), .wait])
        let clock = MusicAgentTestClock()
        var config = configuration; config.runBudget = GenerationBudget(timeout: 0.1, now: { clock.now() })
        let agent = MusicAgent(transport: transport)
        _ = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        clock.advance(0.15)
        await #expect(throws: AgentError.self) {
            _ = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        }
        #expect(await transport.captured().count == 1)
    }

    @Test func revisionReplanKeepsTheOutputTokenBudget() async throws {
        var large = response([answer()])
        if case .object(var fields) = large {
            fields["usage"] = .object(["input_tokens": .number(10), "output_tokens": .number(65_500)])
            large = .object(fields)
        }
        let transport = MockTransport([.response(large), .response(response([answer()]))])
        var config = configuration; config.runBudget = GenerationBudget()
        let agent = MusicAgent(transport: transport)
        _ = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        let result = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        #expect(result.outputTokens == 65_505)
        #expect(await transport.captured()[1]["max_output_tokens"]?.doubleValue == 36)
    }

    @Test func transientRetriesDoNotResetAcrossSuccessfulStepsOrReplans() async throws {
        let failure = AgentError.provider(status: 503, message: "Temporary")
        let transport = MockTransport([
            .failure(failure), .response(response([answer()])),
            .failure(failure), .response(response([try tool("get_project", .object([:]))])),
            .failure(failure), .response(response([answer()]))
        ])
        let budget = GenerationBudget()
        var config = configuration; config.runBudget = budget
        let agent = MusicAgent(transport: transport)
        _ = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        do {
            _ = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
            Issue.record("Expected the third transient failure to stop without a retry")
        } catch let error as AgentError {
            if case .provider(let status, _) = error { #expect(status == 503) } else { Issue.record("Unexpected error: \(error)") }
        }
        let usage = await budget.snapshot()
        #expect(usage.requests == 5 && usage.retries == 2)
        #expect(usage.inputTokens == 20 && usage.outputTokens == 10)
        #expect(await transport.captured().count == 5)
    }

    @Test func revisionReplanRetainsAnAutomaticFrontierUpgrade() async throws {
        let reason = "Interacting musical constraints"
        let transport = MockTransport([
            .response(response([try tool("request_frontier", .object(["reason": .string(reason)]))], model: "gpt-6-luna")),
            .response(response([answer()], model: "gpt-6-astra")),
            .response(response([answer()], model: "gpt-6-astra"))
        ])
        var config = AgentConfiguration(apiKey: "test"); config.runBudget = GenerationBudget()
        let agent = MusicAgent(transport: transport)
        _ = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        let result = try await agent.generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        #expect(result.attemptedModels == ["gpt-6-luna", "gpt-6-astra", "gpt-6-astra"])
        #expect(result.routingReason == reason)
        let requests = await transport.captured()
        #expect(requests[2]["model"]?.stringValue == "gpt-6-astra")
        #expect(requests[2]["tools"]?.arrayValue?.contains { $0["name"]?.stringValue == "request_frontier" } == false)
    }

    @Test func streamedStatusesRetainCompletedBatchMusicalCounts() async throws {
        let track = Track(clips: [Clip(notes: [NoteEvent(pitch: 60)])])
        var encoded = try JSONValue.encode(ProjectCommand(op: .addTrack, track: track))
        if case .object(var command) = encoded, case .object(var value) = command["track"] {
            value["parameters"] = .array([]); command["track"] = .object(value); encoded = .object(command)
        }
        let transport = MockTransport([
            .response(response([try tool("apply_edits", .object(["commands": .array([encoded])]))])),
            .response(response([answer()]))
        ])
        let recorder = StatusRecorder()
        _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: configuration, status: { recorder.append($0) })
        #expect(recorder.snapshot().contains("1 tracks, 1 clips, 1 notes · Composing…"))
    }
    @Test func defaultRoutingIsEconomicalAndExplicitModelsStayFixed() {
        let automatic = AgentConfiguration(apiKey: "test")
        #expect(automatic.model == "gpt-6-luna")
        #expect(automatic.autoUpgrade)
        #expect(automatic.frontierModel == "gpt-6-astra")
        #expect(!AgentConfiguration(model: "gpt-6.1-sol", apiKey: "test").autoUpgrade)
    }

    @Test func autoCompletesRoutineWorkWithEconomicalModel() async throws {
        let transport = MockTransport([.response(response([answer()], model: "gpt-6-luna"))])
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: .init(apiKey: "test"))
        #expect(result.model == "gpt-6-luna")
        #expect(result.attemptedModels == ["gpt-6-luna"])
        #expect(result.routingReason == nil)
        let requests = await transport.captured()
        #expect(requests.count == 1)
        #expect(requests[0]["tools"]?.arrayValue?.contains { $0["name"]?.stringValue == "request_frontier" } == true)
    }

    @Test func requestedUpgradeDiscardsDraftAndAggregatesUsage() async throws {
        let firstCommands = try JSONValue.encode([ProjectCommand(op: .setTempo, value: 155)])
        let finalCommands = try JSONValue.encode([ProjectCommand(op: .setTempo, value: 170)])
        let transport = MockTransport([
            .response(response([try tool("apply_edits", .object(["commands": firstCommands]))], model: "gpt-6-luna")),
            .response(response([try tool("request_frontier", .object(["reason": .string("The interacting harmony and rhythm constraints need stronger planning.")]), id: "upgrade")], model: "gpt-6-luna")),
            .response(response([try tool("apply_edits", .object(["commands": finalCommands]), id: "final_edit")], model: "gpt-6-astra")),
            .response(response([answer()], model: "gpt-6-astra"))
        ])
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: .init(apiKey: "test"))
        #expect(result.song.tempo == 170)
        #expect(result.song.revision == 1)
        #expect(result.model == "gpt-6-astra")
        #expect(result.attemptedModels == ["gpt-6-luna", "gpt-6-astra"])
        #expect(result.inputTokens == 40)
        #expect(result.outputTokens == 20)
        #expect(result.routingReason?.contains("harmony") == true)
        let requests = await transport.captured()
        #expect(requests[2]["tools"]?.arrayValue?.count == 5)
        let frontierContext = try #require(requests[2]["input"]?.arrayValue?.first?["content"]?.stringValue)
        #expect(frontierContext.contains("\"tempo\":140"))
        #expect(!frontierContext.contains("\"tempo\":155"))
    }

    @Test func invalidEditsCanEscalateOnceInAutoMode() async throws {
        let invalid = try JSONValue.encode([ProjectCommand(op: .setTempo, value: -1)])
        let transport = MockTransport([
            .response(response([try tool("apply_edits", .object(["commands": invalid]), id: "bad1")])),
            .response(response([try tool("apply_edits", .object(["commands": invalid]), id: "bad2")])),
            .response(response([try tool("apply_edits", .object(["commands": invalid]), id: "bad3")])),
            .response(response([answer()], model: "gpt-6-astra"))
        ])
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: .init(apiKey: "test"))
        #expect(result.song.tempo == 140)
        #expect(result.attemptedModels == ["gpt-6-luna", "gpt-6-astra"])
        #expect(result.routingReason != nil)
    }

    @Test func fixedModelCannotEscalateAfterAnOutputLimit() async throws {
        let incomplete = JSONValue.object(["status": .string("incomplete"), "incomplete_details": .object(["reason": .string("max_output_tokens")]), "output": .array([])])
        let transport = MockTransport([.response(incomplete), .response(incomplete)])
        do { _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: configuration); Issue.record("Expected output limit") }
        catch let error as AgentError { if case .modelLimit = error {} else { Issue.record("Unexpected error") } }
        #expect(await transport.captured().count == 2)
        let request = await transport.captured()[0]
        #expect(request["tools"]?.arrayValue?.count == 5)
    }

    @Test func autoDoesNotUpgradeOnAuthenticationOrBrokenStreams() async throws {
        for error in [AgentError.provider(status: 401, message: "Invalid key"), .provider(status: 402, message: "No credits"), .incomplete("Disconnected stream")] {
            let transport = MockTransport([.failure(error)])
            do { _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: .init(apiKey: "test")); Issue.record("Expected failure") } catch {}
            #expect(await transport.captured().count == 1)
        }
    }

    @Test func unavailableFrontierStopsWithItsErrorAndNeverFallsBackAgain() async throws {
        let transport = MockTransport([
            .response(response([try tool("request_frontier", .object(["reason": .string("Complex harmony")]))])),
            .failure(.provider(status: 404, message: "The frontier model is unavailable to this account."))
        ])
        do { _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: .init(apiKey: "test")); Issue.record("Expected unavailable frontier") }
        catch let error as AgentError { if case .provider(let status, _) = error { #expect(status == 404) } else { Issue.record("Unexpected error") } }
        #expect(await transport.captured().count == 2)
    }

    @Test func modelChangesKeepTextHistoryAndDropOnlyOpaqueReasoning() async throws {
        let reasoning = JSONValue.object(["type": .string("reasoning"), "encrypted_content": .string("old-model-context")])
        let oldText = JSONValue.object(["role": .string("user"), "content": .string("Keep this musical preference")])
        for previousModel in [String?.none, .some("another-model"), .some("test-model")] {
            var context = conversation(); context.responseModel = previousModel; context.responseItems = [oldText, reasoning]
            let transport = MockTransport([.response(response([answer()]))])
            _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: context, selection: .init(), configuration: configuration)
            let requests = await transport.captured()
            let input = requests[0]["input"]?.arrayValue ?? []
            #expect(input.contains(oldText))
            #expect(input.contains(reasoning) == (previousModel == "test-model"))
        }
    }

    @Test func requestBudgetIsSharedAcrossAutomaticUpgrade() async throws {
        let transport = MockTransport([
            .response(response([try tool("request_frontier", .object(["reason": .string("Complex structure")]))])),
            .response(response([try tool("get_project", .object([:]), id: "read1")])),
            .response(response([try tool("get_project", .object([:]), id: "read2")]))
        ])
        let config = AgentConfiguration(apiKey: "test", maximumSteps: 3)
        do { _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config); Issue.record("Expected shared step limit") }
        catch let error as AgentError { if case .modelLimit = error {} else { Issue.record("Unexpected error") } }
        #expect(await transport.captured().count == 3)
    }

    @Test func tokenBudgetIncludesIncompleteEconomicalOutput() async throws {
        let incomplete = JSONValue.object(["status": .string("incomplete"), "incomplete_details": .object(["reason": .string("max_output_tokens")]), "usage": .object(["input_tokens": .number(20), "output_tokens": .number(63_000)]), "output": .array([])])
        let transport = MockTransport([.response(incomplete), .response(response([answer()], model: "gpt-6-luna"))])
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: .init(apiKey: "test"))
        #expect(result.inputTokens == 30)
        #expect(result.outputTokens == 63_005)
        let requests = await transport.captured()
        #expect(requests[1]["max_output_tokens"]?.doubleValue == 2_536)
    }

    @Test func incompleteOutputRetriesSmallerCallWithoutLosingCompletedDraft() async throws {
        let commands = try JSONValue.encode([ProjectCommand(op: .setTempo, value: 155)])
        let incomplete = JSONValue.object(["status": .string("incomplete"), "incomplete_details": .object(["reason": .string("max_output_tokens")]), "output": .array([try tool("apply_edits", .object(["commands": try .encode([ProjectCommand(op: .setTempo, value: 180)])]), id: "never_run")])])
        let transport = MockTransport([
            .response(response([try tool("apply_edits", .object(["commands": commands]))], model: "gpt-6-luna")),
            .response(incomplete),
            .response(response([answer()], model: "gpt-6-luna"))
        ])
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: .init(apiKey: "test"))
        #expect(result.song.tempo == 155)
        #expect(result.song.revision == 1)
        #expect(result.attemptedModels == ["gpt-6-luna"])
        let requests = await transport.captured()
        #expect(requests.allSatisfy { $0["max_output_tokens"]?.doubleValue == 4096 })
        #expect(requests[2]["input"]?.arrayValue?.contains { $0["role"]?.stringValue == "developer" && $0["content"]?.stringValue?.contains("Previously completed draft edits remain intact") == true } == true)
    }

    @Test func nullNoteIDsBecomeUniqueHostIDsInNestedTracksAndClips() throws {
        let existing = NoteEvent(pitch: 60)
        var nullNote = try JSONValue.encode(existing)
        if case .object(var fields) = nullNote { fields["id"] = .null; nullNote = .object(fields) }
        let originalTrack = Track(clips: [Clip(notes: [existing, existing])])
        var trackValue = try JSONValue.encode(originalTrack)
        if case .object(var fields) = trackValue, case .object(var clip) = fields["clips"]?.arrayValue?.first {
            clip["notes"] = .array([nullNote, nullNote]); fields["clips"] = .array([.object(clip)]); fields["parameters"] = .array([]); trackValue = .object(fields)
        }
        let commands = try AgentTools.commands(from: .object(["commands": .array([.object(["op": .string("addTrack"), "track": trackValue])])]))
        let notes = try #require(commands.first?.track?.clips.first?.notes)
        #expect(notes.count == 2)
        #expect(notes[0].id != notes[1].id)
        #expect(notes[0].id != existing.id)
        #expect(commands[0].track?.id == originalTrack.id)
        var song = Song(); try ProjectEditor.apply(commands, to: &song)
        #expect(song.tracks[0].clips[0].notes.count == 2)
    }

    @Test func editingANotePreservesItsExistingIdentityEvenWithNullPayloadID() throws {
        let note = NoteEvent(pitch: 60), clipID = UUID()
        let track = Track(clips: [Clip(id: clipID, notes: [note])])
        for useNull in [false, true] {
            var song = Song(); song.tracks = [track]
            var replacement = try JSONValue.encode(NoteEvent(id: note.id, pitch: 62))
            if useNull, case .object(var fields) = replacement { fields["id"] = .null; replacement = .object(fields) }
            let value = JSONValue.object(["op": .string("updateNote"), "clipID": .string(clipID.uuidString), "noteID": .string(note.id.uuidString), "note": replacement])
            let commands = try AgentTools.commands(from: .object(["commands": .array([value])]))
            try ProjectEditor.apply(commands, to: &song)
            #expect(song.tracks[0].clips[0].notes[0].id == note.id)
            #expect(song.tracks[0].clips[0].notes[0].pitch == 62)
        }
    }

    @Test func newNoteBatchLimitAndInvalidNotesRemainAtomic() throws {
        var note = try JSONValue.encode(NoteEvent(pitch: 60))
        if case .object(var fields) = note { fields["id"] = .null; note = .object(fields) }
        let clipID = UUID(), track = Track(clips: [Clip(id: UUID(), notes: [])])
        let tooMany = JSONValue.object(["op": .string("replaceNotes"), "clipID": .string(clipID.uuidString), "notes": .array(Array(repeating: note, count: 65))])
        #expect(throws: AgentError.self) { try AgentTools.commands(from: .object(["commands": .array([tooMany])])) }
        var song = Song(); song.tracks = [track]
        let before = song
        if case .object(var fields) = note { fields["pitch"] = .number(200); note = .object(fields) }
        let invalid = JSONValue.object(["op": .string("addNote"), "clipID": .string(track.clips[0].id.uuidString), "note": note])
        let commands = try AgentTools.commands(from: .object(["commands": .array([try .encode(ProjectCommand(op: .setTempo, value: 150)), invalid])]))
        #expect(throws: ProjectError.self) { try ProjectEditor.apply(commands, to: &song) }
        #expect(song == before)
    }
    @Test func everyToolUsesStrictClosedObjectSchemas() throws {
        func inspect(_ schema: JSONValue) throws {
            if schema["type"]?.stringValue == "object" {
                guard case .object(let properties) = schema["properties"] else { Issue.record("Object schema is missing properties"); return }
                #expect(schema["additionalProperties"] == .bool(false))
                let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                #expect(required == Set(properties.keys))
                for child in properties.values { try inspect(child) }
            }
            if let item = schema["items"] { try inspect(item) }
            for child in schema["anyOf"]?.arrayValue ?? [] { try inspect(child) }
        }
        #expect(AgentTools.definitions.count == 5)
        for tool in AgentTools.definitions {
            #expect(tool["strict"] == .bool(true))
            let parameters = try #require(tool["parameters"])
            try inspect(parameters)
        }
    }

    @Test func validEditsStayInDraftAndPreserveContinuation() async throws {
        let original = Song()
        let track = Track(clips: [Clip(notes: [NoteEvent(pitch: 60)])])
        var encoded = try JSONValue.encode(ProjectCommand(op: .addTrack, track: track))
        if case .object(var c) = encoded, case .object(var t) = c["track"] {
            t["parameters"] = .array([]); c["track"] = .object(t); encoded = .object(c)
        }
        let reasoning = JSONValue.object(["type": .string("reasoning"), "id": .string("rs_test"), "encrypted_content": .string("opaque")])
        let transport = MockTransport([.response(response([reasoning, try tool("apply_edits", .object(["commands": .array([encoded])]))])), .response(response([answer()]))])
        let result = try await MusicAgent(transport: transport).generate(song: original, conversation: conversation(), selection: .init(), configuration: configuration)
        #expect(original.tracks.isEmpty)
        #expect(result.song.tracks.count == 1)
        #expect(result.song.tracks[0].clips[0].notes[0].pitch == 60)
        #expect(result.inputTokens == 20)
        #expect(result.outputTokens == 10)
        #expect(result.responseItems.contains(reasoning))
        let requests = await transport.captured()
        #expect(requests.count == 2)
        #expect(requests[0]["store"] == .bool(false))
        #expect(requests[0]["parallel_tool_calls"] == .bool(false))
        #expect(requests[0]["tools"]?.arrayValue?.count == 5)
        #expect(requests[1]["input"]?.arrayValue?.contains { $0["type"]?.stringValue == "function_call_output" && $0["call_id"]?.stringValue == "call_1" } == true)
        let serialized = String(data: try JSONEncoder().encode(result.responseItems), encoding: .utf8)!
        #expect(!serialized.contains("test-key"))
    }

    @Test func invalidBatchIsAtomicAndCanBeRepaired() async throws {
        let invalid = try JSONValue.encode([ProjectCommand(op: .setTempo, value: 150), ProjectCommand(op: .setTempo, value: -1)])
        let valid = try JSONValue.encode([ProjectCommand(op: .setTempo, value: 160)])
        let transport = MockTransport([
            .response(response([try tool("apply_edits", .object(["commands": invalid]))])),
            .response(response([try tool("get_project", .object([:]), id: "read")])),
            .response(response([try tool("apply_edits", .object(["commands": valid]), id: "repair")])),
            .response(response([answer()]))
        ])
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: configuration)
        #expect(result.song.tempo == 160)
        #expect(result.song.revision == 1)
        let requests = await transport.captured()
        let readResult = requests[2]["input"]?.arrayValue?.first { $0["call_id"]?.stringValue == "read" && $0["type"]?.stringValue == "function_call_output" }
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data((readResult?["output"]?.stringValue ?? "{}").utf8))
        #expect(snapshot["tempo"]?.doubleValue == 140)
    }

    @Test func repeatedToolCallDoesNotDuplicateEdits() async throws {
        let commands = try JSONValue.encode([ProjectCommand(op: .setTempo, value: 155)])
        let call = try tool("apply_edits", .object(["commands": commands]))
        let transport = MockTransport([.response(response([call])), .response(response([call])), .response(response([answer()]))])
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: configuration)
        #expect(result.song.revision == 1)
    }

    @Test func timeoutCancelsAnInflightRequest() async throws {
        let transport = MockTransport([.wait])
        var config = configuration; config.timeout = 0.02
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
            Issue.record("Expected timeout")
        } catch let error as AgentError { if case .limit = error {} else { Issue.record("Unexpected error: \(error)") } }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func cancellationPropagatesWithoutRetry() async throws {
        let transport = MockTransport([.wait])
        let task = Task { try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: configuration) }
        defer { task.cancel() }
        // Wait for the request we mean to cancel, rather than assuming the
        // concurrent test runner starts it within a fixed 20 ms window.
        let deadline = ContinuousClock.now + .seconds(3)
        while await transport.captured().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(await transport.captured().count == 1)
    }

    @Test func transientProviderFailureRetries() async throws {
        let transport = MockTransport([.failure(.provider(status: 503, message: "Temporary")), .response(response([answer("Try a contrasting melody.")]))])
        _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: configuration)
        #expect(await transport.captured().count == 2)
    }

    @Test func authenticationFailureDoesNotRetry() async throws {
        let transport = MockTransport([.failure(.provider(status: 401, message: "Invalid key"))])
        do { _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: configuration); Issue.record("Expected authentication failure") }
        catch let error as AgentError { if case .provider(let status, _) = error { #expect(status == 401) } else { Issue.record("Unexpected error") } }
        #expect(await transport.captured().count == 1)
    }

    @Test func malformedNotesAreRejectedBeforeDraftApplication() throws {
        let track = Track(clips: [Clip(notes: [NoteEvent(pitch: 200, duration: -1)])])
        var encoded = try JSONValue.encode(ProjectCommand(op: .addTrack, track: track))
        if case .object(var command) = encoded, case .object(var t) = command["track"] {
            t["parameters"] = .array([]); command["track"] = .object(t); encoded = .object(command)
        }
        let commands = try AgentTools.commands(from: .object(["commands": .array([encoded])]))
        var draft = Song()
        #expect(throws: ProjectError.self) { try ProjectEditor.apply(commands, to: &draft) }
        #expect(draft.tracks.isEmpty)
        #expect(draft.revision == 0)
    }

    @Test func incompleteFinalResponseCannotReturnPreviouslyStagedEdits() async throws {
        let commands = try JSONValue.encode([ProjectCommand(op: .setTempo, value: 155)])
        let incomplete = JSONValue.object(["status": .string("incomplete"), "output": .array([answer("Done")])])
        let transport = MockTransport([.response(response([try tool("apply_edits", .object(["commands": commands]))])), .response(incomplete)])
        let original = Song()
        do {
            _ = try await MusicAgent(transport: transport).generate(song: original, conversation: conversation(), selection: .init(), configuration: configuration)
            Issue.record("Expected incomplete response failure")
        } catch let error as AgentError { if case .incomplete = error {} else { Issue.record("Unexpected error") } }
        #expect(original.tempo == 140)
    }

    @Test func aQuestionCanFinishWithoutMusicalChanges() async throws {
        let transport = MockTransport([.response(response([answer("The song is in C major.")]))])
        let original = Song()
        let result = try await MusicAgent(transport: transport).generate(song: original, conversation: conversation(), selection: .init(), configuration: configuration)
        #expect(result.song == original)
    }

    @Test func connectionCheckUsesAReadOnlyForcedTool() async throws {
        let transport = MockTransport([.response(response([try tool("connection_check", .object([:]))]))])
        try await MusicAgent(transport: transport).testConnection(configuration: configuration)
        let request = await transport.captured()[0]
        #expect(request["tool_choice"]?["name"]?.stringValue == "connection_check")
        #expect(request["tools"]?.arrayValue?.count == 1)
    }

    @Test func modelDefaultOmitsUnsupportedReasoningTuning() async throws {
        let transport = MockTransport([.response(response([answer()]))])
        var config = configuration; config.reasoningEffort = ""
        _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        let request = await transport.captured()[0]
        #expect(request["reasoning"] == nil)
    }

    @Test func streamDeltasNeverCompleteAResponse() throws {
        var decoder = ResponseEventDecoder()
        let eventLine = try decoder.accept(line: "event: response.function_call_arguments.delta")
        #expect(eventLine == nil)
        let dataLine = try decoder.accept(line: "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{}\"}")
        let delta = try #require(dataLine)
        let separator = try decoder.accept(line: "")
        #expect(separator == nil)
        #expect(try OpenAIResponsesClient.handle(delta, status: { _ in }) == nil)
        let complete = JSONValue.object(["type": .string("response.completed"), "response": response([answer()])])
        #expect(try OpenAIResponsesClient.handle(complete, status: { _ in })?["status"]?.stringValue == "completed")
        #expect(throws: AgentError.self) { try OpenAIResponsesClient.handle(.object(["type": .string("response.incomplete")]), status: { _ in }) }
    }
}

private actor InstrumentRequests {
    var values: [Set<String>] = []
    func record(_ ids: Set<String>) { values.append(ids) }
    func all() -> [Set<String>] { values }
}

struct InstrumentDependencyTests {
    private func addTrack(_ track: Track) throws -> JSONValue {
        var value = try JSONValue.encode(ProjectCommand(op: .addTrack, track: track))
        if case .object(var command) = value, case .object(var fields) = command["track"] {
            fields["parameters"] = .array([]); command["track"] = .object(fields); value = .object(command)
        }
        return .object(["commands": .array([value])])
    }

    @Test func dependencyFailureStopsBeforeAnotherRequestOrUpgrade() async throws {
        let track = Track(instrumentID: "sampled.piano", clips: [Clip(notes: [NoteEvent(pitch: 60)])])
        let transport = MockTransport([
            .response(response([try tool("apply_edits", addTrack(track))], model: "gpt-6-luna")),
            .response(response([answer()], model: "gpt-6-astra"))
        ])
        let original = Song()
        let requests = InstrumentRequests()
        let budget = GenerationBudget()
        var config = AgentConfiguration(apiKey: "test", runBudget: budget)
        config.instruments = InstrumentDependencies(installed: { [] }, ensure: { ids in
            await requests.record(ids)
            throw InstrumentDependencyError("Download canceled")
        })
        await #expect(throws: InstrumentDependencyError.self) {
            _ = try await MusicAgent(transport: transport).generate(song: original, conversation: conversation(), selection: .init(), configuration: config)
        }
        #expect(original.tracks.isEmpty && original.revision == 0)
        #expect(await requests.all() == [Set(["sampled.piano"])])
        #expect(await transport.captured().count == 1)
        let usage = await budget.snapshot()
        #expect(usage.requests == 1 && usage.retries == 0 && usage.routingReason == nil)
    }

    @Test func libraryCatalogDistinguishesBuiltInAndDownloadedSounds() async throws {
        let transport = MockTransport([
            .response(response([try tool("get_instruments", .object([:]))])),
            .response(response([answer("These are the available sounds.")]))
        ])
        var config = configuration
        config.instruments = InstrumentDependencies(installed: { ["sampled.piano"] }, ensure: { _ in
            throw InstrumentDependencyError("Inspection must not download")
        })
        _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        let captured = await transport.captured()
        let outputs = captured[1]["input"]?.arrayValue?.filter { $0["type"]?.stringValue == "function_call_output" } ?? []
        let json = try #require(outputs.first?["output"]?.stringValue)
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let presets = try #require(result["instruments"]?.arrayValue)
        #expect(presets.first { $0["id"]?.stringValue == "synth.lead" }?["installed"] == .bool(true))
        #expect(presets.first { $0["id"]?.stringValue == "sampled.piano" }?["installed"] == .bool(true))
        #expect(presets.first { $0["id"]?.stringValue == "sampled.guitar" }?["installed"] == .bool(false))
        #expect(presets.first { $0["id"]?.stringValue == "sampled.piano" }?["source"]?.stringValue == "freepats")
    }

    @Test func ordinaryAnswerDoesNotDownloadExistingMissingInstruments() async throws {
        let transport = MockTransport([.response(response([answer("The song has a piano track.")]))])
        var song = Song(); song.tracks = [Track(instrumentID: "sampled.piano")]
        var config = configuration
        config.instruments = InstrumentDependencies(installed: { [] }, ensure: { _ in
            throw InstrumentDependencyError("Questions must not download")
        })
        let result = try await MusicAgent(transport: transport).generate(song: song, conversation: conversation(), selection: .init(), configuration: config)
        #expect(result.song == song)
    }

    @Test func agentWatchdogHonorsDependencyPauseAndSharedBudget() async throws {
        let track = Track(instrumentID: "sampled.piano", clips: [Clip(notes: [NoteEvent(pitch: 60)])])
        let transport = MockTransport([
            .response(response([try tool("apply_edits", addTrack(track))])),
            .response(response([answer()]))
        ])
        let clock = MusicAgentTestClock()
        let budget = GenerationBudget(timeout: 0.1, now: { clock.now() })
        let requests = InstrumentRequests()
        var config = configuration; config.runBudget = budget
        config.instruments = InstrumentDependencies(installed: { ["sampled.piano"] }, ensure: { ids in
            await requests.record(ids)
            try await budget.withDependencyWait {
                clock.advance(1)
                try await Task.sleep(for: .milliseconds(150))
            }
        })
        let result = try await MusicAgent(transport: transport).generate(song: Song(), conversation: conversation(), selection: .init(), configuration: config)
        #expect(result.song.tracks.count == 1)
        #expect(result.runID == budget.runID)
        #expect(await budget.snapshot().requests == 2)
    }
}
