import Foundation
import Testing
@testable import UnabletonCore

struct ClipFadeTests {
    private func song() -> Song {
        var song = Song(); song.tempo = 120
        let asset = AudioAsset(fileName: "song.wav", duration: 10, sampleRate: 48_000, channels: 2)
        song.assets = [asset]
        song.tracks = [Track(kind: .audio, clips: [Clip(kind: .audio, lengthBeats: 8, assetID: asset.id)])]
        return song
    }

    @Test func fadesValidateTransactionallyAndSurviveSplitTrim() throws {
        var song = song()
        let id = song.tracks[0].clips[0].id
        try ProjectEditor.apply([ProjectCommand(op: .setClipFades, clipID: id, startBeat: 2, lengthBeats: 2)], to: &song)
        #expect(song.tracks[0].clips[0].fadeInBeats == 2)
        let before = song
        #expect(throws: ProjectError.self) {
            try ProjectEditor.apply([ProjectCommand(op: .setClipFades, clipID: id, startBeat: 7, lengthBeats: 2)], to: &song)
        }
        #expect(song == before)
        try ProjectEditor.apply([ProjectCommand(op: .splitClip, clipID: id, startBeat: 4)], to: &song)
        #expect(song.tracks[0].clips[0].fadeInBeats == 2)
        #expect(song.tracks[0].clips[0].fadeOutBeats == nil)
        #expect(song.tracks[0].clips[1].fadeInBeats == nil)
        #expect(song.tracks[0].clips[1].fadeOutBeats == 2)
        try ProjectEditor.apply([ProjectCommand(op: .trimClip, clipID: id, lengthBeats: 1)], to: &song)
        #expect(song.tracks[0].clips[0].fadeInBeats == 1)
        try ProjectEditor.validate(song)
    }
}
