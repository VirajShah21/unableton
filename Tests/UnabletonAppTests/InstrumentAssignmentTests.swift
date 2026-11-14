import Foundation
import Testing
import UnabletonCore
@testable import Unableton

@Suite(.serialized) @MainActor
struct InstrumentAssignmentTests {
    private func session() -> ProjectSession {
        var file = ProjectFile()
        file.song.tracks = [Track(name: "Melody", instrumentID: "synth.lead"), Track(name: "Harmony", instrumentID: "synth.pad")]
        let session = ProjectSession(file: file, mode: .producer)
        session.selection = .init(trackID: file.song.tracks[0].id)
        return session
    }
    @Test func delayedInstrumentChoiceRechecksModeSelectionRevisionAndClosure() {
        let session = session(); defer { session.close() }
        let selection = session.selection, revision = session.file.song.revision, original = session.file.song
        session.setMode(.superhuman, remember: false)
        #expect(!session.commitInstrumentChoice("synth.pluck", selection: selection, revision: revision))
        #expect(session.file.song == original)
        #expect(!session.editorVisible)
        session.setMode(.producer, remember: false)
        session.selection.trackID = session.file.song.tracks[1].id
        #expect(!session.commitInstrumentChoice("synth.pluck", selection: selection, revision: revision))
        session.selection = selection
        session.setTempo(126)
        let changed = session.file.song
        #expect(!session.commitInstrumentChoice("synth.pluck", selection: selection, revision: revision))
        #expect(session.file.song == changed)
        session.close()
        #expect(!session.commitInstrumentChoice("synth.pluck", selection: selection, revision: changed.revision))
    }
    @Test func completedChoiceUsesSharedUndoableCommand() {
        let session = session(); defer { session.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        undo.beginUndoGrouping()
        #expect(session.commitInstrumentChoice("synth.pluck", selection: session.selection, revision: session.file.song.revision))
        undo.endUndoGrouping()
        #expect(session.selectedTrack?.instrumentID == "synth.pluck")
        #expect(session.editorVisible && session.editorTab == "Instrument")
        undo.undo()
        #expect(session.selectedTrack?.instrumentID == "synth.lead")
        undo.redo()
        #expect(session.selectedTrack?.instrumentID == "synth.pluck")
    }
}
