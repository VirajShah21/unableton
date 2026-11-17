import Foundation
import UnabletonCore
import UnabletonAI
import UnabletonAudio

/// One immutable chat scope and one draft-asset registry per submitted prompt.
/// The provider cache is shared across attempts; paths never enter model output.
actor SongReferenceRuntime {
    let attachments: [SongAttachment]
    let sources: [UUID: URL]
    let directory: URL
    let budget: GenerationBudget
    let processor: @Sendable () async throws -> ReferenceProcessing
    let inspector: any ReferenceAudioInspecting
    let update: @Sendable (UUID, JSONValue?, MIDIImport?) async throws -> Void
    let updateReconstruction: @Sendable (UUID, ReferenceReconstruction) async throws -> Void
    let fittingResources: @Sendable () async throws -> InstrumentResources
    let status: @Sendable (UUID, String) -> Void
    let lease: ProjectBlobLease?
    let allowsAudioInspection: Bool
    let allowsVocalNoteConversion: Bool
    var analyses: [UUID: JSONValue] = [:]
    var scores: [UUID: MIDIImport] = [:]
    var reconstructions: [UUID: ReferenceReconstruction] = [:]
    var reconstructionSoundFits: [String: ReferenceSoundFit] = [:]
    var heldFittingResources: InstrumentResources?
    var stems: [UUID: ReferenceSeparation] = [:]
    var derived: [UUID: URL] = [:]
    var derivations: [String: (AudioAsset, URL)] = [:]
    var processed = Set<UUID>()
    var inspections = 0
    var cachedProcessor: ReferenceProcessing?

    init(attachments: [SongAttachment], sources: [UUID: URL], directory: URL, budget: GenerationBudget,
         processor: @escaping @Sendable () async throws -> ReferenceProcessing,
         inspector: any ReferenceAudioInspecting, lease: ProjectBlobLease?, allowsAudioInspection: Bool = false, vocalNotesUserPrompt: String = "",
         update: @escaping @Sendable (UUID, JSONValue?, MIDIImport?) async throws -> Void,
         updateReconstruction: @escaping @Sendable (UUID, ReferenceReconstruction) async throws -> Void = { _, _ in },
         fittingResources: @escaping @Sendable () async throws -> InstrumentResources = { .empty },
         status: @escaping @Sendable (UUID, String) -> Void) {
        self.attachments = attachments; self.sources = sources; self.directory = directory; self.budget = budget
        self.processor = processor; self.inspector = inspector; self.lease = lease; self.update = update; self.status = status
        self.allowsAudioInspection = allowsAudioInspection
        let allowsVocalNoteConversion = ReferenceVocalNotesPolicy.allowsConversion(userPrompt: vocalNotesUserPrompt)
        self.allowsVocalNoteConversion = allowsVocalNoteConversion
        self.updateReconstruction = updateReconstruction
        self.fittingResources = fittingResources
        for item in attachments {
            if item.analysis?["analysis_engine"]?.stringValue == "local-rhythm-v1" { analyses[item.id] = item.analysis }
            // Old scores lack trusted stem provenance and must be re-extracted.
            if let midi = item.midi, midi.parts.allSatisfy({ $0.referenceStem != nil }) {
                let retained = midi.parts.filter { allowsVocalNoteConversion || $0.referenceStem != "vocals" }
                if !retained.isEmpty, !allowsVocalNoteConversion || retained.contains(where: { $0.referenceStem == "vocals" }) {
                    var safe = midi; safe.parts = retained; scores[item.id] = safe
                }
            }
            if item.reconstruction?.profile == ReferenceReconstruction.currentProfile { reconstructions[item.id] = item.reconstruction }
        }
    }
    nonisolated func tools() -> ReferenceTools {
        ReferenceTools(attachments: attachments, allowsAudioInspection: allowsAudioInspection, allowsVocalNoteConversion: allowsVocalNoteConversion, execute: { name, arguments, song in
            try await self.execute(name, arguments: arguments, song: song)
        }, assets: { song in await self.assets(for: song) })
    }
    func assets(for song: Song) -> [UUID: URL] {
        let ids = Set(song.assets.map(\.id)); return derived.filter { ids.contains($0.key) }
    }
    func execute(_ name: String, arguments: JSONValue, song: Song) async throws -> ReferenceToolResult {
        try await budget.check()
        guard let raw = arguments["attachment_id"]?.stringValue, let id = UUID(uuidString: raw),
              let attachment = attachments.first(where: { $0.id == id }), let source = sources[id] else {
            throw AgentError.invalidTool("Choose an attachment ID from the current chat manifest.")
        }
        do {
            switch name {
            case "inspect_reference": return try await inspect(attachment, source: source, arguments: arguments)
            case "inspect_reference_audio": return try await inspectAudio(attachment, source: source, arguments: arguments)
            case "insert_reference_notes": return try await insertNotes(attachment, source: source, arguments: arguments, song: song)
            case "insert_reference_audio": return try await insertAudio(attachment, source: source, arguments: arguments, song: song)
            case "reconstruct_reference": return try await reconstruct(attachment, source: source, arguments: arguments, song: song)
            default: throw AgentError.invalidTool("Unknown reference operation.")
            }
        } catch is CancellationError { status(id, "Processing canceled"); throw CancellationError() }
        catch let error as AgentError { throw error }
        catch let error as ReferenceProcessingFailure { status(id, "Processing failed · Use processing actions to retry"); throw error }
        catch { status(id, "Processing failed · \(error.localizedDescription)"); throw ReferenceProcessingFailure("Couldn’t process the attached song: \(error.localizedDescription). The arrangement was not changed.") }
    }
    func inspect(_ attachment: SongAttachment, source: URL, arguments: JSONValue) async throws -> ReferenceToolResult {
        let id = attachment.id
        switch arguments["detail"]?.stringValue {
        case "metadata":
            return ReferenceToolResult(output: .object(["attachment_id": .string(id.uuidString), "file_name": .string(attachment.fileName),
                "duration_seconds": .number(attachment.duration), "source_is_audio": .bool(true), "analysis_available": .bool(analyses[id] != nil), "midi_available": .bool(scores[id] != nil)]))
        case "analysis":
            if let analysis = analyses[id] { return ReferenceToolResult(output: analysis) }
            try reserve(id); status(id, "Measuring rhythm locally…")
            let rhythm = try await referenceWork { try ReferenceAudioProcessor.analyze(url: source) }
            let result = JSONValue.object(["analysis_engine": .string("local-rhythm-v1"), "rhythm_estimates": try .encode(rhythm),
                "note": .string("Local timing and energy measurements only, not instrument identification or listening. Tempo/beat/drop candidates are estimates, not accuracy probabilities.")])
            try await update(id, result, nil); analyses[id] = result; status(id, "Analysis ready")
            return ReferenceToolResult(output: result)
        case "stems":
            let separated = try await separation(attachment, source: source)
            return ReferenceToolResult(output: try stemSummary(separated, score: scores[id]))
        case "midi":
            let score = try await midi(attachment, source: source)
            return ReferenceToolResult(output: try stemSummary(stems[id], score: score))
        case "reconstruction":
            let (start, end) = try reconstructionRange(arguments, attachment: attachment)
            let score = try await reconstruction(attachment, source: source, start: start, end: end)
            let fits = try await reconstructionFits(score, attachment: attachment)
            return ReferenceToolResult(output: try reconstructionSummary(score, fits: fits))
        case "notes":
            guard let score = scores[id] else { throw AgentError.invalidTool("Use detail=midi to transcribe melodic stems locally before reading note pages.") }
            guard let partID = arguments["part_id"]?.stringValue else { return ReferenceToolResult(output: try stemSummary(stems[id], score: score)) }
            guard let part = score.parts.first(where: { $0.id == partID }) else { throw AgentError.invalidTool("Choose a returned MIDI part_id.") }
            let start = try integer(arguments, "start_index", default: 0, range: 0...part.notes.count)
            let count = try integer(arguments, "count", default: 64, range: 1...256)
            return ReferenceToolResult(output: .object(["part_id": .string(part.id), "total_notes": .number(Double(part.notes.count)),
                "start_index": .number(Double(start)), "notes": try .encode(Array(part.notes.dropFirst(start).prefix(count)))]))
        default: throw AgentError.invalidTool("Choose metadata, analysis, stems, midi, notes or reconstruction.")
        }
    }
    func separation(_ attachment: SongAttachment, source: URL) async throws -> ReferenceSeparation {
        if let cached = stems[attachment.id] { return cached }
        try reserve(attachment.id); status(attachment.id, "Separating stems locally with Demucs…")
        let processing = try await processingSession()
        let result = try await processing.separate(source: source, sha256: attachment.sha256, budget: budget)
        // Inspect every audio header before admitting provider data to the graph.
        do {
            try await referenceWork {
                for item in result.audio {
                    let metadata = try ReferenceAudioProcessor.inspectDerived(url: item.url)
                    guard abs(metadata.duration - attachment.duration) <= 1 else { throw ReferenceProcessingFailure("Separated audio does not align with the source duration. The arrangement was not changed.") }
                }
            }
        } catch {
            if !(error is CancellationError) { try await processing.rejectSeparation(sha256: attachment.sha256) }
            throw error
        }
        stems[attachment.id] = result; status(attachment.id, "Stems ready")
        return result
    }
    func midi(_ attachment: SongAttachment, source: URL) async throws -> MIDIImport {
        if let score = scores[attachment.id] { return score }
        _ = try await separation(attachment, source: source)
        status(attachment.id, "Transcribing melodic stems locally with Basic Pitch…")
        let processing = try await processingSession()
        let artifacts = try await processing.transcribe(source: source, sha256: attachment.sha256, includeVocals: allowsVocalNoteConversion, budget: budget)
        guard !artifacts.isEmpty else { throw ReferenceProcessingFailure("Basic Pitch returned no editable MIDI. Original/stem audio remains available; no notes were invented.") }
        let score: MIDIImport
        let includeVocals = allowsVocalNoteConversion
        do {
            score = try await referenceWork {
                var parts: [MIDIImportedPart] = [], warnings: [String] = [], duration = 0.0, tempo = 120.0
                for (index, artifact) in artifacts.enumerated() {
                    guard ["bass", "other"].contains(artifact.name) || (includeVocals && artifact.name == "vocals") else {
                        throw ReferenceProcessingFailure("The MIDI source stem is not authorized for instrument conversion.")
                    }
                    let value = try MIDIImporter.parse(Data(contentsOf: artifact.url), maximumDuration: min(600, attachment.duration + 0.001))
                    if index == 0 { tempo = value.initialTempo }
                    duration = max(duration, value.duration); warnings += value.warnings
                    for var part in value.parts {
                        part.referenceStem = artifact.name
                        part.id = "\(artifact.name):\(part.id)"
                        part.name = "\(artifact.name) · \(part.name)"
                        while part.name.utf8.count > 512 { part.name.removeLast() }
                        parts.append(part)
                    }
                }
                let combined = MIDIImport(parts: parts, duration: duration, initialTempo: tempo, warnings: Array(warnings.prefix(16)))
                try combined.validate(); return combined
            }
        } catch {
            if !(error is CancellationError) { try await processing.rejectTranscription(sha256: attachment.sha256) }
            throw error
        }
        try await update(attachment.id, nil, score); scores[attachment.id] = score
        return score
    }
    func stemSummary(_ separated: ReferenceSeparation?, score: MIDIImport?) throws -> JSONValue {
        .object(["model": .string(separated?.model ?? "saved-midi"), "audio_stems": .array((separated?.audio ?? []).map { .string($0.name) }),
            "midi_available": .bool(score != nil), "vocal_note_conversion_authorized": .bool(allowsVocalNoteConversion), "midi_encoding_tempo": score.map { .number($0.initialTempo) } ?? .null,
            "warnings": try .encode(score?.warnings ?? ["MIDI has not been requested. Use detail=midi for local transcription when editable notes are needed."]),
            "parts": .array((score?.parts ?? []).map { part in
                .object(["part_id": .string(part.id), "name": .string(part.name), "is_percussion": .bool(part.isPercussion), "source_stem": part.referenceStem.map(JSONValue.string) ?? .null,
                    "program": .number(Double(part.program)), "note_count": .number(Double(part.notes.count)),
                    "minimum_pitch": .number(Double(part.notes.map(\.pitch).min() ?? 0)), "maximum_pitch": .number(Double(part.notes.map(\.pitch).max() ?? 0))])
            }), "note": .string("Best-effort local stems and measured MIDI. MIDI encoding tempo is not detected source BPM; use local rhythm estimates for that. Drums can remain original audio; Basic Pitch does not classify drums. The other stem may contain multiple instruments.")])
    }
    func inspectAudio(_ attachment: SongAttachment, source: URL, arguments: JSONValue) async throws -> ReferenceToolResult {
        guard allowsAudioInspection, ReferencePrivacyPreferences.allowsAudioInspection(in: .standard) else { throw ReferenceProcessingFailure("OpenAI audio inspection is off. Enable it in Song Attachments settings only if you want to upload excerpts. Local stem separation and MIDI transcription need no cloud audio service.") }
        guard inspections < 8 else { throw ReferenceProcessingFailure("This prompt reached its eight audio-inspection limit.") }
        let start = try number(arguments, "start_seconds", range: 0...attachment.duration)
        let duration = try number(arguments, "duration_seconds", range: 0.001...60)
        guard start + duration <= attachment.duration + 0.001, let question = arguments["question"]?.stringValue else { throw AgentError.invalidTool("Choose a valid excerpt and a short question.") }
        let url = try await audioSource(attachment, original: source, stem: arguments["stem"]?.stringValue ?? "source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let excerpt = directory.appendingPathComponent("Inspection-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: excerpt) }
        try reserveDraftBytes(Int64(ceil(duration * 48_000 * 6)) + 65_536)
        _ = try await referenceWork { try ReferenceAudioProcessor.renderSegment(source: url, to: excerpt, startSeconds: start, durationSeconds: duration) }
        inspections += 1; status(attachment.id, "Inspecting audio with gpt-audio-1.5…")
        let answer = try await inspector.inspect(audio: excerpt, question: question, budget: budget)
        status(attachment.id, "Audio inspection ready")
        return ReferenceToolResult(output: .object(["analysis": .string(answer), "source_start_seconds": .number(start), "source_end_seconds": .number(start + duration),
            "model": .string(OpenAIAudioInspection.model), "note": .string("Semantic interpretation of this excerpt only; timestamps and labels may be approximate.")]))
    }
    func audioSource(_ attachment: SongAttachment, original: URL, stem: String) async throws -> URL {
        if stem == "source" { return original }
        let separated = try await separation(attachment, source: original)
        guard let result = separated.audio.first(where: { $0.name == stem }) else { throw AgentError.invalidTool("Use an exact audio_stems name returned by inspect_reference.") }
        return result.url
    }
    func reserve(_ id: UUID) throws {
        guard processed.contains(id) || processed.count < 4 else { throw ReferenceProcessingFailure("Process at most four source songs per prompt.") }
        processed.insert(id)
    }
    func processingSession() async throws -> ReferenceProcessing {
        if let cachedProcessor { return cachedProcessor }
        let value = try await processor(); cachedProcessor = value; return value
    }
    func reserveDraftBytes(_ additional: Int64) throws {
        var current: Int64 = 0
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { current += Int64(values.fileSize ?? 0) }
            }
        }
        guard additional >= 0, current <= ReferenceProcessing.maximumScratchBytes - additional else {
            throw ReferenceProcessingFailure("This prompt reached its 4 GiB draft-audio limit. Use fewer or shorter source ranges. The arrangement was not changed.")
        }
    }
    func number(_ arguments: JSONValue, _ key: String, range: ClosedRange<Double>) throws -> Double {
        guard let value = arguments[key]?.doubleValue, value.isFinite, range.contains(value) else { throw AgentError.invalidTool("Supply a valid \(key).") }; return value
    }
    func optionalNumber(_ arguments: JSONValue, _ key: String) throws -> Double? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let number = value.doubleValue, number.isFinite else { throw AgentError.invalidTool("\(key) must be a finite number or null.") }
        return number
    }
    func integer(_ arguments: JSONValue, _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let value = arguments[key] == .null || arguments[key] == nil ? Double(fallback) : arguments[key]?.doubleValue
        guard let value, value.isFinite, value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else { throw AgentError.invalidTool("Supply a valid \(key).") }; return Int(value)
    }
}
