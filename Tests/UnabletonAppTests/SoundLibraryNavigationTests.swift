import Foundation
import Testing
import UnabletonCore
@testable import Unableton

@Suite(.serialized) @MainActor
struct SoundLibraryNavigationTests {
    private func project() -> ProjectSession {
        var file = ProjectFile()
        file.song.tracks = [Track(name: "Bass", instrumentID: "synth.bass"), Track(name: "Lead", instrumentID: "synth.lead")]
        let session = ProjectSession(file: file, mode: .producer)
        session.selection.trackID = file.song.tracks[0].id
        return session
    }

    @Test func standaloneAndSuperhumanHaveNoAssignmentCapability() {
        #expect(!SoundLibraryNavigationRequest().canAssign)
        let session = project(); defer { session.close() }
        let request = SoundLibraryNavigationRequest(session: session)
        #expect(request.instrumentID == "synth.bass")
        #expect(request.trackName == "Bass")
        #expect(request.canAssign)
        session.setMode(.superhuman, remember: false)
        #expect(!request.canAssign)
        let before = session.file.song
        request.use("synth.pluck", resources: { _ in Issue.record("Read-only assignment acquired resources"); return .empty })
        #expect(session.file.song == before)
    }

    @Test func originDoesNotFollowAnotherSelectedTrack() {
        let session = project(); defer { session.close() }
        let request = SoundLibraryNavigationRequest(session: session)
        session.selection.trackID = session.file.song.tracks[1].id
        #expect(!request.canAssign)
        #expect(request.trackID == session.file.song.tracks[0].id)
        session.selection.trackID = request.trackID
        #expect(request.canAssign)
        session.close()
        #expect(!request.canAssign)
    }

