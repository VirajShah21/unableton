import SwiftUI
import UnabletonCore

/// Only musical colors enter the system's mirrored backdrop. Extending the
/// scroll view itself would also reflect its scrollbars behind the chat.
struct ArrangementBackdropView: View {
    let tracks: [Track]
    let selection: ProjectSelection
    let zoom: Double
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let headerWidth: CGFloat
    let rulerHeight: CGFloat
    let rowHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            guard zoom.isFinite, zoom > 0 else { return }
            let viewport = CGRect(origin: .zero, size: size)
            // Scrolling clips disappear below the pinned ruler, including in
            // the decorative extension. Canvas drawing may otherwise overflow.
            context.clip(to: Path(CGRect(x: 0, y: rulerHeight, width: size.width,
                                        height: max(0, size.height - rulerHeight))))
            for (index, track) in tracks.enumerated() {
                let y = rulerHeight + CGFloat(index) * (rowHeight + 1) - verticalOffset
                guard y + rowHeight > 0, y < size.height else { continue }
                for clip in track.clips {
                    let rect = CGRect(x: headerWidth + clip.startBeat * zoom - horizontalOffset + 1,
                                      y: y + 6, width: max(12, clip.lengthBeats * zoom - 2), height: rowHeight - 12)
                    guard rect.intersects(viewport) else { continue }
                    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(
                        TrackColors.color(track.colorIndex).opacity(selection.clipID == clip.id ? 0.52 : 0.28)
                    ))
                }
            }
        }
    }
}
