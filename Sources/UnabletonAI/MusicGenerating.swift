import Foundation
import UnabletonCore

/// App sessions depend on this boundary so queue, revision, and undo behavior
/// can be tested without network requests or Keychain credentials.
public protocol MusicGenerating: Sendable {
    func generate(
        song: Song, conversation: Conversation, selection: ProjectSelection, configuration: AgentConfiguration,
        vocals: VocalSession?,
        preview: @escaping @Sendable (Song, Double, Double) async throws -> PreviewReport,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> AgentResult
}

extension MusicAgent: MusicGenerating {}
