import Foundation

public enum TranscriptionTiming: String, Codable, Sendable, CaseIterable {
    case preserve, autoTime
    public var displayName: String { self == .preserve ? "Preserve Time" : "Auto-time" }
}
public enum TranscriptionAdjustment: String, Codable, Sendable, CaseIterable {
    case minor, major
    public var displayName: String { self == .minor ? "Minor adjustments" : "Major adjustments" }
}
public enum TranscriptionLayerRole: String, Codable, Sendable, CaseIterable {
    case performance, drums, bass, harmony, countermelody
    public var displayName: String {
        switch self {
        case .performance: "Detected performance"
        case .drums: "Matching drums"
        case .bass: "Matching bass"
        case .harmony: "Harmony"
        case .countermelody: "Countermelody"
        }
    }
}
public struct TranscriptionLayer: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var instrumentID: String
    public var role: TranscriptionLayerRole
    public init(id: UUID = UUID(), name: String = "Transcribed melody", instrumentID: String = "synth.lead", role: TranscriptionLayerRole = .performance) {
        self.id = id; self.name = name; self.instrumentID = instrumentID; self.role = role
    }
}
public struct TranscriptionOptions: Codable, Sendable, Equatable {
    public var timing: TranscriptionTiming
    public var adjustment: TranscriptionAdjustment
    public var targetLengthBeats: Double
    public var insertionBeat: Double
    public var layers: [TranscriptionLayer]
    public var instructions: String
    public init(timing: TranscriptionTiming = .preserve, adjustment: TranscriptionAdjustment = .minor, targetLengthBeats: Double = 16, insertionBeat: Double = 0, layers: [TranscriptionLayer] = [TranscriptionLayer()], instructions: String = "") {
        self.timing = timing; self.adjustment = adjustment; self.targetLengthBeats = targetLengthBeats
        self.insertionBeat = insertionBeat; self.layers = layers; self.instructions = instructions
    }
    public var requiresAI: Bool { timing == .autoTime || layers.contains { $0.role != .performance } }
}
public struct TranscriptionTimingChange: Codable, Sendable, Equatable {
    public var sourceEventID: UUID
    public var startBeat: Double
    public var duration: Double
    public init(sourceEventID: UUID, startBeat: Double, duration: Double) {
        self.sourceEventID = sourceEventID; self.startBeat = startBeat; self.duration = duration
    }
}
public struct TranscriptionLayerNotes: Codable, Sendable, Equatable {
    public var layerID: UUID
    public var notes: [NoteEvent]
    public init(layerID: UUID, notes: [NoteEvent]) { self.layerID = layerID; self.notes = notes }
}
public struct TranscriptionArrangementPlan: Codable, Sendable, Equatable {
    public var timingChanges: [TranscriptionTimingChange]
    public var layers: [TranscriptionLayerNotes]
    public var summary: String
    public init(timingChanges: [TranscriptionTimingChange] = [], layers: [TranscriptionLayerNotes] = [], summary: String = "Transcribed the detected performance without adding notes.") {
        self.timingChanges = timingChanges; self.layers = layers; self.summary = summary
    }
}

/// Plans cannot alter the existing song. This host constructs all shared commands.
public enum TranscriptionArrangementBuilder {
    public static func validate(plan: TranscriptionArrangementPlan, transcript: PerformanceTranscript, options: TranscriptionOptions, song: Song) throws {
        let tracks = try makeTracks(plan: plan, transcript: transcript, options: options, song: song)
        var probe = song
        try ProjectEditor.apply(tracks.map { .init(op: .addTrack, track: $0) }, to: &probe)
    }

    public static func commands(plan: TranscriptionArrangementPlan, transcript: PerformanceTranscript, options: TranscriptionOptions, song: Song, sourceAssetID: UUID? = nil) throws -> [ProjectCommand] {
        try validate(plan: plan, transcript: transcript, options: options, song: song)
        var tracks = try makeTracks(plan: plan, transcript: transcript, options: options, song: song)
        for i in tracks.indices { tracks[i].clips[0].transcriptionAssetID = sourceAssetID }
        return tracks.map { .init(op: .addTrack, track: $0) }
    }

