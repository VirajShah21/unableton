import SwiftUI

/// Keeps editing controls unobscured while extending their colors under a
/// trailing system-glass panel.
struct FloatingChatWorkspace<Content: View>: View {
    @ObservedObject var session: ProjectSession
    @ViewBuilder var content: Content
    @SceneStorage("aiChatWidth") private var preferredWidth = 360.0

    var body: some View {
        GeometryReader { geometry in
            let maximumWidth = min(520, max(300, geometry.size.width - 556))
            let width = min(CGFloat(preferredWidth), maximumWidth)
            content
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if session.chatVisible {
                        Color.clear.frame(width: width + 16).allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .trailing) {
                    if session.chatVisible {
                        ChatView(session: session)
                            .frame(width: width)
                            .clipShape(.rect(cornerRadius: 20))
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                            .overlay(alignment: .leading) {
                                PaneResizeHandle(axis: .horizontal, label: "AI chat width", coordinateSpace: "chatWorkspace", size: Binding(
                                    get: { width },
                                    set: { preferredWidth = Double(min(maximumWidth, max(300, $0))) }
                                ))
                            }
                            .padding(8)
                    }
                }
                .coordinateSpace(name: "chatWorkspace")
        }
    }
}
