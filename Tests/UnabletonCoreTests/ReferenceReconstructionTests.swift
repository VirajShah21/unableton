import Foundation
import Testing
@testable import UnabletonCore

struct ReferenceReconstructionTests {
    private func measured() -> ReferenceReconstruction {
        ReferenceReconstruction(sourceStartSeconds: 10, sourceEndSeconds: 14, tempo: 80, tempoQuality: 0.7, parts: [
            ReferenceReconstructionPart(id: "bass", role: "bass", name: "Measured bass", notes: [
                MIDITimedNote(pitch: 36, startSeconds: 10.25, durationSeconds: 1, velocity: 95),
                MIDITimedNote(pitch: 38, startSeconds: 11.5, durationSeconds: 0.8, velocity: 77)
            ], relativeGain: 0.8, suggestedParameters: ["oscillator": 0, "lfoDepth": 0, "drive": 0.05]),
            ReferenceReconstructionPart(id: "drums", role: "drums", name: "Measured drums", notes: [
                MIDITimedNote(pitch: 36, startSeconds: 10.05, durationSeconds: 0.08, velocity: 100),
                MIDITimedNote(pitch: 42, startSeconds: 10.5, durationSeconds: 0.05, velocity: 60),
                MIDITimedNote(pitch: 38, startSeconds: 11.02, durationSeconds: 0.1, velocity: 95)
            ], relativeGain: 0.6)
        ], warnings: ["Drum classes are estimates."])
    }
    private func choices(_ source: ReferenceReconstruction) -> [ReferenceReconstructionSelection] {
        source.parts.map { part in
            ReferenceReconstructionSelection(partID: part.id, instrumentID: part.role == "drums" ? "drums.electronic" : "synth.bass",
                parameters: part.suggestedParameters, volume: part.relativeGain * 0.6, pan: 0)
        }
    }

    @Test func replacementPreservesSourceSecondsAndOldMusicWithoutLayerCollisions() throws {
        let source = measured(), attachmentID = UUID()
        var song = Song(); song.tempo = 160
        song.tracks = [Track(name: "Old guessed music", instrumentID: "synth.pad", isSolo: true,
                             clips: [Clip(notes: [NoteEvent(pitch: 60)])])]
        let original = song
        let plan = try ReferenceReconstructionPlanner.plan(song: song, attachmentID: attachmentID, reconstruction: source,
            startBeat: 8, selections: choices(source), replaceTrackIDs: [song.tracks[0].id])
        #expect(song == original) // Preparation never edits the live snapshot.
        try ProjectEditor.apply(plan.commands, to: &song)
        #expect(song.tracks[0].isMuted && !song.tracks[0].isSolo)
        #expect(song.tracks[0].clips == original.tracks[0].clips)
        #expect(song.tracks.count == 3 && plan.noteCount == 5)
        #expect(song.revision == original.revision + 1)
        let bass = song.tracks[1], clip = try #require(bass.clips.first)
        #expect(bass.effectiveParameters["lfoDepth"] == 0)
        #expect(bass.effectiveParameters["oscillator"] == 0)
        #expect(bass.volume == 0.48)
        #expect(clip.referenceAttachmentID == attachmentID)
        #expect(clip.referenceReconstruction?.partID == "bass")
        #expect(clip.referenceReconstruction?.profile == ReferenceReconstruction.currentProfile)
        #expect(abs(clip.lengthBeats * 60 / song.tempo - 4) < 1e-9)
        for (note, event) in zip(clip.notes, source.parts[0].notes) {
            #expect(abs(note.startBeat * 60 / song.tempo - (event.startSeconds - 10)) < 1e-9)
            #expect(abs(note.duration * 60 / song.tempo - event.durationSeconds) < 1e-9)
            #expect(note.pitch == event.pitch && note.velocity == event.velocity)
        }
        #expect(plan.warnings == source.warnings)
    }

