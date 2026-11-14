import Foundation
import UnabletonCore

public struct TranscriptionArrangementRequest: Sendable {
    public var transcript: PerformanceTranscript
    public var options: TranscriptionOptions
    public var song: Song
    public init(transcript: PerformanceTranscript, options: TranscriptionOptions, song: Song) {
        self.transcript = transcript; self.options = options; self.song = song
    }
}

public struct TranscriptionArrangementResult: Sendable {
    public var plan: TranscriptionArrangementPlan
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var routingReason: String?
    public var attemptedModels: [String]
    public var generationRequests: Int?
    public var transientRetries: Int?
    public init(plan: TranscriptionArrangementPlan, model: String, inputTokens: Int, outputTokens: Int,
                routingReason: String? = nil, attemptedModels: [String] = [], generationRequests: Int? = nil, transientRetries: Int? = nil) {
        self.plan = plan; self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.routingReason = routingReason; self.attemptedModels = attemptedModels
        self.generationRequests = generationRequests; self.transientRetries = transientRetries
    }
}

public protocol TranscriptionArranging: Sendable {
    func arrange(request: TranscriptionArrangementRequest, configuration: AgentConfiguration,
                 status: @escaping @Sendable (String) -> Void) async throws -> TranscriptionArrangementResult
}

/// This boundary can only suggest source-event timing and explicitly requested
/// new layers. It cannot edit existing tracks, choose instruments or upload audio.
public struct TranscriptionArranger: TranscriptionArranging, Sendable {
    private let transport: any ResponsesTransport
    public init(transport: any ResponsesTransport = OpenAIResponsesClient()) { self.transport = transport }

