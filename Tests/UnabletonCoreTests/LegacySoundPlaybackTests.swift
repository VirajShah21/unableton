import Foundation
import Testing
import UnabletonCore

struct LegacySoundPlaybackTests {
    @Test func oldDrumNotesRoundTripButUnsupportedNativeRegionsFailExplicitly() throws {
        var file = ProjectFile()
        file.song.tracks = [Track(instrumentID: "sampled.drums", clips: [Clip(notes: [NoteEvent(pitch: 42)])])]
        let package = try ProjectArchive.encode(project: file, assets: [:])
        #expect(try ProjectArchive.decode(package).project == file)
        #expect(try !MIDIExporter.data(for: file.song).isEmpty)
        #expect(throws: ProjectError.self) { try InstrumentResources.validatePlayback(in: file.song) }
        file.song.tracks[0].isMuted = true
        try InstrumentResources.validatePlayback(in: file.song)
        file.song.tracks[0].isMuted = false
        file.song.tracks[0].clips[0].notes[0].pitch = 36
        try InstrumentResources.validatePlayback(in: file.song)
    }
}