    @Test func explicitRetentionWarnsAndRetainedSoloCannotSilenceReconstruction() throws {
        let source = measured()
        var song = Song()
        song.tracks = [Track(name: "Retained", clips: [Clip(notes: [NoteEvent()])])]
        let plan = try ReferenceReconstructionPlanner.plan(song: song, attachmentID: UUID(), reconstruction: source,
            startBeat: 0, selections: choices(source), replaceTrackIDs: [])
        #expect(plan.warnings.contains("Existing tracks remain audible alongside the reconstruction."))
        song.tracks[0].isSolo = true
        #expect(throws: ProjectError.self) {
            try ReferenceReconstructionPlanner.plan(song: song, attachmentID: UUID(), reconstruction: source,
                startBeat: 0, selections: choices(source), replaceTrackIDs: [])
        }
    }

    @Test func unsuitableInstrumentsAndParametersAreRejectedWithoutDroppingPitches() throws {
        let source = measured()
        let invalid = [
            ReferenceReconstructionSelection(partID: "drums", instrumentID: "synth.pluck", parameters: [:], volume: 0.5),
            ReferenceReconstructionSelection(partID: "bass", instrumentID: "drums.electronic", parameters: [:], volume: 0.5),
            ReferenceReconstructionSelection(partID: "drums", instrumentID: "sampled.drums", parameters: [:], volume: 0.5),
            ReferenceReconstructionSelection(partID: "bass", instrumentID: "sampled.piano", parameters: ["lfoDepth": 0], volume: 0.5),
            ReferenceReconstructionSelection(partID: "bass", instrumentID: "synth.bass", parameters: ["cutoff": 0], volume: 0.5),
            ReferenceReconstructionSelection(partID: "bass", instrumentID: "synth.bass", parameters: [:], volume: .nan)
        ]
        for selection in invalid {
            #expect(throws: ProjectError.self) {
                try ReferenceReconstructionPlanner.plan(song: Song(), attachmentID: UUID(), reconstruction: source,
                    startBeat: 0, selections: [selection], replaceTrackIDs: [])
            }
        }
        var highBass = source
        highBass.parts[0].notes[0].pitch = 48
        #expect(throws: ProjectError.self) {
            try ReferenceReconstructionPlanner.plan(song: Song(), attachmentID: UUID(), reconstruction: highBass,
                startBeat: 0, selections: [.init(partID: "bass", instrumentID: "sampled.bass", parameters: [:], volume: 0.5)], replaceTrackIDs: [])
        }
    }

    @Test func noteMeasurementsRequireBoundedTimesMonophonicBassAndKnownProfiles() throws {
        let source = measured()
        try source.validate(maximumDuration: 14)
        var corruptions: [ReferenceReconstruction] = []
        var value = source; value.profile = "legacy-raw-midi"; corruptions.append(value)
        value = source; value.tempoQuality = .nan; corruptions.append(value)
        value = source; value.sourceEndSeconds = 601; corruptions.append(value)
        value = source; value.parts[0].notes[1].startSeconds = 10.5; corruptions.append(value)
        value = source; value.parts[0].notes[0].startSeconds = 9; corruptions.append(value)
        value = source; value.parts[0].notes[0].durationSeconds = 10; corruptions.append(value)
        value = source; value.parts[1].notes[0].pitch = 60; corruptions.append(value)
        value = source; value.parts[0].relativeGain = .infinity; corruptions.append(value)
        value = source; value.parts[0].role = "vocals"; corruptions.append(value)
        for corrupted in corruptions { #expect(throws: ProjectError.self) { try corrupted.validate() } }
        #expect(throws: ProjectError.self) { try source.validate(maximumDuration: 12) }
    }

    @Test func silenceIsValidEvidenceButCannotCreateEmptyTracks() throws {
        let source = ReferenceReconstruction(sourceStartSeconds: 0, sourceEndSeconds: 4, parts: [], warnings: ["No audible instruments detected."])
        try source.validate()
        #expect(throws: ProjectError.self) {
            try ReferenceReconstructionPlanner.plan(song: Song(), attachmentID: UUID(), reconstruction: source,
                startBeat: 0, selections: [], replaceTrackIDs: [])
        }
    }

    @Test func capacityAndDuplicateSelectionFailBeforeAnyMutation() throws {
        let source = measured()
        var song = Song(); song.tracks = (0..<64).map { Track(name: "Track \($0)") }
        #expect(throws: ProjectError.self) {
            try ReferenceReconstructionPlanner.plan(song: song, attachmentID: UUID(), reconstruction: source,
                startBeat: 0, selections: choices(source), replaceTrackIDs: song.tracks.map(\.id))
        }
        let choice = choices(source)[0]
        #expect(throws: ProjectError.self) {
            try ReferenceReconstructionPlanner.plan(song: Song(), attachmentID: UUID(), reconstruction: source,
                startBeat: 0, selections: [choice, choice], replaceTrackIDs: [])
        }
        #expect(throws: ProjectError.self) {
            try ReferenceReconstructionPlanner.plan(song: Song(), attachmentID: UUID(), reconstruction: source,
                startBeat: 199_999, selections: [choice], replaceTrackIDs: [])
        }
        #expect(song.tracks.count == 64 && song.tracks.allSatisfy { !$0.isMuted })
    }

    @Test func savedReconstructionIsIndependentOfLegacyMIDIAndRoundTripsWithProvenance() throws {
        let bytes = Data([1, 2, 3, 4]), source = measured()
        let legacy = MIDIImport(parts: [MIDIImportedPart(id: "old", name: "Old raw data", channel: 0, program: 0, isPercussion: false,
            notes: [MIDITimedNote(pitch: 48, startSeconds: 0, durationSeconds: 1, velocity: 60)])], duration: 1, initialTempo: 120)
        let attachment = SongAttachment(fileName: "Source.wav", duration: 20, sampleRate: 44_100, channels: 2,
            byteCount: bytes.count, sha256: SongAttachmentLimits.sha256(bytes), midi: legacy, reconstruction: source)
        var project = ProjectFile(); project.attachments = [attachment]
        let plan = try ReferenceReconstructionPlanner.plan(song: project.song, attachmentID: attachment.id, reconstruction: source,
            startBeat: 0, selections: choices(source), replaceTrackIDs: [])
        try ProjectEditor.apply(plan.commands, to: &project.song)
        let restored = try ProjectArchive.decode(ProjectArchive.encode(project: project, assets: [attachment.id: bytes]))
        #expect(restored.project == project)
        #expect(restored.project.attachments?.first?.midi == legacy)
        #expect(restored.project.attachments?.first?.reconstruction == source)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
        json.removeValue(forKey: "reconstruction")
        let old = try JSONDecoder().decode(SongAttachment.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.reconstruction == nil && old.midi == legacy)
        let oldClip = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(Clip()))
        #expect(oldClip.referenceReconstruction == nil)
        project.song.tracks[0].clips[0].referenceReconstruction?.sourceEndSeconds = 21
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
    }

    @Test(arguments: ["local-reconstruction-v1", "local-reconstruction-v2", "local-reconstruction-v3"])
    func previousProfileReopensWithOldClipsButRequiresReanalysisBeforeNewPlanning(profile: String) throws {
        let bytes = Data([1, 2, 3, 4])
        let current = measured()
        var previous = current; previous.profile = profile
        #expect(current.isCurrentProfile && !previous.isCurrentProfile)
        try previous.validate(maximumDuration: 20)
        let attachment = SongAttachment(fileName: "Source.wav", duration: 20, sampleRate: 44_100, channels: 2,
            byteCount: bytes.count, sha256: SongAttachmentLimits.sha256(bytes), reconstruction: previous)
        var project = ProjectFile(); project.attachments = [attachment]
        let priorPlan = try ReferenceReconstructionPlanner.plan(song: project.song, attachmentID: attachment.id,
            reconstruction: current, startBeat: 0, selections: choices(current), replaceTrackIDs: [])
        try ProjectEditor.apply(priorPlan.commands, to: &project.song)
        for track in project.song.tracks.indices {
            project.song.tracks[track].clips[0].referenceReconstruction?.profile = previous.profile
        }
        let restored = try ProjectArchive.decode(ProjectArchive.encode(project: project, assets: [attachment.id: bytes]))
        #expect(restored.project == project)
        #expect(restored.project.song.tracks[0].clips[0].referenceReconstruction?.profile == profile)
        do {
            _ = try ReferenceReconstructionPlanner.plan(song: project.song, attachmentID: attachment.id,
                reconstruction: previous, startBeat: 0, selections: choices(previous), replaceTrackIDs: project.song.tracks.map(\.id))
            Issue.record("The previous extraction profile was reused for new tracks.")
        } catch let error as ProjectError {
            #expect(error.message.contains("Reanalyze"))
        }
        #expect(project == restored.project)
        previous.profile = "unknown-future-profile"
        #expect(throws: ProjectError.self) { try previous.validate() }
    }
}
