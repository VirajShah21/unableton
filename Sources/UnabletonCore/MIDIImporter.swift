import Foundation

public struct MIDITimedNote: Codable, Sendable, Equatable {
    public var pitch: Int
    public var startSeconds: Double
    public var durationSeconds: Double
    public var velocity: Int
    public init(pitch: Int, startSeconds: Double, durationSeconds: Double, velocity: Int) {
        self.pitch = pitch; self.startSeconds = startSeconds; self.durationSeconds = durationSeconds; self.velocity = velocity
    }
}

public struct MIDIImportedPart: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var channel: Int
    public var program: Int
    public var isPercussion: Bool
    public var notes: [MIDITimedNote]
    /// Host-assigned provenance for local reference transcription; absent in legacy/imported MIDI.
    public var referenceStem: String?
    public init(id: String, name: String, channel: Int, program: Int, isPercussion: Bool, notes: [MIDITimedNote], referenceStem: String? = nil) {
        self.id = id; self.name = name; self.channel = channel; self.program = program; self.isPercussion = isPercussion; self.notes = notes; self.referenceStem = referenceStem
    }
}

public struct MIDIImport: Codable, Sendable, Equatable {
    public var parts: [MIDIImportedPart]
    public var duration: Double
    public var initialTempo: Double
    public var warnings: [String]
    public init(parts: [MIDIImportedPart], duration: Double, initialTempo: Double, warnings: [String] = []) {
        self.parts = parts; self.duration = duration; self.initialTempo = initialTempo; self.warnings = warnings
    }
    public func validate(maximumDuration: Double = 600) throws {
        guard duration.isFinite, duration > 0, duration <= maximumDuration + 0.001,
              initialTempo.isFinite, initialTempo > 0, initialTempo <= 1_000,
              !parts.isEmpty, parts.count <= 64, Set(parts.map(\.id)).count == parts.count,
              parts.reduce(0, { $0 + $1.notes.count }) <= 131_072,
              warnings.count <= 16, warnings.allSatisfy({ $0.utf8.count <= 1024 }) else { throw ProjectError("Invalid or oversized MIDI transcription.") }
        for part in parts {
            guard !part.id.isEmpty, part.id.utf8.count <= 128, part.name.utf8.count <= 512,
                  (0...15).contains(part.channel), (0...127).contains(part.program), part.isPercussion == (part.channel == 9),
                  !part.notes.isEmpty, part.notes.count <= 65_536,
                  part.referenceStem == nil || ["bass", "other", "vocals"].contains(part.referenceStem!) else { throw ProjectError("Invalid MIDI instrument part.") }
            for note in part.notes {
                guard (0...127).contains(note.pitch), (1...127).contains(note.velocity),
                      note.startSeconds.isFinite, note.durationSeconds.isFinite, note.startSeconds >= 0, note.durationSeconds > 0,
                      note.startSeconds + note.durationSeconds <= duration + 0.001 else { throw ProjectError("Invalid measured MIDI note timing.") }
            }
        }
    }
}

/// Reads standard MIDI 0/1 with a PPQ clock. Returned times include rests and tempo changes.
public enum MIDIImporter {
    public static func parse(_ data: Data, maximumDuration: Double = 600) throws -> MIDIImport {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
              maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 3_600 else { throw ProjectError("MIDI data is empty or exceeds the supported limit.") }
        var reader = MIDIReader(Array(data))
        guard try reader.string(4) == "MThd" else { throw ProjectError("The transcription is not a standard MIDI file.") }
        let headerLength = try reader.uint32()
        guard (6...1024).contains(headerLength) else { throw ProjectError("Invalid MIDI header.") }
        let format = try reader.uint16(), trackCount = try reader.uint16(), division = try reader.uint16()
        guard format == 0 || format == 1, trackCount > 0, trackCount <= 128,
              format != 0 || trackCount == 1 else { throw ProjectError("Only standard MIDI formats 0 and 1 are supported.") }
        guard division > 0, division & 0x8000 == 0 else { throw ProjectError("SMPTE MIDI clocks are unsupported; provide a PPQ MIDI transcription.") }
        try reader.skip(headerLength - 6)
        var parser = MIDIParser(ppq: division)
        var readTracks = 0
        while !reader.isAtEnd, readTracks < trackCount {
            let type = try reader.string(4), length = try reader.uint32()
            let chunk = try reader.bytes(length)
            if type == "MTrk" {
                try parser.readTrack(chunk, index: readTracks)
                readTracks += 1
            }
        }
        guard readTracks == trackCount, reader.isAtEnd else { throw ProjectError("The MIDI file has missing tracks or unexpected trailing data.") }
        return try parser.result(maximumDuration: maximumDuration)
    }
}

