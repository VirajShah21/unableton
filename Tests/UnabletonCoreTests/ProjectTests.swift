import Foundation
import Testing
import AudioToolbox
@testable import UnabletonCore

struct ProjectTests {
    func song() -> Song {
        var song = Song()
        song.tracks = [Track(name: "Lead", clips: [Clip(name: "Phrase", lengthBeats: 8, notes: [NoteEvent(pitch: 60, startBeat: 1, duration: 4, velocity: 90)])])]
        return song
    }
    @Test func invalidBatchIsAtomic() throws {
        var edited = song(); let original = edited, id = edited.tracks[0].id
        #expect(throws: ProjectError.self) { try ProjectEditor.apply([.init(op: .renameTrack, trackID: id, text: "Changed"), .init(op: .setTempo, value: .nan)], to: &edited) }
        #expect(edited == original)
    }
    @Test func oneBatchOneRevision() throws {
        var edited = song(); let id = edited.tracks[0].id
        try ProjectEditor.apply([.init(op: .renameTrack, trackID: id, text: "Bass"), .init(op: .setInstrument, trackID: id, text: "synth.bass")], to: &edited)
        #expect(edited.revision == 1)
        #expect(edited.tracks[0].effectiveParameters["lfoDepth"] == 0.55)
    }
    @Test func duplicatedPartsGetIndependentIDs() throws {
        var edited = song(); let id = edited.tracks[0].id
        try ProjectEditor.apply([.init(op: .duplicateTrack, trackID: id)], to: &edited)
        #expect(edited.tracks.count == 2)
        #expect(edited.tracks[0].id != edited.tracks[1].id)
        #expect(edited.tracks[0].clips[0].id != edited.tracks[1].clips[0].id)
        #expect(edited.tracks[0].clips[0].notes[0].id != edited.tracks[1].clips[0].notes[0].id)
    }
    @Test func movingToIncompatibleTrackDoesNotLoseClip() throws {
        var edited = song(); edited.tracks.append(Track(name: "Audio", kind: .audio))
        let original = edited, clip = edited.tracks[0].clips[0].id, target = edited.tracks[1].id
        #expect(throws: ProjectError.self) { try ProjectEditor.apply([.init(op: .moveClip, clipID: clip, targetTrackID: target, startBeat: 4)], to: &edited) }
        #expect(edited == original)
    }
    @Test func splittingPreservesSustainedNote() throws {
        var edited = song(); let clip = edited.tracks[0].clips[0].id
        try ProjectEditor.apply([.init(op: .splitClip, clipID: clip, startBeat: 3)], to: &edited)
        let clips = edited.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].lengthBeats == 3)
        #expect(clips[0].notes[0].duration == 2)
        #expect(clips[1].startBeat == 3)
        #expect(clips[1].notes[0].startBeat == 0)
        #expect(clips[1].notes[0].duration == 2)
        #expect(clips[0].notes[0].id != clips[1].notes[0].id)
    }
    @Test func audioTrimKeepsSourceOffset() throws {
        var edited = Song(); edited.tempo = 120
        let asset = AudioAsset(fileName: "take.wav", duration: 12, sampleRate: 48000, channels: 1)
        let clip = Clip(kind: .audio, startBeat: 2, lengthBeats: 16, assetID: asset.id)
        let track = Track(kind: .audio, clips: [clip])
        edited.assets = [asset]; edited.tracks = [track]
        try ProjectEditor.apply([.init(op: .trimClip, clipID: clip.id, startBeat: 6, lengthBeats: 8)], to: &edited)
        #expect(edited.tracks[0].clips[0].sourceOffsetSeconds == 2)
        #expect(edited.tracks[0].clips[0].startBeat == 6)
    }
    @Test func outOfRangePitchAndUnknownParameterRejected() throws {
        var edited = song(); let original = edited, track = edited.tracks[0].id, clip = edited.tracks[0].clips[0].id
        #expect(throws: ProjectError.self) { try ProjectEditor.apply([.init(op: .transpose, clipID: clip, value: 100)], to: &edited) }
        #expect(throws: ProjectError.self) { try ProjectEditor.apply([.init(op: .setParameter, trackID: track, value: 1, text: "imaginary")], to: &edited) }
        #expect(edited == original)
    }
    @Test func quantizeAndRepeatAreRealEdits() throws {
        var edited = song(); let clip = edited.tracks[0].clips[0].id
        edited.tracks[0].clips[0].notes[0].startBeat = 1.13
        try ProjectEditor.apply([.init(op: .quantize, clipID: clip, value: 0.25), .init(op: .repeatClip, clipID: clip, index: 2)], to: &edited)
        #expect(edited.tracks[0].clips[0].notes[0].startBeat == 1.25)
        #expect(edited.tracks[0].clips.map(\.startBeat) == [0, 8, 16])
    }
    @Test func projectPackageRoundTripIncludesAudioAndChats() throws {
        var file = ProjectFile(); let bytes = Data([1,2,3,4])
        let asset = AudioAsset(fileName: "recording.wav", duration: 2, sampleRate: 48000, channels: 1)
        file.song.assets = [asset]
        file.song.tracks = [Track(name: "Voice", kind: .audio, clips: [Clip(kind: .audio, lengthBeats: 4, assetID: asset.id)])]
        file.conversations[0].messages = [ChatMessage(role: "user", text: "Keep the melody")]
        file.conversations[0].responseItems = [.object(["type": .string("reasoning"), "encrypted_content": .string("opaque")])]
        let package = try ProjectArchive.encode(project: file, assets: [asset.id: bytes])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".unableton")
        defer { try? FileManager.default.removeItem(at: url) }
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
        let result = try ProjectArchive.decode(FileWrapper(url: url, options: .immediate))
        #expect(result.project.song == file.song)
        #expect(result.project.conversations[0].responseItems == file.conversations[0].responseItems)
        #expect(result.assets[asset.id] == bytes)
        #expect(result.project.conversations[0].messages[0].text == "Keep the melody")
    }
    @Test func packageRejectsMissingAudioAndUnsafeName() throws {
        var file = ProjectFile()
        file.song.assets = [AudioAsset(fileName: "take.wav", duration: 1, sampleRate: 48000, channels: 1)]
        #expect(throws: ProjectError.self) { try ProjectArchive.encode(project: file, assets: [:]) }
        file.song.assets[0].fileName = "../other.wav"
        #expect(throws: ProjectError.self) { try ProjectEditor.validate(file.song) }
    }
    @Test func midiLoadsAsStandardMultitrackFile() throws {
        var edited = song(); edited.tempo = 123
        edited.tracks.append(Track(name: "Drums", instrumentID: "drums.electronic", clips: [Clip(notes: [NoteEvent(pitch: 36, duration: 0.25)])]))
        let data = try MIDIExporter.data(for: edited)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "MThd")
        var sequence: MusicSequence?
        #expect(NewMusicSequence(&sequence) == noErr)
        guard let sequence else { return }
        defer { DisposeMusicSequence(sequence) }
        #expect(MusicSequenceFileLoadData(sequence, data as CFData, .midiType, []) == noErr)
        var count: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &count)
        #expect(count == 2)
    }
}
