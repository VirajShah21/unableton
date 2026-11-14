import Foundation
import UnabletonCore

/// Converts pointer positions in the visible arrangement into its scrolling
/// musical coordinates. Preview and release use the same conversion.
struct ClipDragGeometry {
    let headerWidth: CGFloat
    let rulerHeight: CGFloat
    let rowHeight: CGFloat
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let zoom: Double

    func grabOffsetX(for clip: Clip, pointer: CGPoint) -> Double? {
        guard contains(pointer), clip.startBeat.isFinite, clip.startBeat >= 0,
              clip.lengthBeats.isFinite, clip.lengthBeats > 0 else { return nil }
        let offset = Double(pointer.x + horizontalOffset - headerWidth) - clip.startBeat * zoom - 1
        guard offset.isFinite, offset >= 0, offset <= max(12, clip.lengthBeats * zoom - 2) else { return nil }
        return offset
    }

    func target(for pointer: CGPoint, context: ClipDragContext, in song: Song) -> ClipDropTarget? {
        guard contains(pointer) else { return nil }
        let contentY = pointer.y + verticalOffset - rulerHeight
        let stride = rowHeight + 1
        let index = floor(contentY / stride)
        guard index.isFinite, index >= 0, index < CGFloat(song.tracks.count),
              contentY - index * stride < rowHeight else { return nil }
        return context.proposal(in: song, targetTrackID: song.tracks[Int(index)].id,
                                dropX: Double(pointer.x + horizontalOffset - headerWidth), zoom: zoom)
    }

    /// Desired scrolling per tick. The caller clamps the resulting scroll
    /// position to the content bounds and recomputes the preview afterwards.
    func scrollDelta(for pointer: CGPoint) -> CGSize {
        guard contains(pointer) else { return .zero }
        return CGSize(width: edgeDelta(pointer.x, lower: headerWidth, upper: viewportWidth),
                      height: edgeDelta(pointer.y, lower: rulerHeight, upper: viewportHeight))
    }

    private var valid: Bool {
        headerWidth.isFinite && headerWidth >= 0 && rulerHeight.isFinite && rulerHeight >= 0
            && rowHeight.isFinite && rowHeight > 0 && viewportWidth.isFinite && viewportWidth > headerWidth
            && viewportHeight.isFinite && viewportHeight > rulerHeight
            && horizontalOffset.isFinite && verticalOffset.isFinite && zoom.isFinite && zoom > 0
    }

    private func contains(_ point: CGPoint) -> Bool {
        valid && point.x.isFinite && point.y.isFinite
            && point.x >= headerWidth && point.x < viewportWidth
            && point.y >= rulerHeight && point.y < viewportHeight
    }

    private func edgeDelta(_ coordinate: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        let zone = min(24, (upper - lower) / 2)
        if coordinate < lower + zone { return -12 * (lower + zone - coordinate) / zone }
        if coordinate > upper - zone { return 12 * (coordinate - upper + zone) / zone }
        return 0
    }
}
