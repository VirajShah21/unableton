import Foundation
import UnabletonCore

public struct AgentConfiguration: Sendable, Equatable {
    public var model: String
    public var apiKey: String
    public var reasoningEffort: String
    public var maximumSteps: Int
    public var timeout: TimeInterval
    public var autoUpgrade: Bool
    public var frontierModel: String
    public var runBudget: GenerationBudget?
    public var instruments: InstrumentDependencies?
    public var references: ReferenceTools? = nil
    public init(model: String? = nil, apiKey: String, reasoningEffort: String = "low", maximumSteps: Int = 32, timeout: TimeInterval = 300, autoUpgrade: Bool? = nil, frontierModel: String = ModelRouting.frontierModel, runBudget: GenerationBudget? = nil, instruments: InstrumentDependencies? = nil) {
        self.model = model ?? ModelRouting.economicalModel; self.apiKey = apiKey; self.reasoningEffort = reasoningEffort
        self.maximumSteps = maximumSteps; self.timeout = timeout
        self.autoUpgrade = autoUpgrade ?? (model == nil); self.frontierModel = frontierModel
        self.runBudget = runBudget; self.instruments = instruments
    }
}

public struct PreviewReport: Sendable {
    public var url: URL?
    public var duration: Double
    public var peak: Double
    public var rms: Double
    public var clippedSamples: Int
    public var silent: Bool
    public init(url: URL? = nil, duration: Double, peak: Double = 0, rms: Double = 0, clippedSamples: Int = 0, silent: Bool = false) {
        self.url = url; self.duration = duration; self.peak = peak; self.rms = rms
        self.clippedSamples = clippedSamples; self.silent = silent
    }
}

public struct AgentResult: Sendable {
    public var song: Song
    public var generatedAssets: [UUID: Data]
    public var generatedFiles: [UUID: URL] = [:]
    public var summary: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var responseItems: [JSONValue]
    public var runID: UUID
    public var routingReason: String? = nil
    public var attemptedModels: [String] = []
    public init(song: Song, summary: String, model: String, inputTokens: Int, outputTokens: Int, responseItems: [JSONValue], runID: UUID, routingReason: String? = nil, attemptedModels: [String] = [], generatedAssets: [UUID: Data] = [:], generatedFiles: [UUID: URL] = [:]) {
        self.generatedAssets = generatedAssets
        self.generatedFiles = generatedFiles
        self.song = song; self.summary = summary; self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.responseItems = responseItems; self.runID = runID; self.routingReason = routingReason; self.attemptedModels = attemptedModels
    }
}

public enum AgentError: LocalizedError, Sendable {
    case configuration(String), transport(String), provider(status: Int, message: String), incomplete(String), invalidTool(String), modelLimit(String), limit(String)
    public var errorDescription: String? {
        switch self {
        case .configuration(let s), .transport(let s), .incomplete(let s), .invalidTool(let s), .modelLimit(let s), .limit(let s): s
        case .provider(_, let message): message
        }
    }
    var canRetry: Bool {
        if case .provider(let status, _) = self { return status == 408 || status == 429 || status >= 500 }
        if case .transport = self { return true }
        return false
    }
}

public protocol ResponsesTransport: Sendable {
    func send(body: JSONValue, apiKey: String, status: @escaping @Sendable (String) -> Void) async throws -> JSONValue
}

/// Host-owned library access. Models can select catalog IDs, never paths or URLs.
/// The host holds resources for the run and pauses its budget only for downloads.
public final class InstrumentDependencies: Sendable, Equatable {
    public let installed: @Sendable () async -> Set<String>
    public let ensure: @Sendable (Set<String>) async throws -> Void
    public init(installed: @escaping @Sendable () async -> Set<String>,
                ensure: @escaping @Sendable (Set<String>) async throws -> Void) {
        self.installed = installed; self.ensure = ensure
    }
    public static func == (lhs: InstrumentDependencies, rhs: InstrumentDependencies) -> Bool { lhs === rhs }
}

public struct InstrumentDependencyError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
