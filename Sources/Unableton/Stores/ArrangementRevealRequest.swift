import Foundation

/// Window-only navigation after creating or inspecting music.
struct ArrangementRevealRequest: Identifiable, Equatable {
    var id = UUID()
    let trackID: UUID
    let beat: Double
}