private struct MIDIReader {
    let data: [UInt8]
    var offset = 0
    init(_ data: [UInt8]) { self.data = data }
    var isAtEnd: Bool { offset == data.count }
    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw ProjectError("The MIDI file ended inside an event.") }
        defer { offset += 1 }; return data[offset]
    }
    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= data.count - offset else { throw ProjectError("Invalid MIDI chunk length.") }
        defer { offset += count }; return Array(data[offset..<(offset + count)])
    }
    mutating func skip(_ count: Int) throws { _ = try bytes(count) }
    mutating func string(_ count: Int) throws -> String { String(decoding: try bytes(count), as: UTF8.self) }
    mutating func uint16() throws -> Int { let a = try byte(), b = try byte(); return Int(a) << 8 | Int(b) }
    mutating func uint32() throws -> Int { let a = try uint16(), b = try uint16(); return a << 16 | b }
    mutating func variable() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<4 {
            let b = try byte(); value = value << 7 | UInt64(b & 0x7f)
            if b & 0x80 == 0 { return value }
        }
        throw ProjectError("Invalid MIDI variable-length value.")
    }
    mutating func dataByte(_ first: UInt8? = nil) throws -> Int {
        let value = try first ?? byte()
        guard value < 0x80 else { throw ProjectError("Invalid MIDI channel data.") }
        return Int(value)
    }
}

private struct MIDIParser {
    struct RawNote {
        var track: Int; var name: String; var channel: Int; var program: Int; var pitch: Int; var velocity: Int
        var start: UInt64; var end: UInt64?
    }
    struct Tempo { var tick: UInt64; var micros: Int; var order: Int }
    let ppq: Int
    var tempos: [Tempo] = []
    var notes: [RawNote] = []
    var finalTick: UInt64 = 0
    var eventCount = 0
    var pitchBends = false

    mutating func readTrack(_ bytes: [UInt8], index: Int) throws {
        var reader = MIDIReader(bytes), tick: UInt64 = 0, running: UInt8?
        var name = "Part \(index + 1)", programs = [Int](repeating: 0, count: 16)
        var active: [Int: [Int]] = [:], sustained: [Int: [Int]] = [:], pedal = [Bool](repeating: false, count: 16)
        var ended = false
        while !reader.isAtEnd {
            eventCount += 1
            guard eventCount <= 1_000_000 else { throw ProjectError("The MIDI file contains too many events.") }
            let delta = try reader.variable()
            guard tick <= UInt64.max - delta else { throw ProjectError("MIDI timing overflow.") }
            tick += delta
            guard tick <= 1_000_000_000 else { throw ProjectError("MIDI timing exceeds the supported range.") }
            let next = try reader.byte()
            let status: UInt8, first: UInt8?
            if next < 0x80 {
                guard let previous = running else { throw ProjectError("MIDI running status has no channel event.") }
                status = previous; first = next
            } else { status = next; first = nil }
            if status == 0xff {
                let meta = try reader.byte(), length = try reader.variable()
                guard length <= 1_048_576 else { throw ProjectError("MIDI metadata is too large.") }
                let payload = try reader.bytes(Int(length))
                if meta == 0x2f {
                    guard payload.isEmpty, reader.isAtEnd else { throw ProjectError("Invalid MIDI end-of-track event.") }
                    ended = true; break
                }
                if meta == 0x51 {
                    guard payload.count == 3 else { throw ProjectError("Invalid MIDI tempo event.") }
                    let micros = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
                    guard micros > 0 else { throw ProjectError("MIDI tempo cannot be zero.") }
                    tempos.append(Tempo(tick: tick, micros: micros, order: tempos.count))
                } else if meta == 0x03 {
                    name = String((String(bytes: payload, encoding: .utf8) ?? String(bytes: payload, encoding: .isoLatin1) ?? "Part \(index + 1)").prefix(120))
                }
                continue
            }
            if status == 0xf0 || status == 0xf7 {
                running = nil
                let length = try reader.variable()
                guard length <= 1_048_576 else { throw ProjectError("MIDI system data is too large.") }
                try reader.skip(Int(length)); continue
            }
            guard (0x80...0xef).contains(status) else { throw ProjectError("Unsupported MIDI system event.") }
            running = status
            let channel = Int(status & 0x0f), op = status & 0xf0
            let a = try reader.dataByte(first), b = try (op == 0xc0 || op == 0xd0) ? 0 : reader.dataByte()
            let key = channel * 128 + a
            if op == 0x90, b > 0 {
                guard notes.count < 131_072 else { throw ProjectError("MIDI transcription exceeds 131,072 notes.") }
                guard active[key, default: []].count < 32 else { throw ProjectError("MIDI contains too many overlapping notes of the same pitch.") }
                notes.append(RawNote(track: index, name: name, channel: channel, program: programs[channel], pitch: a, velocity: b, start: tick))
                active[key, default: []].append(notes.count - 1)
            } else if op == 0x80 || op == 0x90 {
                if var sounding = active[key], !sounding.isEmpty {
                    let note = sounding.removeFirst()
                    if sounding.isEmpty { active.removeValue(forKey: key) } else { active[key] = sounding }
                    if pedal[channel] { sustained[channel, default: []].append(note) } else { notes[note].end = tick }
                }
            } else if op == 0xc0 { programs[channel] = a }
            else if op == 0xe0 { pitchBends = true }
            else if op == 0xb0 {
                if a == 64 {
                    let isDown = b >= 64
                    if pedal[channel], !isDown { for note in sustained.removeValue(forKey: channel) ?? [] { notes[note].end = tick } }
                    pedal[channel] = isDown
                } else if a == 121 {
                    pedal[channel] = false
                    for note in sustained.removeValue(forKey: channel) ?? [] { notes[note].end = tick }
                } else if a == 120 || a == 123 {
                    for key in active.keys.filter({ $0 / 128 == channel }) {
                        for note in active.removeValue(forKey: key) ?? [] {
                            if a == 123, pedal[channel] { sustained[channel, default: []].append(note) } else { notes[note].end = tick }
                        }
                    }
                    if a == 120 { for note in sustained.removeValue(forKey: channel) ?? [] { notes[note].end = tick } }
                }
            }
        }
        guard ended else { throw ProjectError("The MIDI track is missing its end marker.") }
        for note in active.values.flatMap({ $0 }) + sustained.values.flatMap({ $0 }) { notes[note].end = tick }
        finalTick = max(finalTick, tick)
    }

