import Foundation
import Testing
@testable import UnabletonCore

struct TranscriptionArrangementTests {
    private func transcript(mode: TranscriptionMode = .humming) -> PerformanceTranscript {
        PerformanceTranscript(mode: mode, events: [
            TranscribedEvent(pitch: mode == .beatboxing ? 36 : 60, startSeconds: 0.25, durationSeconds: 0.2, velocity: 0.7, confidence: 0.92),
            TranscribedEvent(pitch: mode == .beatboxing ? 38 : 67, startSeconds: 1.25, durationSeconds: 0.2, velocity: 0.4, confidence: 0.86)
        ], duration: 2, warnings: ["Review detected events."])
    }

    private func timingPlan(_ transcript: PerformanceTranscript, tempo: Double = 120) throws -> TranscriptionArrangementPlan {
        .init(timingChanges: try transcript.notes(tempo: tempo).map {
            TranscriptionTimingChange(sourceEventID: $0.id, startBeat: $0.startBeat, duration: $0.duration)
        })
    }

    private func tracks(plan: TranscriptionArrangementPlan = .init(), transcript: PerformanceTranscript, options: TranscriptionOptions, song: Song = Song()) throws -> [Track] {
        try TranscriptionArrangementBuilder.commands(plan: plan, transcript: transcript, options: options, song: song).compactMap(\.track)
    }

