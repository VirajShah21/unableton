import Foundation
import Testing
@testable import UnabletonCore

struct InstrumentResourceTests {
    @Test func songSerializationAndMidiDoNotDependOnInstalledSounds() throws {
        var original = ProjectFile()
        original.song.tracks = [
            Track(instrumentID: "sampled.piano", parameters: ["cutoff": 4000], clips: [Clip(notes: [NoteEvent(pitch: 60)])]),
            Track(instrumentID: "sampled.drums", clips: [Clip(notes: [NoteEvent(pitch: 36)])])
        ]
        let before = try MIDIExporter.data(for: original.song)
        let package = try ProjectArchive.encode(project: original, assets: [:])
        let decoded = try ProjectArchive.decode(package).project
        #expect(decoded == original)
        #expect(decoded.formatVersion == 1)
        #expect(try MIDIExporter.data(for: decoded.song) == before)
        #expect(String(decoding: before.prefix(4), as: UTF8.self) == "MThd")
        let json = try #require(package.fileWrappers?["project.json"]?.regularFileContents)
        let text = String(decoding: json, as: UTF8.self)
        #expect(!text.contains("SoundLibrary"))
        #expect(!text.contains("installed"))
        #expect(!text.contains("downloadBytes"))
        var edited = decoded.song
        try ProjectEditor.apply([.init(op: .setTempo, value: 100)], to: &edited)
        #expect(edited.tempo == 100)
        #expect(edited.tracks == original.song.tracks)
    }

    @Test func requiredResourcesFollowAudioTrackMuteAndSoloRules() {
        var song = Song()
        song.tracks = [Track(instrumentID: "sampled.piano"), Track(kind: .audio), Track(instrumentID: "synth.lead", isMuted: true)]
        #expect(InstrumentResources.requiredIDs(in: song) == ["sampled.piano"])
        song.tracks[1].isSolo = true
        #expect(InstrumentResources.requiredIDs(in: song).isEmpty)
        song.tracks[0].isSolo = true
        #expect(InstrumentResources.requiredIDs(in: song) == ["sampled.piano"])
        song.tracks[0].isMuted = true
        #expect(InstrumentResources.requiredIDs(in: song).isEmpty)
    }
}
