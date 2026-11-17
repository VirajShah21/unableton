import Foundation
import Testing
@testable import UnabletonCore

struct MIDIImporterTests {
    private func variable(_ value: Int) -> [UInt8] {
        var value = value, bytes = [UInt8(value & 0x7f)]
        while value > 127 { value >>= 7; bytes.insert(UInt8(value & 0x7f) | 0x80, at: 0) }
        return bytes
    }
    private func event(_ delta: Int, _ bytes: [UInt8]) -> [UInt8] { variable(delta) + bytes }
    private func file(_ tracks: [[UInt8]], format: UInt8 = 1, division: UInt16 = 480) -> Data {
        var bytes: [UInt8] = Array("MThd".utf8) + [0,0,0,6,0,format,0,UInt8(tracks.count),UInt8(division >> 8),UInt8(division & 255)]
        for track in tracks {
            let count = UInt32(track.count)
            bytes += Array("MTrk".utf8) + [UInt8(count >> 24),UInt8((count >> 16) & 255),UInt8((count >> 8) & 255),UInt8(count & 255)] + track
        }
        return Data(bytes)
    }
    private let end: [UInt8] = [0,0xff,0x2f,0]

    @Test func tempoMapPreservesLeadingSilenceAndCrossTempoDuration() throws {
        let tempo = event(0, [0xff,0x51,3,0x07,0xa1,0x20]) + event(480, [0xff,0x51,3,0x0f,0x42,0x40]) + event(480, [0xff,0x2f,0])
        let notes = event(0, [0xff,3,4] + Array("Lead".utf8)) + event(240, [0x90,60,90]) + event(720, [0x80,60,0]) + end
        let result = try MIDIImporter.parse(file([tempo, notes]))
        #expect(result.initialTempo == 120)
        #expect(result.duration == 1.5)
        let part = try #require(result.parts.first)
        #expect(part.name == "Lead")
        #expect(part.notes == [MIDITimedNote(pitch: 60, startSeconds: 0.25, durationSeconds: 1.25, velocity: 90)])
    }

    @Test func runningStatusAndVelocityZeroTerminateNotes() throws {
        let track = event(0, [0x90,60,100]) + event(120, [62,80]) + event(120, [60,0]) + event(120, [62,0]) + end
        let result = try MIDIImporter.parse(file([track], format: 0))
        #expect(result.parts[0].notes.count == 2)
        #expect(result.parts[0].notes[0].durationSeconds == 0.25)
        #expect(result.parts[0].notes[1].startSeconds == 0.125)
        #expect(result.parts[0].notes[1].durationSeconds == 0.25)
    }

    @Test func sustainHoldsReleasedNotesUntilPedalUp() throws {
        let track = event(0, [0xb0,64,127]) + event(0, [0x90,60,90]) + event(480, [0x80,60,0]) + event(480, [0xb0,64,0]) + end
        let result = try MIDIImporter.parse(file([track], format: 0))
        #expect(result.parts[0].notes[0].durationSeconds == 1)
    }

    @Test func controllerResetReleasesSustainedNotes() throws {
        let track = event(0, [0xb0,64,127]) + event(0, [0x90,60,90]) + event(240, [0x80,60,0]) + event(240, [0xb0,121,0]) + event(480, [0xff,0x2f,0])
        let result = try MIDIImporter.parse(file([track], format: 0))
        #expect(result.parts[0].notes[0].durationSeconds == 0.5)
    }

    @Test func percussionAndProgramChangesKeepIndependentParts() throws {
        let track = event(0, [0xc0,4]) + event(0, [0x90,60,90]) + event(120, [0x80,60,0]) + event(0, [0xc0,5]) + event(0, [0x90,62,90]) + event(120, [0x80,62,0]) + event(0, [0x99,36,110]) + event(120, [0x89,36,0]) + end
        let first = try MIDIImporter.parse(file([track], format: 0))
        let second = try MIDIImporter.parse(file([track], format: 0))
        #expect(first == second)
        #expect(first.parts.map(\.program) == [4,5,0])
        #expect(first.parts.map(\.isPercussion) == [false,false,true])
        #expect(first.parts.last?.notes.first?.pitch == 36)
    }

    @Test func malformedAndUnsupportedFilesFailWithoutPartialOutput() throws {
        let valid = event(0, [0x90,60,90]) + event(480, [0x80,60,0]) + end
        #expect(throws: ProjectError.self) { try MIDIImporter.parse(file([valid], format: 2)) }
        #expect(throws: ProjectError.self) { try MIDIImporter.parse(file([valid], format: 0, division: 0xe728)) }
        #expect(throws: ProjectError.self) { try MIDIImporter.parse(file([Array(valid.dropLast())], format: 0)) }
        #expect(throws: ProjectError.self) { try MIDIImporter.parse(file([event(0, [60,90]) + end], format: 0)) }
        #expect(throws: ProjectError.self) { try MIDIImporter.parse(file([event(0, [0xff,0x51,3,0,0,0]) + valid], format: 0)) }
        #expect(throws: ProjectError.self) { try MIDIImporter.parse(file([valid], format: 0), maximumDuration: 0.1) }
    }

    @Test func referenceStemProvenanceIsOptionalBoundedAndRoundTrips() throws {
        var value = MIDIImport(parts: [.init(id: "bass:0", name: "Bass", channel: 0, program: 0, isPercussion: false,
            notes: [.init(pitch: 45, startSeconds: 0, durationSeconds: 1, velocity: 90)], referenceStem: "bass")], duration: 1, initialTempo: 120)
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(MIDIImport.self, from: encoded) == value)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var parts = try #require(legacy["parts"] as? [[String: Any]])
        parts[0].removeValue(forKey: "referenceStem"); legacy["parts"] = parts
        let decoded = try JSONDecoder().decode(MIDIImport.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.parts[0].referenceStem == nil)
        try decoded.validate()
        value.parts[0].referenceStem = "untrusted-stem"
        #expect(throws: ProjectError.self) { try value.validate() }
    }

    @Test func hostValidationRejectsInventedOrNonfiniteMeasuredEvents() throws {
        let invalid = MIDIImport(parts: [.init(id: "1", name: "Lead", channel: 0, program: 0, isPercussion: false,
                                              notes: [.init(pitch: 60, startSeconds: .nan, durationSeconds: 1, velocity: 90)])], duration: 2, initialTempo: 120)
        #expect(throws: ProjectError.self) { try invalid.validate() }
    }
}
