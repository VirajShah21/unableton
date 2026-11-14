import SwiftUI

struct ArrangementZoomView: View {
    @Binding var zoom: Double
    private let range = 8.0...60.0

    var body: some View {
        HStack(spacing: 8) {
            Button {
                zoom = max(range.lowerBound, zoom / 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 20, height: 20)
            }
            .disabled(zoom <= range.lowerBound)
            .help("Zoom out").accessibilityLabel("Zoom out")

            Slider(value: $zoom, in: range)
                .frame(width: 110)
                .accessibilityLabel("Timeline zoom")
                .help("Timeline zoom")

            Button {
                zoom = min(range.upperBound, zoom * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 20, height: 20)
            }
            .disabled(zoom >= range.upperBound)
            .help("Zoom in").accessibilityLabel("Zoom in")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arrangement zoom")
    }
}