    func result(maximumDuration: Double) throws -> MIDIImport {
        let sorted = tempos.sorted { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }
        var segments: [(tick: UInt64, seconds: Double, micros: Int)] = [(0, 0, 500_000)]
        for tempo in sorted {
            let last = segments.last!
            let seconds = last.seconds + Double(tempo.tick - last.tick) / Double(ppq) * Double(last.micros) / 1_000_000
            if tempo.tick == last.tick { segments[segments.count - 1] = (tempo.tick, seconds, tempo.micros) }
            else { segments.append((tempo.tick, seconds, tempo.micros)) }
        }
        func seconds(_ tick: UInt64) -> Double {
            var low = 0, high = segments.count
            while low + 1 < high {
                let mid = (low + high) / 2
                if segments[mid].tick <= tick { low = mid } else { high = mid }
            }
            let segment = segments[low]
            return segment.seconds + Double(tick - segment.tick) / Double(ppq) * Double(segment.micros) / 1_000_000
        }
        let duration = seconds(finalTick)
        guard duration <= maximumDuration + 0.001 else { throw ProjectError("The MIDI transcription exceeds the source song duration limit.") }
        var parts: [MIDIImportedPart] = [], locations: [String: Int] = [:]
        for note in notes {
            guard let end = note.end, end > note.start else { continue }
            let id = "\(note.track):\(note.channel):\(note.program)"
            if locations[id] == nil {
                guard parts.count < 64 else { throw ProjectError("The MIDI transcription exceeds 64 instrument parts.") }
                locations[id] = parts.count
                parts.append(MIDIImportedPart(id: id, name: note.name, channel: note.channel, program: note.program, isPercussion: note.channel == 9, notes: []))
            }
            let start = seconds(note.start)
            parts[locations[id]!].notes.append(MIDITimedNote(pitch: note.pitch, startSeconds: start, durationSeconds: seconds(end) - start, velocity: note.velocity))
        }
        for index in parts.indices {
            parts[index].notes.sort { $0.startSeconds == $1.startSeconds ? $0.pitch < $1.pitch : $0.startSeconds < $1.startSeconds }
        }
        let result = MIDIImport(parts: parts, duration: duration, initialTempo: 60_000_000 / Double(segments[0].micros), warnings: pitchBends ? ["Pitch-bend events are not reconstructed; MIDI notes retain their base pitches."] : [])
        try result.validate(maximumDuration: maximumDuration)
        return result
    }
}
