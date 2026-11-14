import Foundation
import AVFAudio
import UnabletonAI
import UnabletonCore

/// Provider configuration is local to this Mac. Only the rendered score, lyrics
/// and take metadata go into a song; API keys and reference recordings do not.
enum VocalPreferences {
    static var referenceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Unableton", isDirectory: true).appendingPathComponent("VocalReference")
    }
    static func makeSession() throws -> VocalSession? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "vocals.enabled") else { return nil }
        let provider = defaults.string(forKey: "vocals.provider") ?? "audial"
        guard let key = try CredentialStore.load(provider: provider), !key.isEmpty else {
            throw ProjectError("Add your \(provider == "audial" ? "Audial" : "Rinoa") API key in Vocals settings, or turn off vocal generation.")
        }
        if provider == "rinoa" { return VocalSession(provider: RinoaVocalClient(apiKey: key)) }
        let userID = defaults.string(forKey: "vocals.audialUserID") ?? ""
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("Add your Audial user ID in Vocals settings.") }
        guard let name = defaults.string(forKey: "vocals.referenceName"), let data = try? Data(contentsOf: referenceURL), !data.isEmpty else {
            throw ProjectError("Choose a 5–10 second reference voice recording in Vocals settings.")
        }
        return VocalSession(provider: AudialVocalClient(apiKey: key, userID: userID, referenceAudio: data, referenceFileName: name))
    }
    static func saveReference(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, (5...10).contains(duration) else { throw ProjectError("Choose a reference voice recording between 5 and 10 seconds long.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw ProjectError("The reference recording must be smaller than 8 MB.") }
        try FileManager.default.createDirectory(at: referenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: referenceURL, options: .atomic)
        UserDefaults.standard.set(url.lastPathComponent, forKey: "vocals.referenceName")
    }
}