    @Test func emptyAndAudioSelectionsAddAnUndoableInstrumentTrack() async throws {
        for audioSelected in [false, true] {
            var file = ProjectFile()
            if audioSelected { file.song.tracks = [Track(name: "Vocals", kind: .audio)] }
            let session = ProjectSession(file: file, mode: .producer); defer { session.close() }
            if audioSelected { session.selection.trackID = file.song.tracks[0].id }
            let before = session.file.song, originalSelection = session.selection
            let request = SoundLibraryNavigationRequest(session: session)
            #expect(request.createsTrack && request.hasTarget && request.canAssign)
            #expect(request.instrumentID == nil)
            #expect(request.trackID == nil)
            #expect(request.actionTitle(installed: true) == "Add Instrument Track")
            #expect(request.actionTitle(installed: false) == "Download & Add Track")
            #expect(request.incompatibilityReason(for: "synth.pluck") == nil)
            #expect(session.file.song == before && session.selection == originalSelection)
            let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
            undo.beginUndoGrouping()
            request.use("synth.pluck", resources: { _ in .empty })
            try await settled(request)
            undo.endUndoGrouping()
            #expect(session.file.song.tracks.count == before.tracks.count + 1)
            #expect(session.selectedTrack?.instrumentID == "synth.pluck")
            #expect(session.selectedTrack?.kind == .instrument)
            if audioSelected { #expect(session.file.song.tracks[0] == before.tracks[0]) }
            #expect(!request.createsTrack && request.canAssign)
            #expect(request.trackID == session.selectedTrack?.id)
            let created = session.selectedTrack?.id
            undo.undo()
            #expect(session.file.song.tracks == before.tracks)
            undo.redo()
            #expect(session.file.song.track(created)?.instrumentID == "synth.pluck")
        }
    }

    @Test func successfulNewTrackBecomesTheExplicitTargetForFurtherChoices() async throws {
        let session = ProjectSession(mode: .producer); defer { session.close() }
        let request = SoundLibraryNavigationRequest(session: session)
        request.use("synth.pluck", resources: { _ in .empty })
        try await settled(request)
        let created = try #require(request.trackID)
        request.use("synth.pad", resources: { _ in .empty })
        try await settled(request)
        #expect(session.file.song.tracks.count == 1)
        #expect(session.file.song.track(created)?.instrumentID == "synth.pad")
    }

    @Test func newTrackRequiresProducerAndCapacityBeforeDownloading() {
        let readOnly = ProjectSession(mode: .superhuman); defer { readOnly.close() }
        let blocked = SoundLibraryNavigationRequest(session: readOnly)
        #expect(blocked.createsTrack && !blocked.canAssign)
        blocked.use("sampled.piano", resources: { _ in Issue.record("Read-only request downloaded a sound"); return .empty })
        #expect(readOnly.file.song.tracks.isEmpty)

        var file = ProjectFile()
        file.song.tracks = (0..<64).map { Track(name: "Audio \($0)", kind: .audio) }
        let full = ProjectSession(file: file, mode: .producer); defer { full.close() }
        let request = SoundLibraryNavigationRequest(session: full), before = full.file.song
        #expect(request.createsTrack && request.canAssign)
        #expect(request.incompatibilityReason(for: "sampled.piano") != nil)
        request.use("sampled.piano", resources: { _ in Issue.record("Full song downloaded a sound for another track"); return .empty })
        #expect(full.file.song == before)
        #expect(request.assignmentID == nil && request.message != nil)
    }

    @Test func delayedNewTrackRejectsChangedOriginRevisionModeAndClosure() async throws {
        for change in 0..<4 {
            let session = ProjectSession(mode: .producer); defer { session.close() }
            let request = SoundLibraryNavigationRequest(session: session), gate = ResourceGate()
            request.use("synth.pluck", resources: { _ in await gate.wait() })
            for _ in 0..<200 where !(await gate.started) { try await Task.sleep(for: .milliseconds(1)) }
            switch change {
            case 0: session.setTempo(137)
            case 1: session.selection.startBeat = 4
            case 2:
                session.setMode(.superhuman, remember: false); session.setMode(.producer, remember: false)
            default: session.close()
            }
            let before = session.file.song
            await gate.finish()
            try await settled(request)
            #expect(session.file.song == before)
            #expect(session.file.song.tracks.isEmpty)
            #expect(request.message?.contains("Assignment canceled") == true)
        }
    }

    @Test func incompatibleSoundExplainsItsRangeBeforeDownloading() {
        let session = project(); defer { session.close() }
        session.file.song.tracks[0].clips = [Clip(name: "Low bass", lengthBeats: 4, notes: [.init(pitch: 25, startBeat: 0, duration: 1)])]
        let request = SoundLibraryNavigationRequest(session: session), before = session.file.song
        #expect(request.incompatibilityReason(for: "sampled.guitar")?.contains("25") == true)
        request.use("sampled.guitar", resources: { _ in Issue.record("Incompatible sound should not download"); return .empty })
        #expect(request.assignmentID == nil)
        #expect(request.message?.contains("25") == true)
        #expect(session.file.song == before)
        #expect(session.errorMessage == nil)
    }

    @Test func libraryUseIsUndoableAndNeverChangesAnotherProject() async throws {
        let session = project(), other = project()
        defer { session.close(); other.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        let otherSong = other.file.song
        let request = SoundLibraryNavigationRequest(session: session)
        undo.beginUndoGrouping()
        request.use("synth.pluck", resources: { ids in #expect(ids == ["synth.pluck"]); return .empty })
        try await settled(request)
        undo.endUndoGrouping()
        #expect(session.selectedTrack?.instrumentID == "synth.pluck")
        #expect(other.file.song == otherSong)
        undo.undo()
        #expect(session.selectedTrack?.instrumentID == "synth.bass")
        undo.redo()
        #expect(session.selectedTrack?.instrumentID == "synth.pluck")
    }

    @Test func delayedUseRejectsRevisionSelectionModeAndClosureChanges() async throws {
        for change in 0..<4 {
            let session = project(); defer { session.close() }
            let request = SoundLibraryNavigationRequest(session: session)
            let gate = ResourceGate()
            request.use("synth.pluck", resources: { _ in await gate.wait() })
            for _ in 0..<200 where !(await gate.started) { try await Task.sleep(for: .milliseconds(1)) }
            switch change {
            case 0: session.setTempo(137)
            case 1: session.selection.trackID = session.file.song.tracks[1].id
            case 2: session.setMode(.superhuman, remember: false)
            default: session.close()
            }
            let before = session.file.song
            await gate.finish()
            try await settled(request)
            #expect(session.file.song == before)
            #expect(request.message?.contains("Assignment canceled") == true)
        }
    }

    @Test func cancelPreventsLateAssignment() async throws {
        let session = project(); defer { session.close() }
        let request = SoundLibraryNavigationRequest(session: session), gate = ResourceGate()
        let before = session.file.song
        request.use("synth.pluck", resources: { _ in await gate.wait() })
        for _ in 0..<200 where !(await gate.started) { try await Task.sleep(for: .milliseconds(1)) }
        request.cancel(); await gate.finish()
        try await Task.sleep(for: .milliseconds(10))
        #expect(session.file.song == before)
        #expect(request.assignmentID == nil)
    }

    @Test func leavingAndReturningToModeOrSelectionCannotReviveAnAssignment() async throws {
        for changeMode in [true, false] {
            let session = project(); defer { session.close() }
            let request = SoundLibraryNavigationRequest(session: session), gate = ResourceGate()
            let before = session.file.song, selection = session.selection
            request.use("synth.pluck", resources: { _ in await gate.wait() })
            for _ in 0..<200 where !(await gate.started) { try await Task.sleep(for: .milliseconds(1)) }
            if changeMode {
                session.setMode(.superhuman, remember: false); session.setMode(.producer, remember: false)
            } else {
                session.selection.trackID = session.file.song.tracks[1].id; session.selection = selection
            }
            await gate.finish()
            try await Task.sleep(for: .milliseconds(10))
            #expect(request.canAssign)
            #expect(request.assignmentID == nil)
            #expect(session.file.song == before)
        }
    }

    private func settled(_ request: SoundLibraryNavigationRequest) async throws {
        for _ in 0..<500 {
            if request.assignmentID == nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Instrument assignment did not settle")
    }
}

private actor ResourceGate {
    private var continuation: CheckedContinuation<InstrumentResources, Never>?
    private(set) var started = false
    func wait() async -> InstrumentResources {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func finish() { continuation?.resume(returning: .empty); continuation = nil }
}
