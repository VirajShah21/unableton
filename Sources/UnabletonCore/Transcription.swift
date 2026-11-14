import Foundation

public enum TranscriptionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case whistle, humming, singing, beatboxing
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .whistle: "Whistle"
        case .humming: "Humming"
        case .singing: "Singing"
        case .beatboxing: "Beatboxing"
        }
    }
}

/// Measured performance timing, relative to the beginning of the original take.
/// Confidence is a detector quality estimate, not a calibrated probability.
public struct TranscribedEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var pitch: Int
    public var startSeconds: Double
    public var durationSeconds: Double
    /// Normalized MIDI velocity, greater than zero and at most one.
    public var velocity: Double
    public var confidence: Double
    public init(id: UUID = UUID(), pitch: Int, startSeconds: Double, durationSeconds: Double, velocity: Double, confidence: Double) {
        self.id = id; self.pitch = pitch; self.startSeconds = startSeconds; self.durationSeconds = durationSeconds
        self.velocity = velocity; self.confidence = confidence
    }
}

public struct PerformanceTranscript: Codable, Sendable, Equatable {
    public static let maximumDuration: Double = 60
    public static let maximumEvents = 4096
    public var mode: TranscriptionMode
    public var events: [TranscribedEvent]
    public var duration: Double
    public var warnings: [String]
    public init(mode: TranscriptionMode, events: [TranscribedEvent], duration: Double, warnings: [String] = []) {
        self.mode = mode; self.events = events; self.duration = duration; self.warnings = warnings
    }

    public func validate() throws {
        guard duration.isFinite, duration > 0, duration <= Self.maximumDuration + 0.0001 else { throw TranscriptionError.durationLimit }
        guard !events.isEmpty else { throw TranscriptionError.noNotes }
        guard events.count <= Self.maximumEvents else { throw TranscriptionError.invalidTranscript("There are too many detected events.") }
        var ids = Set<UUID>()
        for event in events {
            guard ids.insert(event.id).inserted, (0...127).contains(event.pitch),
                  event.startSeconds.isFinite, event.startSeconds >= 0,
                  event.durationSeconds.isFinite, event.durationSeconds > 0,
                  event.startSeconds + event.durationSeconds <= duration + 0.0001,
                  event.velocity.isFinite, event.velocity > 0, event.velocity <= 1,
                  event.confidence.isFinite, (0...1).contains(event.confidence) else {
                throw TranscriptionError.invalidTranscript("A detected event has invalid pitch, timing, velocity or confidence.")
            }
        }
    }

    /// Converts measured seconds directly into beats. No snapping, tempo fitting,
    /// transposition, rest removal or additional musical content happens here.
    public func notes(tempo: Double) throws -> [NoteEvent] {
        guard tempo.isFinite, (30...300).contains(tempo) else { throw TranscriptionError.invalidTempo }
        try validate()
        return events.sorted { $0.startSeconds < $1.startSeconds }.map {
            NoteEvent(id: $0.id, pitch: $0.pitch, startBeat: $0.startSeconds * tempo / 60,
                      duration: $0.durationSeconds * tempo / 60,
                      velocity: min(127, max(1, Int(($0.velocity * 127).rounded()))))
        }
    }
}

public enum TranscriptionError: LocalizedError, Sendable {
    case durationLimit, noSound, noNotes, invalidTempo
    case invalidAudio(String), invalidTranscript(String)
    public var errorDescription: String? {
        switch self {
        case .durationLimit: "Transcribe a recording between a fraction of a second and 60 seconds long."
        case .noSound: "No clear sound was found. Check the input level and record another take."
        case .noNotes: "No reliable musical events were found. Try a clear solo melody, or use Beatboxing for percussion."
        case .invalidTempo: "Choose a song tempo between 30 and 300 BPM."
        case .invalidAudio(let message), .invalidTranscript(let message): message
        }
    }
}
