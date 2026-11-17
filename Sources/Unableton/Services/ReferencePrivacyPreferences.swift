import Foundation

/// Local separation/transcription needs no cloud consent. Only this new explicit
/// preference permits an audio excerpt to leave the Mac for OpenAI inspection.
enum ReferencePrivacyPreferences {
    static let audioInspectionKey = "references.allowOpenAIAudioInspection"

    static func allowsAudioInspection(in preferences: UserDefaults = .standard) -> Bool {
        preferences.bool(forKey: audioInspectionKey)
    }
}
