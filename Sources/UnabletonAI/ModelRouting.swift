import Foundation
import UnabletonCore

public enum ModelRouting {
    public static let economicalModel = "gpt-6-luna"
    public static let frontierModel = "gpt-6-astra"
    /// Curated, documented Responses function-tool models. Account model listing
    /// does not supply capability metadata; unknown models require a manual check.
    public static let supportedModelIDs = [economicalModel, "gpt-6.1-sol", "gpt-6.1-terra", frontierModel]
    static let upgradeTool = AgentTools.tool("request_frontier", "Request the more capable model when this request needs reasoning or composition control beyond your capability. Give one short practical reason; do this before editing when possible. This discards your draft and restarts once from the user's original song.", AgentTools.object(["reason": AgentTools.string]))
    static let economicalInstructions = """
    Automatic model selection is enabled. You are the economical model. Complete routine composition and edits yourself. When a request's interacting musical constraints, long-form development, or difficult transformations exceed what you can confidently deliver, call request_frontier with a brief capability reason. Do not request an upgrade merely because a user wrote a long prompt, or for ordinary note, instrument, mixer or arrangement edits. The stronger model restarts from the original song; any edits in your current draft will be discarded. Do not ask the user to choose a model.
    """
    static func escalationReason(for error: any Error) -> String? {
        if let request = error as? FrontierRequest { return request.reason }
        guard let error = error as? AgentError else { return nil }
        switch error {
        case .invalidTool: return "The economical model could not complete valid edits."
        case .modelLimit: return "The request needs more reasoning and composition steps."
        default: return nil
        }
    }
}

struct FrontierRequest: Error, Sendable { var reason: String }
