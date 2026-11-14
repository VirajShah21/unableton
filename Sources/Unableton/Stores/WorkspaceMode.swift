import Foundation

/// A window preference, never musical document state.
enum WorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case superhuman
    case producer

    static let lastUsedPreferenceKey = "workspace.lastMode"
    var id: String { rawValue }
    var title: String { self == .superhuman ? "Superhuman" : "Producer" }

    static func lastUsed(in preferences: UserDefaults = .standard) -> WorkspaceMode {
        WorkspaceMode(rawValue: preferences.string(forKey: lastUsedPreferenceKey) ?? "") ?? .superhuman
    }
}
