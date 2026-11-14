import AppKit
import SwiftUI

/// Shared pointer, keyboard, and accessibility resizing for the two editor panes.
struct PaneResizeHandle: View {
    let axis: Axis
    let label: String
    let coordinateSpace: String
    @Binding var size: CGFloat
    @GestureState private var initialSize: CGFloat?
    @State private var hovering = false
    @FocusState private var focused: Bool
    private var horizontal: Bool { axis == .horizontal }

    var body: some View {
        Capsule()
            .fill(.secondary.opacity(hovering || focused ? 0.5 : 0))
            .frame(width: horizontal ? 3 : 32, height: horizontal ? 32 : 3)
            .frame(width: horizontal ? 10 : nil, height: horizontal ? nil : 8)
            .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
            .background {
                if !horizontal { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
            }
            .contentShape(Rectangle())
            .onHover { active in
                guard hovering != active else { return }
                hovering = active
                if active { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                .updating($initialSize) { _, initial, _ in if initial == nil { initial = size } }
                .onChanged { value in
                    size = (initialSize ?? size) - (horizontal ? value.translation.width : value.translation.height)
                })
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.leftArrow) { guard horizontal else { return .ignored }; size += 20; return .handled }
            .onKeyPress(.rightArrow) { guard horizontal else { return .ignored }; size -= 20; return .handled }
            .onKeyPress(.upArrow) { guard !horizontal else { return .ignored }; size += 20; return .handled }
            .onKeyPress(.downArrow) { guard !horizontal else { return .ignored }; size -= 20; return .handled }
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(size)) points")
            .accessibilityHint(horizontal ? "Use Left and Right Arrow to resize." : "Use Up and Down Arrow to resize.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: size += 20
                case .decrement: size -= 20
                @unknown default: break
                }
            }
    }
}
