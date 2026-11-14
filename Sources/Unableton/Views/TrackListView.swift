import SwiftUI
import UnabletonCore

/// Shares the timeline's native scrolling surface. The glass compensates for
/// vertical motion; the rows scroll with their corresponding lanes.
struct TrackListView: View {
    @ObservedObject var session: ProjectSession
    let width: CGFloat
    let rowHeight: CGFloat
    let rulerHeight: CGFloat
    let viewportHeight: CGFloat
    let verticalOffset: CGFloat
    let titlebarInset: CGFloat

    private let inset: CGFloat = 8
    private let cornerRadius: CGFloat = 18
    private var panelHeight: CGFloat { max(0, viewportHeight - inset * 2) }
    private var panelTop: CGFloat { verticalOffset + inset }
    private var rowViewport: Path {
        Path(CGRect(x: 0, y: verticalOffset + rulerHeight,
                    width: width - inset * 2, height: max(0, viewportHeight - rulerHeight - inset)))
    }
    private var panelViewport: Path {
        Path(roundedRect: CGRect(x: 0, y: panelTop, width: width - inset * 2, height: panelHeight),
             cornerRadius: cornerRadius)
    }

    var body: some View {
        rows
            .frame(width: width - inset * 2)
            .frame(minHeight: viewportHeight, alignment: .top)
            .mask { rowViewport }
            .clipShape(panelViewport)
            .contentShape(rowViewport)
            .background(alignment: .top) {
                Color.clear
                    .frame(height: panelHeight + titlebarInset)
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .offset(y: panelTop - titlebarInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background(alignment: .top) {
                colorBands.mask { rowViewport }.clipShape(panelViewport)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, inset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tracks, \(session.file.song.tracks.count)")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach(session.file.song.tracks) { track in
                TrackHeaderView(session: session, track: track).frame(height: rowHeight)
                Color.clear.frame(height: 1)
            }
            Color.clear.frame(height: 120)
        }
    }

    private var colorBands: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach(session.file.song.tracks) { track in
                TrackColors.color(track.colorIndex).opacity(0.12).frame(height: rowHeight)
                Color.clear.frame(height: 1)
            }
        }
    }
}
