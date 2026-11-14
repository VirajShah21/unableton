import Combine
import Foundation
import UnabletonCore

enum SoundLibraryAssignmentDestination: Equatable {
    case existingTrack(UUID)
    case newTrack
}

/// A library window has an explicit origin, never a target inferred from focus.
@MainActor
final class SoundLibraryNavigationRequest: ObservableObject, Identifiable {
    let id = UUID()
    let instrumentID: String?
    @Published private(set) var destination: SoundLibraryAssignmentDestination?
    @Published private(set) var trackName: String?
    let songName: String?
    weak var session: ProjectSession?
    @Published private(set) var assignmentID: String?
    @Published private(set) var message: String?
    private var assignment: Task<Void, Never>?
    private var token = UUID()
    private var observations = Set<AnyCancellable>()
    private let originSelection: ProjectSelection?
    private var committing = false

    init(instrumentID: String? = nil, session: ProjectSession? = nil) {
        let track = session?.selectedTrack
        self.instrumentID = instrumentID ?? (track?.kind == .instrument ? track?.instrumentID : nil)
        self.session = session
        originSelection = session?.selection
        if let track, track.kind == .instrument { destination = .existingTrack(track.id); trackName = track.name }
        else { destination = session == nil ? nil : .newTrack; trackName = nil }
        songName = session?.document.nativeDocument?.fileURL?.deletingPathExtension().lastPathComponent ?? session?.file.song.title
        if let session {
            session.$mode.removeDuplicates().dropFirst().sink { [weak self] _ in
                self?.cancel(reason: "Assignment canceled because the view mode changed. Any completed download remains available.")
            }.store(in: &observations)
            session.$selection.removeDuplicates().dropFirst().sink { [weak self] _ in
                guard self?.committing != true else { return }
                self?.cancel(reason: "Assignment canceled because the selection changed. Any completed download remains available.")
            }.store(in: &observations)
            session.$closed.filter { $0 }.sink { [weak self] _ in
                self?.cancel(reason: "Assignment canceled because the song closed. Any completed download remains available.")
            }.store(in: &observations)
        }
    }

    var trackID: UUID? { if case .existingTrack(let id) = destination { id } else { nil } }
    var createsTrack: Bool { destination == .newTrack }
    var hasTarget: Bool { destination != nil && session != nil }
    var targetTitle: String {
        if createsTrack { return "New instrument track in “\(songName ?? "Song")”" }
        return "For “\(trackName ?? "Track")” in “\(songName ?? "Song")”"
    }
    func actionTitle(installed: Bool) -> String {
        if createsTrack { return installed ? "Add Instrument Track" : "Download & Add Track" }
        return "\(installed ? "Use" : "Download & Use") on \(trackName ?? "Track")"
    }
    var successMessage: String { "Applied to \(trackName ?? "track")." }

    var canAssign: Bool {
        guard let session, !session.closed, session.canEditMusic else { return false }
        switch destination {
        case .existingTrack(let id): return session.selectedTrack?.id == id && session.selectedTrack?.kind == .instrument
        case .newTrack: return session.selection == originSelection && session.selectedTrack?.kind != .instrument
        case nil: return false
        }
    }

    func incompatibilityReason(for instrumentID: String) -> String? {
        guard canAssign, let session else { return nil }
        do {
            var draft = session.file.song
            let command: ProjectCommand
            if let trackID { command = .init(op: .setInstrument, trackID: trackID, text: instrumentID) }
            else {
                let track = Track(name: "Instrument \(draft.tracks.count + 1)", instrumentID: instrumentID, colorIndex: draft.tracks.count)
                command = .init(op: .addTrack, track: track)
            }
            try ProjectEditor.apply([command], to: &draft)
            return nil
        } catch { return error.localizedDescription }
    }

    func use(_ instrumentID: String,
             resources: @escaping @MainActor (Set<String>) async throws -> InstrumentResources = {
                 try await SoundLibraryStore.shared.resourcesForExplicitUse(for: $0)
             }) {
        guard canAssign, let session else { return }
        if let reason = incompatibilityReason(for: instrumentID) { message = reason; return }
        assignment?.cancel()
        let selection = session.selection, revision = session.file.song.revision
        let current = UUID(); token = current
        assignmentID = instrumentID; message = nil
        assignment = Task { [weak self] in
            guard let self else { return }
            defer { if token == current { assignmentID = nil; assignment = nil } }
            do {
                let held = try await resources([instrumentID])
                try Task.checkCancellation()
                guard token == current, let session = self.session else { return }
                let adding = createsTrack
                committing = true
                let applied = canAssign && session.commitInstrumentChoice(instrumentID, selection: selection, revision: revision)
                committing = false
                if applied, adding, let created = session.selectedTrack {
                    destination = .existingTrack(created.id); trackName = created.name
                }
                message = applied ? (adding ? "Added \(trackName ?? "an instrument track")." : successMessage) : "Assignment canceled because the track, selection, mode, or song changed. Any completed download is available on this Mac."
                withExtendedLifetime(held) {}
            } catch is CancellationError {
                if token == current { message = "Assignment canceled. Any completed download is available on this Mac." }
            } catch {
                if token == current { message = error.localizedDescription }
            }
        }
    }

    func cancel(reason: String? = nil) {
        if assignmentID != nil { message = reason ?? "Assignment canceled. Any completed download remains available." }
        token = UUID(); assignment?.cancel(); assignment = nil; assignmentID = nil
    }
}

@MainActor
final class SoundLibraryNavigation: ObservableObject {
    static let shared = SoundLibraryNavigation()
    @Published private(set) var request: SoundLibraryNavigationRequest?

    func reveal(_ instrumentID: String? = nil, from session: ProjectSession? = nil) {
        request?.cancel()
        request = SoundLibraryNavigationRequest(instrumentID: instrumentID, session: session)
    }

    func clearTarget() {
        let instrumentID = request?.instrumentID
        reveal(instrumentID)
    }
}