    private static func makeTracks(plan: TranscriptionArrangementPlan, transcript: PerformanceTranscript, options: TranscriptionOptions, song: Song) throws -> [Track] {
        var source = try transcript.notes(tempo: song.tempo)
        guard !source.isEmpty, source.count <= 4096, Set(source.map(\.id)).count == source.count, !options.layers.isEmpty,
              options.layers.count <= 64 - song.tracks.count,
              options.layers.contains(where: { $0.role == .performance }),
              Set(options.layers.map(\.id)).count == options.layers.count,
              options.insertionBeat.isFinite, options.insertionBeat >= 0,
              options.targetLengthBeats.isFinite, (0.0625...4096).contains(options.targetLengthBeats),
              options.instructions.utf8.count <= 8000 else { throw ProjectError("Choose at least one performance layer, a valid position and length, and stay within the song's 64-track limit.") }
        if options.timing == .preserve {
            guard plan.timingChanges.isEmpty else { throw ProjectError("Preserve Time does not allow timing changes.") }
        } else {
            guard plan.timingChanges.count == source.count,
                  Set(plan.timingChanges.map(\.sourceEventID)) == Set(source.map(\.id)) else { throw ProjectError("Auto-time must retain every detected event exactly once.") }
            let changes = Dictionary(uniqueKeysWithValues: plan.timingChanges.map { ($0.sourceEventID, $0) })
            for i in source.indices {
                guard let change = changes[source[i].id], change.startBeat.isFinite, change.startBeat >= 0,
                      change.duration.isFinite, change.duration > 0 else { throw ProjectError("Auto-time returned invalid event timing.") }
                if options.adjustment == .minor {
                    guard abs(change.startBeat - source[i].startBeat) <= 0.25 + 1e-8,
                          abs(change.duration - source[i].duration) <= 0.25 + 1e-8 else { throw ProjectError("Minor adjustments may move onsets and lengths by at most one sixteenth note.") }
                } else {
                    guard change.startBeat + change.duration <= options.targetLengthBeats + 1e-8 else { throw ProjectError("Major adjustments must fit the chosen section length.") }
                }
                source[i].startBeat = change.startBeat; source[i].duration = change.duration
            }
            for pair in zip(source, source.dropFirst()) {
                guard pair.0.startBeat <= pair.1.startBeat,
                      transcript.mode == .beatboxing || pair.0.startBeat + pair.0.duration <= pair.1.startBeat + 1e-6 else { throw ProjectError("Auto-time must preserve event order and a single melody voice.") }
            }
        }
        let requested = Set(options.layers.filter { $0.role != .performance }.map(\.id))
        guard plan.layers.count == requested.count, Set(plan.layers.map(\.layerID)) == requested else { throw ProjectError("The arrangement must contain exactly the accompaniment layers you requested.") }
        let added = Dictionary(uniqueKeysWithValues: plan.layers.map { ($0.layerID, $0.notes) })
        let sourceLength = options.timing == .autoTime && options.adjustment == .major ? options.targetLengthBeats :
            max(transcript.duration * song.tempo / 60, source.map { $0.startBeat + $0.duration }.max() ?? 0)
        let clipLength = max(sourceLength, options.requiresAI ? options.targetLengthBeats : 0)
        var tracks: [Track] = []
        for (index, layer) in options.layers.enumerated() {
            guard !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, layer.name.utf8.count <= 256,
                  let preset = InstrumentCatalog.preset(id: layer.instrumentID),
                  (layer.role == .performance || (preset.category == "Drums") == (layer.role == .drums)),
                  (layer.role != .performance || (preset.category == "Drums") == (transcript.mode == .beatboxing)) else { throw ProjectError("Choose a compatible instrument and name for each layer.") }
            let detected = layer.role == .performance
            let notes = detected ? source : (added[layer.id] ?? [])
            guard !notes.isEmpty, notes.count <= 4096 else { throw ProjectError("Each layer needs 1–4096 notes.") }
            if !detected {
                guard notes.allSatisfy({ $0.startBeat.isFinite && $0.duration.isFinite && $0.startBeat >= 0 && $0.duration > 0 && $0.startBeat + $0.duration <= options.targetLengthBeats + 1e-8 }) else { throw ProjectError("An accompaniment note falls outside the requested section.") }
            }
            let copied = notes.map { NoteEvent(pitch: $0.pitch, startBeat: $0.startBeat, duration: $0.duration, velocity: $0.velocity) }
            let clip = Clip(name: detected ? "\(transcript.mode.displayName) take" : layer.name, startBeat: options.insertionBeat, lengthBeats: max(0.0625, clipLength), notes: copied)
            tracks.append(Track(name: layer.name, instrumentID: layer.instrumentID, colorIndex: song.tracks.count + index,
                                volume: 0.7 / sqrt(Double(options.layers.count)), clips: [clip]))
        }
        return tracks
    }
}

public struct TranscriptionTake: Codable, Sendable, Equatable {
    public var transcript: PerformanceTranscript
    public var recordedTempo: Double
    public var recordedStartBeat: Double
    public var createdAt: Date
    public init(transcript: PerformanceTranscript, recordedTempo: Double, recordedStartBeat: Double, createdAt: Date = Date()) {
        self.transcript = transcript; self.recordedTempo = recordedTempo; self.recordedStartBeat = recordedStartBeat; self.createdAt = createdAt
    }
}
