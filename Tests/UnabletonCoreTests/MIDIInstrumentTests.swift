import Foundation
import Testing
import AudioToolbox
@testable import UnabletonCore

private struct ExportedMIDI {
    var programs: [(channel: UInt8, program: UInt8)] = []
    var controls: [UInt8] = []
    var notes: [(channel: UInt8, pitch: UInt8, beat: Double, duration: Float32, velocity: UInt8)] = []
}

struct MIDIInstrumentTests {
    private func read(_ song: Song) throws -> ExportedMIDI {
        let data = try MIDIExporter.data(for: song)
        var sequence: MusicSequence?
        #expect(NewMusicSequence(&sequence) == noErr)
        let sequenceValue = try #require(sequence)
        defer { DisposeMusicSequence(sequenceValue) }
        #expect(MusicSequenceFileLoadData(sequenceValue, data as CFData, .midiType, []) == noErr)
        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(sequenceValue, &trackCount)
        var result = ExportedMIDI()
        for index in 0..<trackCount {
            var track: MusicTrack?
            #expect(MusicSequenceGetIndTrack(sequenceValue, index, &track) == noErr)
            let trackValue = try #require(track)
            var iterator: MusicEventIterator?
            #expect(NewMusicEventIterator(trackValue, &iterator) == noErr)
            let iteratorValue = try #require(iterator)
            defer { DisposeMusicEventIterator(iteratorValue) }
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iteratorValue, &hasEvent)
            while hasEvent.boolValue {
                var beat: MusicTimeStamp = 0, type: MusicEventType = 0
                var bytes: UnsafeRawPointer?, size: UInt32 = 0
                #expect(MusicEventIteratorGetEventInfo(iteratorValue, &beat, &type, &bytes, &size) == noErr)
                if let bytes, type == kMusicEventType_MIDINoteMessage {
                    let note = bytes.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                    result.notes.append((note.channel, note.note, beat, note.duration, note.velocity))
                } else if let bytes, type == kMusicEventType_MIDIChannelMessage {
                    let message = bytes.assumingMemoryBound(to: MIDIChannelMessage.self).pointee
                    if message.status & 0xF0 == 0xC0 { result.programs.append((message.status & 0x0F, message.data1)) }
                    if message.status & 0xF0 == 0xB0 { result.controls.append(message.data1) }
                }
                MusicEventIteratorNextEvent(iteratorValue)
                MusicEventIteratorHasCurrentEvent(iteratorValue, &hasEvent)
            }
        }
        return result
    }

    @Test func legacyProgramsAndGeneralMidiDrumChannelRemainUnchanged() throws {
        var song = Song()
        song.tracks = [
            Track(instrumentID: "sampled.guitar", clips: [Clip(notes: [NoteEvent(pitch: 60)])]),
            Track(instrumentID: "sampled.bass", clips: [Clip(notes: [NoteEvent(pitch: 40)])]),
            Track(instrumentID: "sampled.drums", clips: [Clip(notes: [NoteEvent(pitch: 36)])])
        ]
        let exported = try read(song)
        #expect(exported.programs.map(\.program) == [24, 33, 0])
        #expect(exported.notes.map(\.pitch) == [60, 40, 36])
        #expect(exported.notes.map(\.channel) == [0, 1, 9])
        #expect(exported.controls.isEmpty)
    }

    @Test func declaredGeneralMidiProgramDoesNotUseNativeBankProgram() throws {
        let preset = try #require(InstrumentCatalog.presets.first {
            $0.soundBankID != nil && $0.category != "Drums" && $0.gmProgram != nil && $0.gmProgram != $0.program
        })
        var song = Song()
        let pitch = preset.supportedPitches?.first ?? preset.minimumPitch
        song.tracks = [Track(instrumentID: preset.id, clips: [Clip(startBeat: 2, notes: [NoteEvent(pitch: pitch, startBeat: 0.25, duration: 0.75, velocity: 91)])])]
        let exported = try read(song)
        #expect(exported.programs.count == 1)
        #expect(exported.programs.first?.program == preset.gmProgram)
        #expect(exported.controls.isEmpty)
        let note = try #require(exported.notes.first)
        #expect(note.pitch == pitch && note.beat == 2.25 && note.duration == 0.75 && note.velocity == 91)
    }

    @Test func nativePercussionRetainsRawPitchesWithoutSpeculativeProgram() throws {
        let preset = try #require(InstrumentCatalog.presets.first {
            $0.soundBankID != nil && $0.category == "Drums" && $0.gmProgram == nil && $0.pitchMap == nil
        })
        let pitch = try #require(preset.supportedPitches?.first)
        var song = Song()
        song.tracks = [Track(instrumentID: preset.id, clips: [Clip(notes: [NoteEvent(pitch: pitch, startBeat: 1.5, duration: 0.25, velocity: 95)])])]
        let exported = try read(song)
        #expect(exported.programs.isEmpty)
        let note = try #require(exported.notes.first)
        #expect(note.channel == 0 && note.pitch == pitch)
        #expect(note.beat == 1.5 && note.duration == 0.25 && note.velocity == 95)
    }
}