    @Test func preserveTimeCopiesOnlyDetectedEventsUsingCurrentTempoAndDistinctIDs() throws {
        var song = Song(); song.tempo = 137
        song.tracks = [Track(name: "Existing", clips: [Clip(notes: [NoteEvent(pitch: 72, startBeat: 3, duration: 0.75)])])]
        let original = song
        var take = transcript()
        take.events.reverse()
        take.events[0].startSeconds = 1.031; take.events[0].durationSeconds = 0.414
        take.events[1].startSeconds = 0.117; take.events[1].durationSeconds = 0.363
        let layers = [TranscriptionLayer(name: "Lead", instrumentID: "synth.lead"), TranscriptionLayer(name: "Pluck", instrumentID: "synth.pluck")]
        let options = TranscriptionOptions(insertionBeat: 8.375, layers: layers)
        let commands = try TranscriptionArrangementBuilder.commands(plan: .init(), transcript: take, options: options, song: song)
        #expect(!options.requiresAI)
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.op == .addTrack })
        let generated = commands.compactMap(\.track)
        let expected = try take.notes(tempo: song.tempo)
        for track in generated {
            let clip = try #require(track.clips.first)
            #expect(clip.startBeat == options.insertionBeat)
            #expect(clip.lengthBeats == take.duration * song.tempo / 60)
            #expect(clip.notes.count == take.events.count)
            for (note, source) in zip(clip.notes, expected) {
                let measured = try #require(take.events.first(where: { $0.id == source.id }))
                #expect(note.pitch == source.pitch)
                #expect(note.startBeat == source.startBeat)
                #expect(note.duration == source.duration)
                #expect(note.velocity == source.velocity)
                #expect(note.id != source.id)
                #expect(abs(note.startBeat * 60 / song.tempo - measured.startSeconds) < 1e-12)
            }
        }
        let firstIDs = Set(generated[0].clips[0].notes.map(\.id))
        #expect(firstIDs.isDisjoint(with: generated[1].clips[0].notes.map(\.id)))
        #expect(generated[0].id != generated[1].id)
        #expect(generated[0].clips[0].id != generated[1].clips[0].id)
        var draft = song
        try ProjectEditor.apply(commands, to: &draft)
        #expect(song == original)
        #expect(draft.tracks[0] == original.tracks[0])
        #expect(draft.tempo == original.tempo)
        #expect(draft.assets == original.assets)
    }

    @Test func preserveTimeRejectsAnyAITimingChangesAndDuplicateSourceEvents() throws {
        let take = transcript()
        #expect(throws: ProjectError.self) {
            try TranscriptionArrangementBuilder.validate(plan: timingPlan(take), transcript: take, options: .init(), song: Song())
        }
        var duplicate = take
        duplicate.events[1].id = duplicate.events[0].id
        #expect(throws: TranscriptionError.self) {
            try TranscriptionArrangementBuilder.validate(plan: .init(), transcript: duplicate, options: .init(), song: Song())
        }
    }

    @Test func autoTimeRequiresEveryKnownSourceEventExactlyOnce() throws {
        let take = transcript(), options = TranscriptionOptions(timing: .autoTime)
        let valid = try timingPlan(take)
        var missing = valid; missing.timingChanges.removeLast()
        var duplicate = valid; duplicate.timingChanges[1].sourceEventID = duplicate.timingChanges[0].sourceEventID
        var unknown = valid; unknown.timingChanges[0].sourceEventID = UUID()
        for invalid in [missing, duplicate, unknown] {
            #expect(throws: ProjectError.self) {
                try TranscriptionArrangementBuilder.validate(plan: invalid, transcript: take, options: options, song: Song())
            }
        }
    }

    @Test func minorAdjustmentsAllowQuarterBeatBoundaryButRejectLargerChanges() throws {
        let take = transcript()
        var song = Song(); song.tempo = 120
        let options = TranscriptionOptions(timing: .autoTime, adjustment: .minor)
        var plan = try timingPlan(take)
        plan.timingChanges[0].startBeat += 0.25; plan.timingChanges[0].duration += 0.25
        plan.timingChanges[1].startBeat -= 0.25; plan.timingChanges[1].duration -= 0.25
        let generated = try tracks(plan: plan, transcript: take, options: options, song: song)
        #expect(generated[0].clips[0].notes.map(\.startBeat) == plan.timingChanges.map(\.startBeat))
        #expect(generated[0].clips[0].notes.map(\.pitch) == take.events.map(\.pitch))
        var invalidOnset = plan; invalidOnset.timingChanges[0].startBeat += 0.0001
        var invalidDuration = plan; invalidDuration.timingChanges[0].duration += 0.0001
        var nonfinite = plan; nonfinite.timingChanges[0].startBeat = .nan
        var emptyDuration = plan; emptyDuration.timingChanges[0].duration = 0
        for invalid in [invalidOnset, invalidDuration, nonfinite, emptyDuration] {
            #expect(throws: ProjectError.self) {
                try TranscriptionArrangementBuilder.validate(plan: invalid, transcript: take, options: options, song: song)
            }
        }
    }

    @Test func majorAdjustmentsFitSectionAndPreserveMelodyOrderWithoutOverlaps() throws {
        let take = transcript()
        var song = Song(); song.tempo = 120
        let options = TranscriptionOptions(timing: .autoTime, adjustment: .major, targetLengthBeats: 8)
        var valid = try timingPlan(take)
        valid.timingChanges[0].startBeat = 0; valid.timingChanges[0].duration = 1
        valid.timingChanges[1].startBeat = 7.5; valid.timingChanges[1].duration = 0.5
        let generated = try tracks(plan: valid, transcript: take, options: options, song: song)
        #expect(generated[0].clips[0].lengthBeats == 8)
        #expect(generated[0].clips[0].notes.map(\.pitch) == take.events.map(\.pitch))
        var beyond = valid; beyond.timingChanges[1].duration = 0.5001
        var reordered = valid; reordered.timingChanges[0].startBeat = 3; reordered.timingChanges[1].startBeat = 2
        var overlapping = valid; overlapping.timingChanges[0].duration = 2.5; overlapping.timingChanges[1].startBeat = 2
        for invalid in [beyond, reordered, overlapping] {
            #expect(throws: ProjectError.self) {
                try TranscriptionArrangementBuilder.validate(plan: invalid, transcript: take, options: options, song: song)
            }
        }
    }

    @Test func drumAutoTimingAllowsOverlappingDecaysButRetainsHitOrder() throws {
        let take = transcript(mode: .beatboxing)
        var song = Song(); song.tempo = 120
        let layer = TranscriptionLayer(instrumentID: "drums.electronic")
        let options = TranscriptionOptions(timing: .autoTime, adjustment: .major, targetLengthBeats: 4, layers: [layer])
        var plan = try timingPlan(take)
        plan.timingChanges[0].startBeat = 0; plan.timingChanges[0].duration = 2
        plan.timingChanges[1].startBeat = 1; plan.timingChanges[1].duration = 1
        let generated = try tracks(plan: plan, transcript: take, options: options, song: song)
        #expect(generated[0].clips[0].notes.map(\.pitch) == [36, 38])
        plan.timingChanges[0].startBeat = 1.5
        #expect(throws: ProjectError.self) {
            try TranscriptionArrangementBuilder.validate(plan: plan, transcript: take, options: options, song: song)
        }
    }

    @Test func accompanimentMustMatchTheRequestedLayerIDsExactly() throws {
        let take = transcript()
        let performance = TranscriptionLayer(), drums = TranscriptionLayer(name: "Drums", instrumentID: "drums.electronic", role: .drums)
        let bass = TranscriptionLayer(name: "Bass", instrumentID: "synth.bass", role: .bass)
        let options = TranscriptionOptions(targetLengthBeats: 4, layers: [performance, drums, bass])
        let drumNotes = TranscriptionLayerNotes(layerID: drums.id, notes: [NoteEvent(pitch: 36, startBeat: 0, duration: 0.25)])
        let bassNotes = TranscriptionLayerNotes(layerID: bass.id, notes: [NoteEvent(pitch: 36, startBeat: 0, duration: 1)])
        let valid = TranscriptionArrangementPlan(layers: [drumNotes, bassNotes])
        #expect(try tracks(plan: valid, transcript: take, options: options).count == 3)
        let missing = TranscriptionArrangementPlan(layers: [drumNotes])
        let duplicated = TranscriptionArrangementPlan(layers: [drumNotes, drumNotes])
        var unknown = bassNotes; unknown.layerID = UUID()
        let unrequested = TranscriptionArrangementPlan(layers: [drumNotes, unknown])
        var empty = bassNotes; empty.notes = []
        var outside = bassNotes; outside.notes[0].duration = 4.01
        for invalid in [missing, duplicated, unrequested, .init(layers: [drumNotes, empty]), .init(layers: [drumNotes, outside])] {
            #expect(throws: ProjectError.self) {
                try TranscriptionArrangementBuilder.validate(plan: invalid, transcript: take, options: options, song: Song())
            }
        }
    }

    @Test func compatibleInstrumentsNeverSilentlyTransposeOrRemapPerformance() throws {
        let melody = transcript(), drums = transcript(mode: .beatboxing)
        let melodicWithKit = TranscriptionOptions(layers: [.init(instrumentID: "drums.electronic")])
        let drumWithLead = TranscriptionOptions(layers: [.init(instrumentID: "synth.lead")])
        let melodyWithBassGuitar = TranscriptionOptions(layers: [.init(instrumentID: "sampled.bass")])
        for invalid in [melodicWithKit, melodyWithBassGuitar] {
            #expect(throws: ProjectError.self) {
                try TranscriptionArrangementBuilder.validate(plan: .init(), transcript: melody, options: invalid, song: Song())
            }
        }
        #expect(throws: ProjectError.self) {
            try TranscriptionArrangementBuilder.validate(plan: .init(), transcript: drums, options: drumWithLead, song: Song())
        }
        let acousticKit = TranscriptionOptions(layers: [.init(instrumentID: "sampled.drums")])
        #expect(try tracks(transcript: drums, options: acousticKit)[0].clips[0].notes.map(\.pitch) == [36, 38])
        var unsupportedDrum = drums; unsupportedDrum.events[0].pitch = 60
        #expect(throws: ProjectError.self) {
            try TranscriptionArrangementBuilder.validate(plan: .init(), transcript: unsupportedDrum, options: acousticKit, song: Song())
        }
    }

    @Test func accompanimentRolesRequireTheCorrectDrumCategory() throws {
        let take = transcript(), performance = TranscriptionLayer()
        for role in [TranscriptionLayerRole.bass, .harmony, .countermelody, .drums] {
            let wrong = TranscriptionLayer(name: "Wrong category", instrumentID: role == .drums ? "synth.lead" : "drums.electronic", role: role)
            let options = TranscriptionOptions(layers: [performance, wrong])
            let plan = TranscriptionArrangementPlan(layers: [.init(layerID: wrong.id, notes: [NoteEvent(pitch: 36)])])
            #expect(throws: ProjectError.self) {
                try TranscriptionArrangementBuilder.validate(plan: plan, transcript: take, options: options, song: Song())
            }
        }
    }

    @Test func trackLimitAndSourceAssetFitWithinOneSharedCommandBatch() throws {
        let take = transcript()
        let asset = AudioAsset(fileName: "Source.wav", duration: take.duration, sampleRate: 48_000, channels: 1, transcriptionTake: .init(transcript: take, recordedTempo: 120, recordedStartBeat: 0))
        let layers = (1...64).map { TranscriptionLayer(name: "Layer \($0)") }
        let options = TranscriptionOptions(layers: layers)
        let addTracks = try TranscriptionArrangementBuilder.commands(plan: .init(), transcript: take, options: options, song: Song(), sourceAssetID: asset.id)
        let batch = [ProjectCommand(op: .addAsset, asset: asset)] + addTracks
        #expect(batch.count == 65)
        #expect(batch.count <= 128)
        var draft = Song()
        try ProjectEditor.apply(batch, to: &draft)
        #expect(draft.tracks.count == 64)
        #expect(draft.tracks.allSatisfy { $0.clips[0].transcriptionAssetID == asset.id })
        #expect(draft.assets == [asset])
        #expect(throws: ProjectError.self) {
            try TranscriptionArrangementBuilder.validate(plan: .init(), transcript: take, options: .init(), song: draft)
        }
        var almostFull = Song(); almostFull.tracks = (1...63).map { Track(name: "Existing \($0)") }
        #expect(try tracks(transcript: take, options: .init(), song: almostFull).count == 1)
        #expect(throws: ProjectError.self) {
            try TranscriptionArrangementBuilder.validate(plan: .init(), transcript: take, options: .init(layers: Array(layers.prefix(2))), song: almostFull)
        }
    }

    @Test func legacyDocumentsAndSourceProvenanceRoundTrip() throws {
        let take = transcript()
        let metadata = TranscriptionTake(transcript: take, recordedTempo: 113, recordedStartBeat: 17.125, createdAt: Date(timeIntervalSince1970: 1234.125))
        let asset = AudioAsset(fileName: "Take.wav", duration: take.duration, sampleRate: 44_100, channels: 1, transcriptionTake: metadata)
        var song = Song(); song.tempo = 137
        let commands = try TranscriptionArrangementBuilder.commands(plan: .init(), transcript: take, options: .init(insertionBeat: 9.75), song: song, sourceAssetID: asset.id)
        try ProjectEditor.apply([.init(op: .addAsset, asset: asset)] + commands, to: &song)
        var project = ProjectFile(); project.song = song
        let bytes = Data([82, 73, 70, 70, 1, 2, 3])
        let archive = try ProjectArchive.encode(project: project, assets: [asset.id: bytes])
        let decoded = try ProjectArchive.decode(archive)
        #expect(decoded.project == project)
        #expect(decoded.assets[asset.id] == bytes)
        #expect(decoded.project.song.tracks[0].clips[0].transcriptionAssetID == asset.id)
        #expect(decoded.project.song.assets[0].transcriptionTake == metadata)
        let legacyAsset = """
        {"id":"\(UUID())","fileName":"Old.wav","duration":2,"sampleRate":48000,"channels":1}
        """
        #expect(try JSONDecoder().decode(AudioAsset.self, from: Data(legacyAsset.utf8)).transcriptionTake == nil)
        let legacyClip = """
        {"id":"\(UUID())","name":"Old notes","kind":"notes","startBeat":0,"lengthBeats":4,"notes":[],"sourceOffsetSeconds":0}
        """
        #expect(try JSONDecoder().decode(Clip.self, from: Data(legacyClip.utf8)).transcriptionAssetID == nil)
        var broken = song; broken.assets[0].transcriptionTake = nil
        #expect(throws: ProjectError.self) { try ProjectEditor.validate(broken) }
    }
}
