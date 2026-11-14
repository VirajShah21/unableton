import Foundation
import AppKit
import UnabletonCore
import UnabletonAudio

extension ProjectSession {
    @discardableResult func commitInstrumentChoice(_ id: String, selection expected: ProjectSelection, revision: Int) -> Bool {
        guard canEditMusic, !closed, selection == expected, file.song.revision == revision,
              InstrumentCatalog.preset(id: id) != nil else { return false }
        if let track = selectedTrack, track.kind == .instrument {
            perform([.init(op: .setInstrument, trackID: track.id, text: id)], name: "Change Instrument")
        } else { addInstrumentTrack(instrumentID: id) }
        guard selectedTrack?.instrumentID == id else { return false }
        editorVisible = true; editorTab = "Instrument"
        return true
    }

    /// The fast path keeps built-in playback synchronous. Sample preparation
    /// happens before touching an audio graph and can be canceled by Stop.
    func preparePlayback(audition: TranscriptionAudition? = nil) {
        PlaybackFocus.claim(self)
        let song = file.song, assets = assetURLs, revision = song.revision
        if audition == nil || audition == .accompaniment {
            do { try InstrumentResources.validatePlayback(in: song) }
            catch { errorMessage = error.localizedDescription; return }
        }
        let ids = audition != nil && audition != .accompaniment ? [] : InstrumentResources.requiredIDs(in: song)
        let play: (InstrumentResources) -> Void = { [weak self] resources in
            guard let self, !self.closed, self.file.song.revision == revision else { return }
            do {
                PlaybackFocus.claim(self)
                if let audition {
                    try self.audio.playTranscriptionAudition(song: song, assets: assets, audition: audition, resources: resources)
                    self.transcription.rehearsing = true
                } else { try self.audio.play(song: song, assets: assets, resources: resources) }
            } catch { self.errorMessage = error.localizedDescription }
        }
        audioPreparation?.cancel()
        if !ids.contains(where: { InstrumentCatalog.preset(id: $0)?.isSampler == true }) { play(.empty); return }
        let token = UUID(); audioPreparationID = token
        audioPreparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.audioPreparationID == token { self.audioPreparation = nil } }
            do {
                let resources = try await SoundLibraryStore.shared.resources(for: ids)
                try Task.checkCancellation()
                guard PlaybackFocus.current == nil || PlaybackFocus.current === self else { return }
                play(resources)
            } catch is CancellationError { }
            catch { self.errorMessage = error.localizedDescription }
        }
    }
    func recordWithoutAccompanimentIfNeeded(_ missing: MissingInstruments) async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Some song instruments are not installed"
        alert.informativeText = (missing.errorDescription ?? "") + " You can record without accompaniment now, or download the sounds first."
        alert.addButton(withTitle: "Record Without Accompaniment")
        alert.addButton(withTitle: "Download Sounds")
        alert.addButton(withTitle: "Cancel")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { throw CancellationError() }
        let response = try await CancellableAlert(alert, for: window).response()
        try Task.checkCancellation()
        if response == .alertFirstButtonReturn { return true }
        if response == .alertSecondButtonReturn { return false }
        throw CancellationError()
    }
}
