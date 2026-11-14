import Foundation
@preconcurrency import AVFAudio
import Testing
import UnabletonCore
@testable import UnabletonAudio
@testable import Unableton

private func workspacePreferences() throws -> (String, UserDefaults) {
    let name = "org.unableton.WorkspaceModeTests." + UUID().uuidString
    return (name, try #require(UserDefaults(suiteName: name)))
}

private func workspaceProject() -> ProjectFile {
    var file = ProjectFile()
    file.song.tempo = 120
    file.song.loopStart = 8; file.song.loopEnd = 24
    file.song.tracks = [Track(name: "Melody", instrumentID: "synth.lead", clips: [
        Clip(name: "Phrase", startBeat: 4, lengthBeats: 8, notes: [
            NoteEvent(pitch: 72, startBeat: 1, duration: 0.5, velocity: 90)
        ])
    ])]
    file.conversations[0].messages = [.init(role: "user", text: "Keep this melody.")]
    return file
}

private func workspaceAudioFixture() throws -> (URL, URL, Data, Double) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-WorkspaceMode-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("take.wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048))
    buffer.frameLength = 2_048
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<2_048 { samples[index] = Float(0.2 * sin(2 * .pi * 440 * Double(index) / 16_000)) }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    return (directory, url, try Data(contentsOf: url), 2_048.0 / 16_000)
}

@Suite(.serialized)
@MainActor
struct WorkspaceModeTests {
    @Test func firstLaunchAndInvalidPreferencesUseSuperhuman() throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(WorkspaceMode.lastUsed(in: preferences) == .superhuman)
        preferences.set("unknown-mode", forKey: WorkspaceMode.lastUsedPreferenceKey)
        #expect(WorkspaceMode.lastUsed(in: preferences) == .superhuman)
        let session = ProjectSession(keyProvider: { nil }, modePreferences: preferences)
        defer { session.close() }
        #expect(session.mode == .superhuman && !session.canEditMusic)
    }

    @Test func windowsStayIndependentAndNewWindowsUseLastExplicitChoice() throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let first = ProjectSession(keyProvider: { nil }, modePreferences: preferences)
        let second = ProjectSession(keyProvider: { nil }, modePreferences: preferences)
        defer { first.close(); second.close() }
        first.setMode(.producer)
        #expect(first.mode == .producer && second.mode == .superhuman)
        let third = ProjectSession(keyProvider: { nil }, modePreferences: preferences)
        defer { third.close() }
        #expect(third.mode == .producer)

        first.setMode(.superhuman, remember: false)
        #expect(WorkspaceMode.lastUsed(in: preferences) == .producer)
        let restoredSibling = ProjectSession(keyProvider: { nil }, modePreferences: preferences)
        defer { restoredSibling.close() }
        #expect(restoredSibling.mode == .producer)
        second.setMode(.superhuman)
        #expect(first.mode == .superhuman && third.mode == .producer && restoredSibling.mode == .producer)
        let next = ProjectSession(keyProvider: { nil }, modePreferences: preferences)
        defer { next.close() }
        #expect(next.mode == .superhuman)
    }

    @Test func modeChangesPreserveDocumentWindowStateAndUndoHistory() throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let session = ProjectSession(file: workspaceProject(), keyProvider: { nil }, mode: .producer, modePreferences: preferences)
        defer { session.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        undo.beginUndoGrouping(); session.setTempo(128); undo.endUndoGrouping()
        let track = try #require(session.file.song.tracks.first), clip = try #require(track.clips.first)
        session.select(track: track.id, clip: clip.id)
        session.selectedNoteID = clip.notes[0].id
        session.composer = "Make this phrase brighter"; session.zoom = 37
        session.editorVisible = true; session.transcriptionVisible = true; session.chatVisible = false; session.editorTab = "Effects"
        session.isGenerating = true; session.generationStatus = "Arranging…"
        let file = session.file, selection = session.selection, note = session.selectedNoteID
        let conversation = session.selectedConversationID
        let before = try session.document.snapshot(contentType: .unabletonProject)
        let encoded = try #require(ProjectArchive.encode(project: before.project, assets: before.assets).fileWrappers?["project.json"]?.regularFileContents)
        let undoName = undo.undoActionName

        session.setMode(.superhuman)
        session.setMode(.producer)
        session.setMode(.superhuman)

        let after = try session.document.snapshot(contentType: .unabletonProject)
        let afterEncoded = try #require(ProjectArchive.encode(project: after.project, assets: after.assets).fileWrappers?["project.json"]?.regularFileContents)
        #expect(session.file == file && after.project == before.project && after.assets == before.assets)
        #expect(afterEncoded == encoded)
        #expect(session.selection == selection && session.selectedNoteID == note && session.selectedConversationID == conversation)
        #expect(session.composer == "Make this phrase brighter" && session.zoom == 37)
        #expect(session.editorVisible && session.transcriptionVisible && !session.chatVisible && session.editorTab == "Effects")
        #expect(session.isGenerating && session.generationStatus == "Arranging…")
        #expect(undo.canUndo && !undo.canRedo && undo.undoActionName == undoName)
        session.isGenerating = false
    }

    @Test func superhumanRejectsManualEditsBeforeSelectionOrDocumentSideEffects() throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let session = ProjectSession(file: workspaceProject(), keyProvider: { nil }, mode: .superhuman, modePreferences: preferences)
        defer { session.close() }
        let track = try #require(session.file.song.tracks.first), clip = try #require(track.clips.first)
        session.select(track: track.id, clip: clip.id); session.selectedNoteID = clip.notes[0].id
        session.editorTab = "Effects"
        let file = session.file, selection = session.selection, note = session.selectedNoteID
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo

        session.perform([.init(op: .renameTrack, trackID: track.id, text: "Changed")], name: "Rename")
        session.perform([.init(op: .moveClip, clipID: clip.id, startBeat: 16)], name: "Move")
        session.perform([.init(op: .setLoop, value: 1, startBeat: 0, lengthBeats: 32)], name: "Loop range")
        session.addInstrumentTrack(); session.addAudioTrack(); session.addNoteClip(at: 12, trackID: track.id)
        session.duplicateSelection(); session.deleteSelection(); session.deleteNote()
        session.setTempo(160); session.setKey("G major"); session.toggleMetronome()
        session.setTrackFlag(.setMute, track: track, enabled: true)
        session.setTrackFlag(.setSolo, track: track, enabled: true)
        session.setTrackFlag(.setArmed, track: track, enabled: true)
        session.parameter("cutoff", value: 500, track: track)

        #expect(session.file == file && session.assetData.isEmpty)
        #expect(session.selection == selection && session.selectedNoteID == note && session.editorTab == "Effects")
        #expect(session.errorMessage == nil && !undo.canUndo)
    }

    @Test func producerEditsWorkAndDelayedCallbacksAreBlockedAfterSwitching() throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let session = ProjectSession(file: workspaceProject(), keyProvider: { nil }, mode: .producer, modePreferences: preferences)
        defer { session.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        let track = try #require(session.file.song.tracks.first)
        session.select(track: track.id)
        undo.beginUndoGrouping(); session.setTempo(128); session.parameter("cutoff", value: 800, track: track); undo.endUndoGrouping()
        #expect(session.file.song.tempo == 128 && session.file.song.tracks[0].parameters["cutoff"] == 800)
        let delayedFieldCommit = { session.setTempo(160) }
        let delayedGesture = { session.addNoteClip(at: 20, trackID: track.id) }
        let before = session.file, selection = session.selection
        session.setMode(.superhuman)
        delayedFieldCommit(); delayedGesture()
        #expect(session.file == before && session.selection == selection)

        undo.undo()
        #expect(session.file.song.tempo == 120 && session.file.song.tracks[0].parameters["cutoff"] == nil)
        undo.redo()
        #expect(session.file.song.tempo == 128 && session.file.song.tracks[0].parameters["cutoff"] == 800)
    }

    @Test func loopToggleIsAllowedWithoutChangingItsRangeAndSupportsUndoRedo() throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let session = ProjectSession(file: workspaceProject(), keyProvider: { nil }, mode: .superhuman, modePreferences: preferences)
        defer { session.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        undo.beginUndoGrouping(); session.toggleLoop(); undo.endUndoGrouping()
        #expect(session.file.song.loopEnabled && session.file.song.loopStart == 8 && session.file.song.loopEnd == 24)
        undo.undo()
        #expect(!session.file.song.loopEnabled && session.file.song.loopStart == 8 && session.file.song.loopEnd == 24)
        undo.redo()
        #expect(session.file.song.loopEnabled && session.file.song.loopStart == 8 && session.file.song.loopEnd == 24)
        undo.beginUndoGrouping(); session.toggleLoop(); undo.endUndoGrouping()
        #expect(!session.file.song.loopEnabled && session.file.song.loopStart == 8 && session.file.song.loopEnd == 24)
    }

    @Test func importingAudioCanCreateAnAudioTrackInSuperhuman() throws { try assertAudioInsertion(recorded: false) }
    @Test func completedRecordingCanCreateAnAudioTrackInSuperhuman() throws { try assertAudioInsertion(recorded: true) }

    private func assertAudioInsertion(recorded: Bool) throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let original = workspaceProject()
        let session = ProjectSession(file: original, keyProvider: { nil }, mode: .superhuman, modePreferences: preferences)
        defer { session.close() }
        let (directory, url, bytes, duration) = try workspaceAudioFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        let captured = recorded ? RecordedAudio(url: url, duration: duration, sampleRate: 16_000, channels: 1, startBeat: 12.5) : nil
        // An instrument track cannot receive audio. The allowed input transaction
        // must create an audio destination without calling manual Add Track.
        undo.beginUndoGrouping()
        try session.insertAudio(url: url, at: 12.5, trackID: original.song.tracks[0].id, recorded: captured)
        undo.endUndoGrouping()
        let added = try #require(session.file.song.tracks.last), clip = try #require(added.clips.first)
        let asset = try #require(session.file.song.assets.first)
        #expect(session.file.song.tracks.count == 2 && session.file.song.tracks[0] == original.song.tracks[0])
        #expect(added.kind == .audio && clip.kind == .audio && clip.startBeat == 12.5)
        #expect(abs(clip.lengthBeats - duration * 2) < 0.000_001)
        #expect(session.assetData[asset.id] == bytes && session.waveforms[asset.id]?.contains(where: { $0 > 0 }) == true)
        #expect(session.selection.trackID == added.id && session.selection.clipID == clip.id)
        #expect(undo.undoActionName == (recorded ? "Record Audio" : "Import Audio"))
        let snapshot = try session.document.snapshot(contentType: .unabletonProject)
        let reopened = try ProjectArchive.decode(ProjectArchive.encode(project: snapshot.project, assets: snapshot.assets))
        #expect(reopened.project == session.file && reopened.assets[asset.id] == bytes)
        undo.undo()
        #expect(session.file.song.tracks == original.song.tracks && session.file.song.assets.isEmpty)
        undo.redo()
        #expect(session.file.song.tracks.count == 2 && session.assetData[asset.id] == bytes)
    }

    @Test func transcriptionEventCorrectionsRequireProducerButInspectionDoesNot() throws {
        let (name, preferences) = try workspacePreferences()
        defer { preferences.removePersistentDomain(forName: name) }
        let session = ProjectSession(file: workspaceProject(), keyProvider: { nil }, mode: .superhuman, modePreferences: preferences)
        defer { session.transcription.take = nil; session.close() }
        let event = TranscribedEvent(pitch: 72, startSeconds: 0.2, durationSeconds: 0.5, velocity: 0.8, confidence: 0.9)
        let transcript = PerformanceTranscript(mode: .whistle, events: [event], duration: 1)
        session.transcription.transcript = transcript
        session.transcription.updateEvent(event.id, pitch: 74, start: 0.3, duration: 0.4)
        #expect(session.transcription.transcript == transcript)
        session.select(track: session.file.song.tracks[0].id, clip: session.file.song.tracks[0].clips[0].id)
        #expect(session.selectedClip != nil && session.editorVisible)
        session.setMode(.producer)
        session.transcription.updateEvent(event.id, pitch: 74, start: 0.3, duration: 0.4)
        #expect(session.transcription.transcript?.events[0].pitch == 74)
        #expect(session.transcription.transcript?.events[0].startSeconds == 0.3)
        #expect(session.transcription.transcript?.events[0].durationSeconds == 0.4)
    }
}
