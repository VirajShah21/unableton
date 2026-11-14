import Foundation
import UnabletonCore

public struct VocalSinger: Codable, Sendable, Hashable, Identifiable {
    /// Rinoa expects the display name, rather than its internal `singer` field.
    public var id: String { name }
    public let name: String
    public let language: String
    public let style: String
    public init(name: String, language: String, style: String) {
        self.name = name; self.language = language; self.style = style
    }
}

public protocol VocalGenerating: Sendable {
    var providerID: String { get }
    func singers() async throws -> [VocalSinger]
    func render(score: VocalScore, singerID: String, status: @escaping @Sendable (String) -> Void) async throws -> Data
}

extension VocalGenerating {
    public var providerID: String { "rinoa" }
}

public enum VocalServiceError: LocalizedError, Sendable, Equatable {
    case configuration(String)
    case provider(status: Int, message: String)
    case invalidResponse(String)
    case limit(String)
    case transport(String)
    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .invalidResponse(let message), .limit(let message), .transport(let message): message
        case .provider(_, let message): message
        }
    }
}
