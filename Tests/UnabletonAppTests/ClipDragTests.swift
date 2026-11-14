import Foundation
import Testing
import UnabletonCore
@testable import Unableton

private func clipDragProject(pitch: Int = 72) -> ProjectFile {
    var file = ProjectFile()
    file.song.tracks = [
        Track(name: "Lead", instrumentID: "synth.lead", clips: [
            Clip(name: "Phrase", startBeat: 8, lengthBeats: 8,
                 notes: [NoteEvent(pitch: pitch, duration: 1)])
        ]),
        Track(name: "Pad", instrumentID: "synth.pad"),
        Track(name: "Bass guitar", instrumentID: "sampled.bass"),
        Track(name: "Audio", kind: .audio)
    ]
    return file
}

private func clipDragContext(_ song: Song, grabX: Double = 35, zoom: Double = 24) throws -> ClipDragContext {
    let source = try #require(song.tracks.first), clip = try #require(source.clips.first)
    return try #require(ClipDragContext(song: song, clipID: clip.id, sourceTrackID: source.id,
                                       grabOffsetX: grabX, zoom: zoom))
}

@Suite(.serialized)
@MainActor
struct ClipDragTests {
    @Test func differentGrabPointsRetainTheSameLeadingEdge() throws {
        let song = clipDragProject().song, source = song.tracks[0]
        for grab in [0.0, 35, 120, 189] {
            let context = try clipDragContext(song, grabX: grab)
            let proposal = try #require(context.proposal(in: song, targetTrackID: source.id,
                                                        dropX: 12 * 24 + 1 + grab, zoom: 24))
            #expect(proposal.startBeat == 12)
            #expect(proposal.lengthBeats == 8 && proposal.clipID == source.clips[0].id)
        }
    }

    @Test func musicalOffsetsSurviveZoomAndScrolledContentCoordinates() throws {
        let song = clipDragProject().song, target = song.tracks[1]
        let context = try clipDragContext(song, grabX: 35, zoom: 24)
        #expect(context.grabOffsetBeats == 1.5)
        // Destination X already belongs to the scrolling lane, even when most
        // of that lane is outside the window. Do not add its scroll offset.
        for zoom in [8.0, 24, 60] {
            let proposal = try #require(context.proposal(in: song, targetTrackID: target.id,
                                                        dropX: (96 + 1.5) * zoom, zoom: zoom))
            #expect(proposal.startBeat == 96)
        }
    }

    @Test func snapsAndClampsBeforeBothPreviewAndCommit() throws {
        let song = clipDragProject().song, source = song.tracks[0]
        let context = try clipDragContext(song, grabX: 11, zoom: 24)
        #expect(context.proposal(in: song, targetTrackID: source.id, dropX: 12.62 * 24, zoom: 24)?.startBeat == 12)
        #expect(context.proposal(in: song, targetTrackID: source.id, dropX: 12.63 * 24, zoom: 24)?.startBeat == 12.25)
        #expect(context.proposal(in: song, targetTrackID: source.id, dropX: -20, zoom: 24)?.startBeat == 0)
        #expect(context.proposal(in: song, targetTrackID: source.id, dropX: 200_000 * 24, zoom: 24) == nil)
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(context.proposal(in: song, targetTrackID: source.id, dropX: invalid, zoom: 24) == nil)
            #expect(context.proposal(in: song, targetTrackID: source.id, dropX: 100, zoom: invalid) == nil)
            #expect(ClipDragContext(song: song, clipID: source.clips[0].id, sourceTrackID: source.id,
                                    grabOffsetX: invalid, zoom: 24) == nil)
        }
        for invalidZoom in [0.0, -24] {
            #expect(context.proposal(in: song, targetTrackID: source.id, dropX: 100, zoom: invalidZoom) == nil)
        }
        #expect(ClipDragContext(song: song, clipID: source.clips[0].id, sourceTrackID: source.id,
                                grabOffsetX: 500, zoom: 24) == nil)
    }

    @Test func rejectsStaleMissingAndIncompatibleDestinations() throws {
        let song = clipDragProject().song, context = try clipDragContext(song)
        #expect(context.proposal(in: song, targetTrackID: song.tracks[1].id, dropX: 300, zoom: 24) != nil)
        #expect(context.proposal(in: song, targetTrackID: song.tracks[2].id, dropX: 300, zoom: 24) == nil)
        #expect(context.proposal(in: song, targetTrackID: song.tracks[3].id, dropX: 300, zoom: 24) == nil)
        #expect(context.proposal(in: song, targetTrackID: UUID(), dropX: 300, zoom: 24) == nil)
        var changed = song
        changed.revision += 1
        #expect(context.proposal(in: changed, targetTrackID: song.tracks[1].id, dropX: 300, zoom: 24) == nil)
        changed = song; changed.tracks[0].clips.removeAll()
        #expect(context.proposal(in: changed, targetTrackID: song.tracks[1].id, dropX: 300, zoom: 24) == nil)
        changed = song; changed.id = UUID()
        #expect(context.proposal(in: changed, targetTrackID: song.tracks[1].id, dropX: 300, zoom: 24) == nil)
        changed = song; changed.tracks[0].clips[0].notes[0].pitch = 74
        #expect(context.proposal(in: changed, targetTrackID: song.tracks[1].id, dropX: 300, zoom: 24) == nil)
        var drumSong = clipDragProject(pitch: 54).song
        drumSong.tracks[1].instrumentID = "sampled.drums"
        let drumContext = try clipDragContext(drumSong)
        #expect(drumContext.proposal(in: drumSong, targetTrackID: drumSong.tracks[1].id, dropX: 300, zoom: 24) == nil)
    }

    @Test func audioMovesOnlyBetweenAudioTracks() throws {
        var song = Song()
        let asset = AudioAsset(fileName: "take.wav", duration: 4, sampleRate: 44_100, channels: 1)
        song.assets = [asset]
        song.tracks = [
            Track(name: "Take", kind: .audio, clips: [Clip(kind: .audio, startBeat: 2, lengthBeats: 4, assetID: asset.id)]),
            Track(name: "Vocal", kind: .audio), Track(name: "Synth")
        ]
        let context = try clipDragContext(song)
        #expect(context.proposal(in: song, targetTrackID: song.tracks[1].id, dropX: 300, zoom: 24) != nil)
        #expect(context.proposal(in: song, targetTrackID: song.tracks[2].id, dropX: 300, zoom: 24) == nil)
    }

    @Test func successfulMoveUsesSharedCommandAndOneUndoStep() throws {
        let file = clipDragProject(), context = try clipDragContext(file.song)
        let session = ProjectSession(file: file, keyProvider: { nil }, mode: .producer)
        defer { session.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        let target = file.song.tracks[1].id, clipID = context.clipID
        session.editorVisible = false; session.editorTab = "Effects"
        undo.beginUndoGrouping()
        #expect(session.moveClipFromDrag(context, to: target, dropX: 12 * 24 + 36, zoom: 24))
        undo.endUndoGrouping()
        #expect(session.file.song.track(target)?.clips.first?.startBeat == 12)
        #expect(session.file.song.tracks[0].clips.isEmpty)
        #expect(session.selection.trackID == target && session.selection.clipID == clipID)
        #expect(!session.editorVisible && session.editorTab == "Effects")
        #expect(undo.undoActionName == "Move Clip")
        undo.undo()
        #expect(session.file.song.tracks[0].clips.first?.startBeat == 8)
        #expect(session.file.song.track(target)?.clips.isEmpty == true)
        #expect(session.selection.trackID == context.sourceTrackID && session.selection.clipID == clipID)
        #expect(!session.editorVisible && session.editorTab == "Effects")
        #expect(!undo.canUndo && undo.canRedo)
        undo.redo()
        #expect(session.file.song.track(target)?.clips.first?.startBeat == 12)
        #expect(session.selection.trackID == target && session.selection.clipID == clipID)
        #expect(!session.editorVisible && session.editorTab == "Effects")
        #expect(!undo.canRedo)
    }

    @Test func blockedAndNoOpDropsLeaveMusicSelectionAndUndoIntact() throws {
        let file = clipDragProject(), context = try clipDragContext(file.song)
        let session = ProjectSession(file: file, keyProvider: { nil }, mode: .producer)
        defer { session.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        let selection = session.selection
        #expect(!session.moveClipFromDrag(context, to: context.sourceTrackID, dropX: 8 * 24 + 36, zoom: 24))
        #expect(!session.moveClipFromDrag(context, to: file.song.tracks[3].id, dropX: 300, zoom: 24))
        #expect(session.file == file && session.selection == selection && !undo.canUndo)
        session.setMode(.superhuman, remember: false)
        #expect(!session.moveClipFromDrag(context, to: file.song.tracks[1].id, dropX: 300, zoom: 24))
        #expect(session.file == file && session.selection == selection && !undo.canUndo)
        session.setMode(.producer, remember: false)
        // The core validator can still reject other project errors. A failed
        // shared command must never select the apparent destination.
        session.file.song.tempo = 1
        let invalidFile = session.file
        #expect(!session.moveClipFromDrag(context, to: file.song.tracks[1].id, dropX: 300, zoom: 24))
        #expect(session.file == invalidFile && session.selection == selection && !undo.canUndo)
    }

    @Test func closedSessionRejectsAnOtherwiseValidMove() throws {
        let file = clipDragProject(), context = try clipDragContext(file.song)
        let session = ProjectSession(file: file, keyProvider: { nil }, mode: .producer)
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        session.close()
        let selection = session.selection
        #expect(!session.moveClipFromDrag(context, to: file.song.tracks[1].id, dropX: 300, zoom: 24))
        #expect(session.file == file && session.selection == selection && !undo.canUndo)
    }
}
