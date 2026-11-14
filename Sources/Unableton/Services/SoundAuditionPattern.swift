import Foundation
import CryptoKit
import UnabletonCore

/// Small comparison phrases, separate from composition and document state.
enum SoundAuditionPattern {
    static let version = 1

    static func song(for preset: InstrumentPreset) throws -> Song {
        let allowed = (preset.supportedPitches ?? Array(preset.minimumPitch...preset.maximumPitch))
            .filter { $0 >= preset.minimumPitch && $0 <= preset.maximumPitch && !(preset.unrenderablePitches ?? []).contains($0) }.sorted()
        guard !allowed.isEmpty else { throw ProjectError("This sound has no supported preview notes.") }
        func pitch(_ target: Int) -> Int { allowed.min { abs($0 - target) < abs($1 - target) }! }
        var notes: [NoteEvent] = []
        // These are project-note mappings, not SF2 keys. NativeGraph applies
        // any declared pitchMap exactly once, just as it does for a song.
        let drumKeys: [Int]?
        switch preset.id {
        case "drums.electronic": drumKeys = [36, 38, 42, 46]
        case "sampled.drums": drumKeys = [35, 38, 37, 40]
        case "freepats.synthesizerpercussion": drumKeys = [48, 50, 52, 54]
        default: drumKeys = nil
        }
        if let drumKeys {
            for beat in 0..<8 {
                let key = drumKeys[beat.isMultiple(of: 2) ? 0 : 1]
                if allowed.contains(key) { notes.append(.init(pitch: key, startBeat: Double(beat), duration: 0.2, velocity: 88)) }
                let hat = drumKeys[beat == 7 ? 3 : 2]
                if allowed.contains(hat) { notes.append(.init(pitch: hat, startBeat: Double(beat) + 0.5, duration: 0.15, velocity: 65)) }
            }
        } else if preset.roles.contains("bass") {
            let root = pitch(36)
            for (index, offset) in [0, 0, 7, 0, 0, 12, 7, 0].enumerated() {
                notes.append(.init(pitch: pitch(root + offset), startBeat: Double(index), duration: 0.7, velocity: index.isMultiple(of: 2) ? 90 : 76))
            }
        } else if preset.roles.contains("harmony") || preset.roles.contains("texture") {
            let root = pitch(60)
            for start in [0.0, 4.0] {
                for key in Set([pitch(root), pitch(root + 4), pitch(root + 7)]).sorted() {
                    notes.append(.init(pitch: key, startBeat: start, duration: 3.2, velocity: 75))
                }
            }
        } else {
            let root = pitch(60)
            for (index, offset) in [0, 4, 7, 12, 7, 4, 2, 0].enumerated() {
                notes.append(.init(pitch: pitch(root + offset), startBeat: Double(index), duration: 0.65, velocity: 84))
            }
        }
        guard !notes.isEmpty else { throw ProjectError("This sound has no supported preview pattern.") }
        var song = Song(); song.title = "Sound preview"; song.tempo = 120; song.lengthBars = 2
        song.tracks = [Track(name: preset.name, instrumentID: preset.id, volume: 0.5, parameters: preset.defaults,
                             clips: [Clip(name: "Preview", lengthBeats: 8, notes: notes)])]
        return song
    }

    static func cacheKey(for preset: InstrumentPreset) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = (try? encoder.encode(preset)) ?? Data(preset.id.utf8)
        let bankVersion = preset.soundBankID.flatMap { SoundBankCatalog.bank(id: $0)?.version } ?? "built-in"
        return SHA256.hash(data: identity + Data("\(version):\(bankVersion)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
