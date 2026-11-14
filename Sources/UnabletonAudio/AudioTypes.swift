import Foundation

public enum AudioError: LocalizedError, Sendable {
    case invalidSong(String), missingInstrument(String), missingSoundFont(String), missingAsset(UUID), unreadableAudio(String), permissionDenied, recording(String), render(String)
    public var errorDescription: String? {
        switch self {
        case .invalidSong(let text), .unreadableAudio(let text), .recording(let text), .render(let text): text
        case .missingInstrument(let id): "Instrument \(id) is not available."
        case .missingSoundFont(let name): "Sound \(name) is not installed. Open Sound Library to download it."
        case .missingAsset(let id): "The audio file for asset \(id) is missing."
        case .permissionDenied: "Microphone access is disabled. Enable Unableton in System Settings → Privacy & Security → Microphone."
        }
    }
}
public struct RecordedAudio: Sendable, Equatable {
    public let url: URL
    public let duration: Double
    public let sampleRate: Double
    public let channels: Int
    public let startBeat: Double
}
public enum TranscriptionAudition: String, CaseIterable, Codable, Sendable, Identifiable {
    case accompaniment, visualOnly, solo
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .accompaniment: "Listen to song"
        case .visualOnly: "Silent timeline"
        case .solo: "Solo"
        }
    }
}
public struct RenderReport: Sendable {
    public let duration: Double
    public let peak: Double
    public let rms: Double
    public let clippedSamples: Int
    public let silent: Bool
}
