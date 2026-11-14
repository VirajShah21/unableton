import Foundation
import Testing
@testable import UnabletonCore

struct MusicalAnalysisTests {
    private func project() -> Song {
        var song = Song(); song.lengthBars = 8
        song.tracks = [
            Track(name: "Melody", clips: [Clip(lengthBeats: 8, notes: [NoteEvent(pitch: 60), NoteEvent(pitch: 67, startBeat: 2)])]),
            Track(name: "Bass", instrumentID: "synth.bass", clips: [Clip(lengthBeats: 8, notes: [NoteEvent(pitch: 36, duration: 4)])])
        ]
        return song
    }

    @Test func bassEditProvesWhichMelodyAndNotesAreUnchanged() throws {
        let before = project()
        var after = before
        after.tracks[1].clips[0].notes[0].pitch = 38; after.revision += 1
        let report = MusicalAnalyzer.analyze(before: before, after: after,
            selection: .init(trackID: before.tracks[1].id, clipID: before.tracks[1].clips[0].id))
        #expect(report.changes.tracks.changedIDs == [before.tracks[1].id])
        #expect(report.changes.tracks.unchangedIDs == [before.tracks[0].id])
        #expect(report.changes.clips.unchangedIDs == [before.tracks[0].clips[0].id])
        #expect(report.changes.noteChangedClipIDs == [before.tracks[1].clips[0].id])
        #expect(report.changes.selectedTrackChanged == true)
        #expect(report.changes.selectedClipChanged == true)
        #expect(report.changes.globalFields.isEmpty)
        #expect(report.after.tracks[1].minimumPitch == 38)
        #expect(report.after.tracks[1].pitchClassCounts[2] == 1)
        #expect(before.tracks[1].clips[0].notes[0].pitch == 36)
    }

    @Test func mixingChangesDoNotClaimNoteChangesAndMovesKeepTheirIdentity() {
        let before = project()
        var after = before
        after.tracks[0].volume = 0.3
        after.tracks[1].clips.append(after.tracks[0].clips.removeFirst())
        let report = MusicalAnalyzer.analyze(before: before, after: after, selection: .init())
        #expect(report.changes.tracks.changedCount == 2)
        #expect(report.changes.clips.changedIDs == [before.tracks[0].clips[0].id])
        #expect(report.changes.clips.addedCount == 0 && report.changes.clips.deletedCount == 0)
        #expect(report.changes.noteChangedClipCount == 0)
        #expect(report.changes.selectedTrackChanged == nil)
    }

    @Test func identitiesAndGlobalFieldChangesAreReportedExactly() {
        let before = project()
        var after = before
        after.tracks[0].clips[0].notes[0].id = UUID()
        after.tracks.reverse(); after.tempo = 145; after.key = "D minor"
        let report = MusicalAnalyzer.analyze(before: before, after: after, selection: .init())
        #expect(report.changes.trackOrderChanged)
        #expect(report.changes.globalFields == ["tempo", "key"])
        #expect(report.changes.noteChangedClipIDs == [before.tracks[0].clips[0].id])
        #expect(report.changes.tracks.changedIDs == [before.tracks[0].id])
    }

    @Test func muteSoloAndZeroVolumeAffectEffectiveActivity() {
        var song = project()
        song.tracks[0].isSolo = true
        song.tracks.append(Track(name: "Solo but muted", isMuted: true, isSolo: true,
            clips: [Clip(notes: [NoteEvent()])]))
        song.tracks.append(Track(name: "Solo but zero", volume: 0, isSolo: true,
            clips: [Clip(notes: [NoteEvent()])]))
        let report = MusicalAnalyzer.analyze(before: song, after: song, selection: .init())
        #expect(report.after.tracks.map(\.isAudible) == [true, false, false, false])
        #expect(report.after.audibleTrackCount == 1)
        #expect(report.after.windows[0].activeTrackCount == 4)
        #expect(report.after.windows[0].audibleActiveTrackCount == 1)
        #expect(report.after.windows[0].audibleNoteOnsets == 2)
        #expect(report.after.windows[0].noteOnsets == 5)
    }

    @Test func coverageUsesIntervalUnionsAndClipsLongNotesAtTheClipBoundary() {
        var song = Song(); song.lengthBars = 4
        song.tracks = [Track(clips: [
            Clip(startBeat: 2, lengthBeats: 4, notes: [NoteEvent(startBeat: 0, duration: 20), NoteEvent(startBeat: 1, duration: 2)]),
            Clip(startBeat: 4, lengthBeats: 4, notes: [NoteEvent(duration: 4)])
        ])]
        let report = MusicalAnalyzer.analyze(before: song, after: song, selection: .init())
        #expect(report.after.activeBeats == 6)
        #expect(report.after.tracks[0].activeBeats == 6)
        #expect(report.after.windows[0].activeBeats == 6)
        #expect(report.after.noteCount == 3)
    }

