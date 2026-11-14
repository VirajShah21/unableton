import SwiftUI

extension View {
    /// Attach editing handlers only while the window permits manual edits.
    @ViewBuilder
    func musicEditing<Content: View>(_ allowed: Bool, @ViewBuilder transform: (Self) -> Content) -> some View {
        if allowed { transform(self) } else { self }
    }
}
