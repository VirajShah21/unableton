import Foundation

/// Standard MIDI File type 1, 480 ticks per quarter note. Audio clips are retained in the project, not MIDI.
public enum MIDIExporter {
    public static func data(for song: Song) throws -> Data {
        try ProjectEditor.validate(song)
        let ppq = 480
        func be(_ n: UInt32, _ bytes: Int) -> [UInt8] { (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
        func vlq(_ n: Int) -> [UInt8] {
            var n = max(0, n), out = [UInt8(n & 127)]; n >>= 7
            while n > 0 { out.insert(UInt8(n & 127) | 128, at: 0); n >>= 7 }; return out
        }
        func chunk(_ events: [(Int, [UInt8])]) -> [UInt8] {
            var bytes: [UInt8] = [], last = 0
            func priority(_ event: [UInt8]) -> Int {
                guard let first = event.first else { return 4 }
                if first == 0xFF { return 0 }
                if first & 0xF0 == 0xC0 { return 1 }
                if first & 0xF0 == 0x80 { return 2 }
                return 3
            }
            for (tick, event) in events.sorted(by: { $0.0 == $1.0 ? priority($0.1) < priority($1.1) : $0.0 < $1.0 }) { bytes += vlq(tick - last) + event; last = tick }
            bytes += [0, 0xFF, 0x2F, 0]
            return Array("MTrk".utf8) + be(UInt32(bytes.count), 4) + bytes
        }
        let tracks = song.tracks.filter { $0.kind == .instrument }
        var result = Array("MThd".utf8) + be(6, 4) + be(1, 2) + be(UInt32(tracks.count + 1), 2) + be(UInt32(ppq), 2)
        let tempo = UInt32((60_000_000 / song.tempo).rounded())
        result += chunk([(0, [0xFF, 0x51, 3] + be(tempo, 3)), (0, [0xFF, 0x58, 4, UInt8(song.beatsPerBar), 2, 24, 8])])
        var melodicChannel = 0
        for track in tracks {
            // Only these legacy presets expose General MIDI percussion keys.
            // Downloaded percussion can use native SF2 keys; keep those notes
            // unchanged on melodic channels rather than relabel them as GM drums.
            let drums = ["drums.electronic", "sampled.drums"].contains(track.instrumentID)
            let ch = drums ? 9 : melodicChannel % 15 + (melodicChannel % 15 >= 9 ? 1 : 0)
            if !drums { melodicChannel += 1 }
            let name = Array(track.name.utf8.prefix(127))
            var events: [(Int, [UInt8])] = [(0, [0xFF, 3] + vlq(name.count) + name)]
            // SF2 program/bank selects a patch inside a particular downloaded
            // file; it is not necessarily a General MIDI program number.
            let legacyPrograms: [String: UInt8] = [
                "sampled.piano": 0, "sampled.guitar": 24, "sampled.bass": 33,
                "sampled.mallets": 13, "sampled.drums": 0, "drums.electronic": 0,
                "synth.bass": 0, "synth.lead": 0, "synth.pad": 0,
                "synth.pluck": 0, "synth.strings": 0
            ]
            if let gm = legacyPrograms[track.instrumentID] ?? InstrumentCatalog.preset(id: track.instrumentID)?.gmProgram {
                events.append((0, [0xC0 | UInt8(ch), gm]))
            }
            for clip in track.clips where clip.kind == .notes {
                for note in clip.notes {
                    let start = clip.startBeat + note.startBeat
                    let end = min(clip.startBeat + clip.lengthBeats, start + note.duration)
                    guard end > start else { continue }
                    events.append((Int((start * Double(ppq)).rounded()), [0x90 | UInt8(ch), UInt8(note.pitch), UInt8(note.velocity)]))
                    events.append((Int((end * Double(ppq)).rounded()), [0x80 | UInt8(ch), UInt8(note.pitch), 0]))
                }
            }
            result += chunk(events)
        }
        return Data(result)
    }
}
