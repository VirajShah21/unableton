import Foundation
import UnabletonCore

/// Window-owned metadata for one clip drag. Positions passed to
/// `proposal` are lane-content coordinates, so scrolling adds no second offset.
struct ClipDragContext: Equatable {
    let clipID: UUID
    let sourceTrackID: UUID
    let revision: Int
    let grabOffsetBeats: Double
    private let songID: UUID
    private let sourceClip: Clip

    init?(song: Song, clipID: UUID, sourceTrackID: UUID, grabOffsetX: Double, zoom: Double) {
        guard zoom.isFinite, zoom > 0, grabOffsetX.isFinite, grabOffsetX >= 0,
              let track = song.track(sourceTrackID), let clip = track.clips.first(where: { $0.id == clipID }),
              clip.startBeat.isFinite, clip.startBeat >= 0, clip.lengthBeats.isFinite, clip.lengthBeats > 0,
              clip.startBeat + clip.lengthBeats <= 200_000,
              grabOffsetX <= max(12, clip.lengthBeats * zoom - 2) else { return nil }
        self.clipID = clipID
        self.sourceTrackID = sourceTrackID
        revision = song.revision
        songID = song.id
        sourceClip = clip
        // Clip drawing starts one point after its musical start.
        grabOffsetBeats = (grabOffsetX + 1) / zoom
        guard grabOffsetBeats.isFinite else { return nil }
    }

    func proposal(in song: Song, targetTrackID: UUID, dropX: Double, zoom: Double) -> ClipDropTarget? {
        guard song.id == songID, song.revision == revision, zoom.isFinite, zoom > 0, dropX.isFinite,
              let source = song.track(sourceTrackID), source.clips.first(where: { $0.id == clipID }) == sourceClip,
              let target = song.track(targetTrackID),
              sourceTrackID == targetTrackID || target.clips.count < 4_096 else { return nil }
        switch sourceClip.kind {
        case .notes:
            guard target.kind == .instrument, let preset = InstrumentCatalog.preset(id: target.instrumentID),
                  sourceClip.notes.allSatisfy({ note in
                      (preset.minimumPitch...preset.maximumPitch).contains(note.pitch)
                          && preset.supportedPitches?.contains(note.pitch) != false
                  }) else { return nil }
        case .audio:
            guard target.kind == .audio else { return nil }
        }
        let beat = dropX / zoom - grabOffsetBeats
        guard beat.isFinite else { return nil }
        let start = (max(0, beat) * 4).rounded() / 4
        guard start.isFinite, start + sourceClip.lengthBeats <= 200_000 else { return nil }
        return ClipDropTarget(clipID: clipID, trackID: targetTrackID, startBeat: start, lengthBeats: sourceClip.lengthBeats)
    }
}

struct ClipDropTarget: Equatable {
    let clipID: UUID
    let trackID: UUID
    let startBeat: Double
    let lengthBeats: Double
}

extension ProjectSession {
    /// Use the preview's placement calculation again at release, and change
    /// selection only after the shared command layer actually commits the move.
    @discardableResult
    func moveClipFromDrag(_ context: ClipDragContext, to targetTrackID: UUID, dropX: Double, zoom: Double) -> Bool {
        guard canEditMusic,
              let target = context.proposal(in: file.song, targetTrackID: targetTrackID, dropX: dropX, zoom: zoom),
              let original = file.song.clip(context.clipID),
              targetTrackID != context.sourceTrackID || target.startBeat != original.startBeat else { return false }
        let beforeRevision = file.song.revision
        perform([.init(op: .moveClip, trackID: context.sourceTrackID, clipID: context.clipID,
                       targetTrackID: target.trackID, startBeat: target.startBeat)], name: "Move Clip")
        guard file.song.revision == beforeRevision + 1,
              file.song.track(target.trackID)?.clips.contains(where: {
                  $0.id == target.clipID && $0.startBeat == target.startBeat
              }) == true else { return false }
        // Moving a clip must not open a pane and shift the canvas at release.
        selection.trackID = target.trackID; selection.clipID = target.clipID; selectedNoteID = nil
        return true
    }
}