    @Test func catalogDeterminesDrumsAndSavedProvenanceDeterminesVocals() throws {
        var song = Song(); song.tempo = 120; song.lengthBars = 4
        let guide = Clip(lengthBeats: 4, notes: [NoteEvent(pitch: 60)])
        let score = try VocalScore.make(clip: guide, tempo: 120, beatsPerBar: 4, lyrics: ["La"])
        let vocal = AudioAsset(fileName: "take.wav", duration: 10, sampleRate: 48000, channels: 1,
            vocalTake: VocalTake(provider: "test", singerID: "voice", sourceClipID: guide.id, score: score))
        let unknown = AudioAsset(fileName: "singer.wav", duration: 10, sampleRate: 48000, channels: 1)
        song.assets = [vocal, unknown]
        song.tracks = [
            Track(name: "Not called drums", instrumentID: "drums.electronic", clips: [Clip(notes: [NoteEvent(pitch: 36), NoteEvent(pitch: 38, startBeat: 2)])]),
            Track(name: "Drums and vocals", clips: [guide]),
            Track(name: "Audio", kind: .audio, clips: [
                Clip(kind: .audio, startBeat: 4, lengthBeats: 16, assetID: vocal.id, sourceOffsetSeconds: 8),
                Clip(kind: .audio, startBeat: 6, lengthBeats: 2, assetID: vocal.id, sourceOffsetSeconds: 9),
                Clip(name: "Vocals", kind: .audio, startBeat: 10, lengthBeats: 2, assetID: unknown.id)
            ])
        ]
        let report = MusicalAnalyzer.analyze(before: song, after: song, selection: .init())
        #expect(report.after.drumNoteCount == 2)
        #expect(report.after.tracks[0].isDrums)
        #expect(report.after.tracks[0].pitchClassCounts == Array(repeating: 0, count: 12))
        #expect(!report.after.tracks[1].isDrums)
        #expect(report.after.generatedVocalBeats == 4)
        #expect(report.after.tracks[2].activeBeats == 6)
        #expect(report.after.windows[0].generatedVocalBeats == 4)
        #expect(report.after.windows[0].drumOnsets == 2)
    }

    @Test func repeatedPatternsIgnoreIDsPlacementNamesAndArrayOrdering() {
        var song = project()
        let original = song.tracks[0].clips[0]
        let copy = Clip(name: "Other name", startBeat: 8, lengthBeats: original.lengthBeats,
            notes: original.notes.reversed().map { NoteEvent(pitch: $0.pitch, startBeat: $0.startBeat, duration: $0.duration, velocity: $0.velocity) })
        song.tracks[0].clips.append(copy)
        var variant = copy; variant.id = UUID(); variant.startBeat = 16; variant.notes[0].velocity -= 1
        for index in variant.notes.indices { variant.notes[index].id = UUID() }
        song.tracks[0].clips.append(variant)
        let report = MusicalAnalyzer.analyze(before: song, after: song, selection: .init())
        #expect(report.after.tracks[0].distinctNotePatterns == 2)
        #expect(report.after.tracks[0].repeatedNoteClipCount == 1)
    }

    @Test func longSongsAndLargeIDListsStayBoundedAndSerializeDeterministically() throws {
        var song = Song(); song.lengthBars = 4096
        song.tracks = [Track(clips: (0..<300).map { Clip(startBeat: Double($0 * 16)) })]
        let report = MusicalAnalyzer.analyze(before: song, after: song, selection: .init())
        #expect(report.after.windows.count == MusicalAnalyzer.maximumWindows)
        #expect(report.after.windows.first?.lengthBeats == 512)
        #expect(report.changes.clips.unchangedCount == 300)
        #expect(report.changes.clips.unchangedIDs.count == MusicalAnalyzer.maximumReportedIDs)
        #expect(report.changes.idsTruncated)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(report)
        let repeated = try encoder.encode(MusicalAnalyzer.analyze(before: song, after: song, selection: .init()))
        #expect(encoded == repeated)
        #expect(try JSONDecoder().decode(MusicalAnalysisReport.self, from: encoded) == report)
        #expect(encoded.count < 40_000)
    }

    @Test func pathologicalNoteCountsRetainExactTotalsAndExposePartialDetails() {
        var song = Song()
        song.tracks = [Track(clips: (0..<5).map { _ in
            Clip(lengthBeats: 16, notes: (0..<65_536).map { NoteEvent(startBeat: Double($0 % 1024) / 1024, duration: 0.01) })
        })]
        let report = MusicalAnalyzer.analyze(before: Song(), after: song, selection: .init())
        #expect(report.after.noteCount == 327_680)
        #expect(report.after.analyzedNoteCount == MusicalAnalyzer.maximumAnalyzedNotes)
        #expect(report.after.truncated)
        #expect(report.after.tracks[0].truncated)
        #expect(report.after.tracks[0].noteCount == 327_680)
        #expect(report.changes.clips.addedCount == 5)
    }
}