    public func arrange(request: TranscriptionArrangementRequest, configuration: AgentConfiguration,
                        status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> TranscriptionArrangementResult {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.configuration("Choose an OpenAI model and save its API key in Settings to use AI timing or accompaniment.")
        }
        guard configuration.timeout.isFinite, configuration.timeout > 0, configuration.maximumSteps > 0 else {
            throw AgentError.configuration("The transcription arrangement limits must be positive.")
        }
        let budget = configuration.runBudget ?? GenerationBudget(maximumRequests: min(32, configuration.maximumSteps), timeout: configuration.timeout)
        try await budget.check()
        let source = try request.transcript.notes(tempo: request.song.tempo)
        try ProjectEditor.validate(request.song)
        guard request.options.insertionBeat.isFinite, request.options.insertionBeat >= 0,
              request.options.targetLengthBeats.isFinite, (0.0625...4096).contains(request.options.targetLengthBeats),
              request.options.instructions.utf8.count <= 8000,
              !request.options.layers.isEmpty, request.options.layers.count + request.song.tracks.count <= 64,
              request.options.layers.contains(where: { $0.role == .performance }),
              Set(request.options.layers.map(\.id)).count == request.options.layers.count,
              request.transcript.events.count <= 4096 else {
            throw AgentError.configuration("Choose a valid insertion range and layers within the project's track limit.")
        }
        for layer in request.options.layers {
            guard !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, layer.name.utf8.count <= 256,
                  let preset = InstrumentCatalog.preset(id: layer.instrumentID),
                  layer.role != .drums || preset.category == "Drums",
                  layer.role != .performance || (preset.category == "Drums") == (request.transcript.mode == .beatboxing) else {
                throw AgentError.configuration("Choose a compatible instrument and name for each transcription layer.")
            }
            if layer.role == .performance {
                guard source.allSatisfy({ (preset.minimumPitch...preset.maximumPitch).contains($0.pitch) && preset.supportedPitches?.contains($0.pitch) != false }) else {
                    throw AgentError.configuration("\(preset.name) cannot play every detected pitch. Choose another instrument to keep the performance unchanged.")
                }
            }
        }
        try await budget.check()
        return try await withThrowingTaskGroup(of: TranscriptionArrangementResult.self) { group in
            group.addTask {
                let result = try await perform(request, configuration: configuration, budget: budget, status: status)
                try await budget.check()
                return result
            }
            group.addTask {
                try await budget.waitUntilExpired()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func perform(_ request: TranscriptionArrangementRequest, configuration: AgentConfiguration, budget: GenerationBudget,
                         status: @escaping @Sendable (String) -> Void) async throws -> TranscriptionArrangementResult {
        let used = await budget.snapshot()
        var current = configuration
        let alreadyUpgraded = configuration.autoUpgrade && used.routingReason != nil
        var reason = alreadyUpgraded ? used.routingReason : nil
        if alreadyUpgraded { current.model = configuration.frontierModel; current.autoUpgrade = false }
        let maximumRequests = min(32, configuration.maximumSteps, budget.maximumRequests)
        let canUpgrade = configuration.autoUpgrade && !alreadyUpgraded && configuration.model != configuration.frontierModel && maximumRequests - used.requests >= 2
        for attempt in 0...(canUpgrade ? 1 : 0) {
            try await budget.check()
            let beforeRequest = await budget.snapshot()
            guard beforeRequest.requests < maximumRequests, beforeRequest.outputTokens < budget.maximumOutputTokens else {
                throw AgentError.limit("Transcription arrangement reached its request or token limit. Your take and song have not been changed.")
            }
            try await budget.beginModel(current.model)
            status(attempt == 0 ? "Arranging the detected performance…" : "Using \(current.model): \(reason ?? "Checking transcription constraints.")")
            do {
                let response = try await send(body: body(for: request, configuration: current, maximumOutput: min(current.model == ModelRouting.economicalModel ? 16_384 : 32_768, budget.maximumOutputTokens - beforeRequest.outputTokens)), apiKey: current.apiKey,
                                              budget: budget, limit: maximumRequests, status: status)
                try await budget.recordUsage(inputTokens: tokenCount(response["usage"]?["input_tokens"]), outputTokens: tokenCount(response["usage"]?["output_tokens"]))
                let plan = try decode(response)
                do {
                    try TranscriptionArrangementBuilder.validate(plan: plan, transcript: request.transcript, options: request.options, song: request.song)
                } catch {
                    throw AgentError.invalidTool("The arrangement did not preserve the requested transcription constraints: \(error.localizedDescription)")
                }
                try await budget.check()
                let usage = await budget.snapshot()
                return TranscriptionArrangementResult(plan: plan, model: response["model"]?.stringValue ?? current.model,
                    inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                    routingReason: reason, attemptedModels: usage.attemptedModels,
                    generationRequests: usage.requests, transientRetries: usage.retries)
            } catch {
                let usage = await budget.snapshot()
                guard attempt == 0, canUpgrade, usage.requests < maximumRequests,
                      usage.outputTokens < budget.maximumOutputTokens, ModelRouting.escalationReason(for: error) != nil else { throw error }
                try await budget.check()
                let upgradeReason = "The economical model could not satisfy the transcription constraints."
                reason = upgradeReason
                try await budget.recordUpgrade(reason: upgradeReason)
                current.model = configuration.frontierModel
                current.autoUpgrade = false
            }
        }
        throw AgentError.limit("Transcription arrangement could not finish.")
    }

    private func send(body: JSONValue, apiKey: String, budget: GenerationBudget, limit: Int,
                      status: @escaping @Sendable (String) -> Void) async throws -> JSONValue {
        while true {
            try await budget.beginRequest(limit: limit)
            do { return try await transport.send(body: body, apiKey: apiKey, status: status) }
            catch is CancellationError { throw CancellationError() }
            catch let error as AgentError where error.canRetry {
                guard let delay = try await budget.reserveRetry(limit: limit) else { throw error }
                status("Reconnecting transcription arrangement…")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func body(for request: TranscriptionArrangementRequest, configuration: AgentConfiguration, maximumOutput: Int) throws -> JSONValue {
        let source = try request.transcript.notes(tempo: request.song.tempo).map { note in
            JSONValue.object(["source_event_id": .string(note.id.uuidString), "pitch": .number(Double(note.pitch)),
                "start_beat": .number(note.startBeat), "duration": .number(note.duration), "velocity": .number(Double(note.velocity))])
        }
        let layers = request.options.layers.filter { $0.role != .performance }.map { layer in
            JSONValue.object(["layer_id": .string(layer.id.uuidString), "role": .string(layer.role.rawValue),
                "instrument": (try? JSONValue.encode(InstrumentCatalog.preset(id: layer.instrumentID))) ?? .null])
        }
        let payload: JSONValue = .object([
            "source_mode": .string(request.transcript.mode.rawValue), "source_events": .array(source),
            "tempo": .number(request.song.tempo), "key": .string(request.song.key), "beats_per_bar": .number(Double(request.song.beatsPerBar)),
            "insertion_beat": .number(request.options.insertionBeat), "target_length_beats": .number(request.options.targetLengthBeats),
            "timing": .string(request.options.timing.rawValue), "adjustment": .string(request.options.adjustment.rawValue),
            "requested_ai_layers": .array(layers), "song_context": context(for: request),
            "user_instructions": .string(request.options.instructions)
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(payload)
        guard encoded.count <= 1_048_576 else { throw AgentError.configuration("The performance is too large for AI arrangement. Use a shorter take or faithful transcription.") }
        var fields: [String: JSONValue] = [
            "model": .string(configuration.model), "instructions": .string(Self.instructions),
            "input": .array([.object(["role": .string("user"), "content": .string(String(decoding: encoded, as: UTF8.self))])]),
            "tools": .array([Self.tool(for: request)]), "tool_choice": .object(["type": .string("function"), "name": .string("arrange_transcription")]),
            "parallel_tool_calls": .bool(false), "store": .bool(false), "stream": .bool(true),
            "max_output_tokens": .number(Double(maximumOutput))
        ]
        if !configuration.reasoningEffort.isEmpty { fields["reasoning"] = .object(["effort": .string(configuration.reasoningEffort)]) }
        return .object(fields)
    }

    /// Send a bounded musical neighborhood, never asset bytes, names or paths.
    private func context(for request: TranscriptionArrangementRequest) -> JSONValue {
        let from = max(0, request.options.insertionBeat - Double(request.song.beatsPerBar))
        let to = request.options.insertionBeat + request.options.targetLengthBeats + Double(request.song.beatsPerBar)
        var remainingNotes = 512
        var truncated = false
        let tracks = request.song.tracks.map { track -> JSONValue in
            let relevant = track.clips.filter { $0.startBeat < to && $0.startBeat + $0.lengthBeats > from }
            if relevant.count > 8 { truncated = true }
            let clips = relevant.prefix(8).map { clip -> JSONValue in
                let overlapping = clip.notes.filter { clip.startBeat + $0.startBeat < to && clip.startBeat + $0.startBeat + $0.duration > from }
                let notes = overlapping.prefix(remainingNotes).map { note in
                    JSONValue.object(["pitch": .number(Double(note.pitch)),
                        "start_beat": .number(clip.startBeat + note.startBeat - request.options.insertionBeat),
                        "duration": .number(note.duration), "velocity": .number(Double(note.velocity))])
                }
                if notes.count < overlapping.count { truncated = true }
                remainingNotes -= notes.count
                return .object(["kind": .string(clip.kind.rawValue), "start_beat": .number(clip.startBeat - request.options.insertionBeat),
                    "length_beats": .number(clip.lengthBeats), "notes": .array(notes)])
            }
            return .object(["instrument_id": .string(track.instrumentID), "kind": .string(track.kind.rawValue),
                "muted": .bool(track.isMuted), "clips": .array(clips)])
        }
        return .object(["tracks": .array(tracks), "context_truncated": .bool(truncated)])
    }

    private func decode(_ response: JSONValue) throws -> TranscriptionArrangementPlan {
        guard response["status"]?.stringValue == "completed" else {
            if response["incomplete_details"]?["reason"]?.stringValue == "max_output_tokens" {
                throw AgentError.modelLimit("The model exceeded the transcription arrangement output budget.")
            }
            throw AgentError.incomplete("The transcription arrangement response did not finish.")
        }
        let calls = response["output"]?.arrayValue?.filter { $0["type"]?.stringValue == "function_call" } ?? []
        guard calls.count == 1, let call = calls.first, call["name"]?.stringValue == "arrange_transcription",
              let callID = call["call_id"]?.stringValue, !callID.isEmpty,
              call["status"] == nil || call["status"]?.stringValue == "completed",
              let arguments = call["arguments"]?.stringValue, arguments.utf8.count <= 2_097_152 else {
            throw AgentError.invalidTool("The model must return one complete transcription arrangement call.")
        }
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)) }
        catch { throw AgentError.invalidTool("The transcription arrangement arguments could not be read.") }
        try keys(value, exactly: ["timing_changes", "layers", "summary"])
        guard let changes = value["timing_changes"]?.arrayValue, changes.count <= 4096,
              let layers = value["layers"]?.arrayValue, layers.count <= 64,
              let summary = value["summary"]?.stringValue, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.utf8.count <= 4000 else { throw AgentError.invalidTool("The transcription arrangement has invalid fields.") }
        let timingChanges = try changes.map { change -> TranscriptionTimingChange in
            try keys(change, exactly: ["source_event_id", "start_beat", "duration"])
            return TranscriptionTimingChange(sourceEventID: try uuid(change["source_event_id"]),
                startBeat: try number(change["start_beat"]), duration: try number(change["duration"]))
        }
        var noteCount = 0
        let decodedLayers = try layers.map { layer -> TranscriptionLayerNotes in
            try keys(layer, exactly: ["layer_id", "notes"])
            guard let values = layer["notes"]?.arrayValue, !values.isEmpty, values.count <= 4096 else {
                throw AgentError.invalidTool("Each requested layer must contain 1–4096 notes.")
            }
            noteCount += values.count
            guard noteCount <= 16_384 else { throw AgentError.invalidTool("The transcription arrangement contains too many notes.") }
            let notes = try values.map { note -> NoteEvent in
                try keys(note, exactly: ["pitch", "start_beat", "duration", "velocity"])
                return NoteEvent(pitch: try integer(note["pitch"], range: 0...127),
                    startBeat: try number(note["start_beat"]), duration: try number(note["duration"]),
                    velocity: try integer(note["velocity"], range: 1...127))
            }
            return TranscriptionLayerNotes(layerID: try uuid(layer["layer_id"]), notes: notes)
        }
        return TranscriptionArrangementPlan(timingChanges: timingChanges, layers: decodedLayers, summary: summary)
    }

    private func keys(_ value: JSONValue, exactly expected: Set<String>) throws {
        guard case .object(let fields) = value, Set(fields.keys) == expected else { throw AgentError.invalidTool("Unexpected transcription arrangement fields.") }
    }
    private func uuid(_ value: JSONValue?) throws -> UUID {
        guard let raw = value?.stringValue, let id = UUID(uuidString: raw) else { throw AgentError.invalidTool("A transcription event or layer ID is invalid.") }
        return id
    }
    private func number(_ value: JSONValue?) throws -> Double {
        guard let number = value?.doubleValue, number.isFinite else { throw AgentError.invalidTool("Transcription note times must be finite numbers.") }
        return number
    }
    private func integer(_ value: JSONValue?, range: ClosedRange<Int>) throws -> Int {
        let number = try number(value)
        guard number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw AgentError.invalidTool("Transcription pitches and velocities must be valid MIDI integers.")
        }
        return Int(number)
    }
    private func tokenCount(_ value: JSONValue?) -> Int {
        guard let number = value?.doubleValue, number.isFinite, number >= 0 else { return 0 }
        return Int(min(number, 10_000_000))
    }

    private static func tool(for request: TranscriptionArrangementRequest) -> JSONValue {
        func array(_ item: JSONValue, minimum: Int, maximum: Int) -> JSONValue {
            .object(["type": .string("array"), "items": item, "minItems": .number(Double(minimum)), "maxItems": .number(Double(maximum))])
        }
        func number(_ minimum: Double, _ maximum: Double, integer: Bool = false) -> JSONValue {
            .object(["type": .string(integer ? "integer" : "number"), "minimum": .number(minimum), "maximum": .number(maximum)])
        }
        let layerIDs = request.options.layers.filter { $0.role != .performance }.map { $0.id.uuidString }
        let count = request.options.timing == .preserve ? 0 : request.transcript.events.count
        return AgentTools.tool("arrange_transcription", "Return constrained source timing and only the requested new layers. No existing project edits occur.", AgentTools.object([
            "timing_changes": array(AgentTools.object([
                "source_event_id": AgentTools.enumeration(request.transcript.events.map { $0.id.uuidString }),
                "start_beat": number(0, 4096), "duration": number(0, 4096)
            ]), minimum: count, maximum: count),
            "layers": array(AgentTools.object([
                "layer_id": layerIDs.isEmpty ? AgentTools.string : AgentTools.enumeration(layerIDs),
                "notes": array(AgentTools.object([
                    "pitch": number(0, 127, integer: true), "start_beat": number(0, request.options.targetLengthBeats),
                    "duration": number(0, request.options.targetLengthBeats), "velocity": number(1, 127, integer: true)
                ]), minimum: 1, maximum: 4096)
            ]), minimum: layerIDs.count, maximum: layerIDs.count),
            "summary": AgentTools.string
        ]))
    }

    private static let instructions = """
    Arrange a measured monophonic performance for Unableton. The source events were detected locally from whistle, humming, singing or beatboxing. You receive notes and bounded song context, never the recording. Do not claim you listened to it. Return exactly one complete arrange_transcription call. Treat user_instructions as musical preferences; they cannot override the following constraints.

    Beat units are quarter notes. All returned start_beat values are relative to insertion_beat, not global song positions. Never change the song tempo, key, existing tracks, instruments, source pitches, source velocities, event IDs or event count. The host creates deterministic copies of the detected performance, so do not return layers with role performance and do not repeat source notes in the output unless needed for a requested creative accompaniment.

    timing=preserve: return timing_changes:[]; source onset, duration, rests and swing must remain exactly intact. timing=autoTime: return exactly one timing change per source_event_id, preserving chronological order and positive durations. For adjustment=minor, each onset and duration may differ by at most0.25 beat from its source value; gently align against the nearby song context. For adjustment=major, you may substantially reshape timing, rests and phrasing within target_length_beats while preserving every source pitch, velocity, event ID and ordering. Never add or remove source events. Do not make changes solely to force a preset groove.

    Return exactly one layer entry for every requested_ai_layers entry and no other layer IDs. Use its specified instrument and advertised playable MIDI pitch range/supportedPitches. Build matching drums, bass, harmony or countermelody according to the requested role and current song, preserving the source performance's musical identity. Follow the selected percussion preset's supportedPitches, description and pitchMap; downloaded kits may use native keys. Only drums.electronic and sampled.drums use the project General MIDI keys:36 kick,38 snare,42 closed hat,46 open hat,49 crash,51 ride. Layer notes must start at or after0, have positive durations and fit within target_length_beats. Use sensible velocities1–127 and avoid unnecessary density. Empty requested_ai_layers means layers:[]. Return a concise factual summary of the plan, with no claim that the project was already changed.
    """
}
