import Foundation
import UnabletonCore

/// A run's immutable attachment scope. Only the host can resolve files and
/// construct commands introducing reference-derived audio or measured notes.
public final class ReferenceTools: Sendable, Equatable {
    public let attachments: [SongAttachment]
    public let allowsAudioInspection: Bool
    public let allowsVocalNoteConversion: Bool
    public let execute: @Sendable (String, JSONValue, Song) async throws -> ReferenceToolResult
    public let assets: @Sendable (Song) async -> [UUID: URL]
    public init(attachments: [SongAttachment], allowsAudioInspection: Bool = false, allowsVocalNoteConversion: Bool = false,
                execute: @escaping @Sendable (String, JSONValue, Song) async throws -> ReferenceToolResult,
                assets: @escaping @Sendable (Song) async -> [UUID: URL]) {
        self.attachments = attachments; self.allowsAudioInspection = allowsAudioInspection; self.allowsVocalNoteConversion = allowsVocalNoteConversion; self.execute = execute; self.assets = assets
    }
    public static func == (lhs: ReferenceTools, rhs: ReferenceTools) -> Bool { lhs === rhs }
}

public struct ReferenceToolResult: Sendable {
    public var output: JSONValue
    public var commands: [ProjectCommand]
    public init(output: JSONValue, commands: [ProjectCommand] = []) {
        self.output = output; self.commands = commands
    }
}

/// Dependency failures cannot be repaired by an LLM or retried through an upgrade.
public struct ReferenceProcessingFailure: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
