import Foundation

public enum TrackKind: String, Codable, Sendable, CaseIterable { case instrument, audio }
public enum ClipKind: String, Codable, Sendable { case notes, audio }

public struct NoteEvent: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var pitch: Int
    public var startBeat: Double
    public var duration: Double
    public var velocity: Int
    public init(id: UUID = UUID(), pitch: Int = 60, startBeat: Double = 0, duration: Double = 1, velocity: Int = 100) {
        self.id = id; self.pitch = pitch; self.startBeat = startBeat; self.duration = duration; self.velocity = velocity
    }
}

public struct Clip: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ClipKind
    public var startBeat: Double
    public var lengthBeats: Double
    public var notes: [NoteEvent]
    public var assetID: UUID?
    public var sourceOffsetSeconds: Double
    public var transcriptionAssetID: UUID? = nil
    public init(id: UUID = UUID(), name: String = "Clip", kind: ClipKind = .notes, startBeat: Double = 0, lengthBeats: Double = 16, notes: [NoteEvent] = [], assetID: UUID? = nil, sourceOffsetSeconds: Double = 0) {
        self.id = id; self.name = name; self.kind = kind; self.startBeat = startBeat; self.lengthBeats = lengthBeats
        self.notes = notes; self.assetID = assetID; self.sourceOffsetSeconds = sourceOffsetSeconds
    }
}

public struct Track: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var instrumentID: String
    public var colorIndex: Int
    public var volume: Double
    public var pan: Double
    public var isMuted: Bool
    public var isSolo: Bool
    public var isArmed: Bool
    public var parameters: [String: Double]
    public var clips: [Clip]
    public init(id: UUID = UUID(), name: String = "Synth", kind: TrackKind = .instrument, instrumentID: String = "synth.lead", colorIndex: Int = 0, volume: Double = 0.7, pan: Double = 0, isMuted: Bool = false, isSolo: Bool = false, isArmed: Bool = false, parameters: [String: Double] = [:], clips: [Clip] = []) {
        self.id = id; self.name = name; self.kind = kind; self.instrumentID = instrumentID; self.colorIndex = colorIndex
        self.volume = volume; self.pan = pan; self.isMuted = isMuted; self.isSolo = isSolo; self.isArmed = isArmed
        self.parameters = parameters; self.clips = clips
    }
}

public struct AudioAsset: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var fileName: String
    public var duration: Double
    public var sampleRate: Double
    public var channels: Int
    public var vocalTake: VocalTake?
    public var transcriptionTake: TranscriptionTake?
    public init(id: UUID = UUID(), fileName: String, duration: Double, sampleRate: Double, channels: Int, vocalTake: VocalTake? = nil, transcriptionTake: TranscriptionTake? = nil) {
        self.id = id; self.fileName = fileName; self.duration = duration; self.sampleRate = sampleRate; self.channels = channels
        self.vocalTake = vocalTake
        self.transcriptionTake = transcriptionTake
    }
}

public struct Song: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var title: String = "Untitled"
    public var revision: Int = 0
    public var tempo: Double = 140
    public var beatsPerBar: Int = 4
    public var lengthBars: Int = 32
    public var key: String = "C major"
    public var tracks: [Track] = []
    public var assets: [AudioAsset] = []
    public var loopEnabled: Bool = false
    public var loopStart: Double = 0
    public var loopEnd: Double = 16
    public var metronomeEnabled: Bool = false
    public init() {}
    public var lengthBeats: Double { max(Double(lengthBars * beatsPerBar), tracks.flatMap(\.clips).map { $0.startBeat + $0.lengthBeats }.max() ?? 0) }
    public var duration: Double { lengthBeats * 60 / tempo }
    public func track(_ id: UUID?) -> Track? { tracks.first { $0.id == id } }
    public func clip(_ id: UUID?) -> Clip? { tracks.lazy.flatMap(\.clips).first { $0.id == id } }
}

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var role: String
    public var text: String
    public var date: Date = Date()
    public var runID: UUID?
    public init(role: String, text: String, runID: UUID? = nil) { self.role = role; self.text = text; self.runID = runID }
}
public struct Conversation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var title: String = "New chat"
    public var messages: [ChatMessage] = []
    /// Canonical Responses items, including opaque continuation data. Never a source of current song truth.
    public var responseItems: [JSONValue] = []
    public var responseModel: String?
    public init(title: String = "New chat") { self.title = title }
}
public struct GenerationRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var model: String
    public var summary: String
    public var baseRevision: Int
    public var appliedRevision: Int?
    public var isUndone: Bool
    public var inputTokens: Int
    public var outputTokens: Int
    public var date: Date
    public var routingReason: String?
    public var attemptedModels: [String]?
    public var observation: GenerationObservation?
    public var generationRequests: Int?
    public var transientRetries: Int?
    public init(id: UUID = UUID(), conversationID: UUID, model: String, summary: String, baseRevision: Int, appliedRevision: Int? = nil, isUndone: Bool = false, inputTokens: Int = 0, outputTokens: Int = 0, routingReason: String? = nil, attemptedModels: [String]? = nil) {
        self.id = id; self.conversationID = conversationID; self.model = model; self.summary = summary
        self.baseRevision = baseRevision; self.appliedRevision = appliedRevision; self.isUndone = isUndone
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.date = Date()
        self.routingReason = routingReason; self.attemptedModels = attemptedModels
    }
}
public struct ProjectFile: Codable, Sendable, Equatable {
    public var formatVersion: Int = 1
    public var song: Song = Song()
    public var conversations: [Conversation] = [Conversation()]
    public var generations: [GenerationRecord] = []
    public init() {}
}
public struct ProjectSelection: Codable, Sendable, Equatable {
    public var trackID: UUID?
    public var clipID: UUID?
    public var startBeat: Double?
    public var endBeat: Double?
    public init(trackID: UUID? = nil, clipID: UUID? = nil, startBeat: Double? = nil, endBeat: Double? = nil) {
        self.trackID = trackID; self.clipID = clipID; self.startBeat = startBeat; self.endBeat = endBeat
    }
}
