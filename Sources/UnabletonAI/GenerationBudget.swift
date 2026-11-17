import Foundation

public enum GenerationDependency: Sendable { case sounds, referenceProcessing }

/// One prompt owns this budget, including model upgrades and revision replans.
/// It contains no credentials, document state, or audio-thread work.
public actor GenerationBudget: Equatable {
    public nonisolated let runID = UUID()
    public nonisolated let maximumRequests: Int
    public nonisolated let maximumOutputTokens = 65_536
    private let maximumRetries: Int
    private let validConfiguration: Bool
    private let maximumActiveTime: TimeInterval
    private let maximumDependencyWait: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let startedAt: TimeInterval
    private var excludedTime: TimeInterval = 0
    private var waitStartedAt: TimeInterval?
    private var waitTokens: Set<UUID> = []
    private var waitedForReferences = false
    private var usage = GenerationUsage()

    public init(maximumRequests: Int = 32, timeout: TimeInterval = 300, maximumRetries: Int = 2,
                maximumDependencyWait: TimeInterval = 1800) {
        let anchor = ContinuousClock.now
        self.init(maximumRequests: maximumRequests, timeout: timeout, maximumRetries: maximumRetries,
                  maximumDependencyWait: maximumDependencyWait, now: {
            let components = anchor.duration(to: .now).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        })
    }

    init(maximumRequests: Int = 32, timeout: TimeInterval = 300, maximumRetries: Int = 2,
         maximumDependencyWait: TimeInterval = 1800, now: @escaping @Sendable () -> TimeInterval) {
        self.maximumRequests = min(32, max(1, maximumRequests))
        self.maximumRetries = min(2, max(0, maximumRetries))
        validConfiguration = maximumRequests > 0 && timeout.isFinite && timeout > 0 && maximumRetries >= 0
            && maximumDependencyWait.isFinite && maximumDependencyWait > 0
        maximumActiveTime = timeout.isFinite ? min(300, max(0, timeout)) : 0
        self.maximumDependencyWait = maximumDependencyWait.isFinite ? min(1800, max(0, maximumDependencyWait)) : 0
        self.now = now
        startedAt = now()
    }

    public nonisolated static func == (lhs: GenerationBudget, rhs: GenerationBudget) -> Bool { lhs === rhs }

    public func check() throws {
        try Task.checkCancellation()
        guard validConfiguration else { throw AgentError.configuration("Generation limits must be positive and finite.") }
        guard dependencyElapsed() < maximumDependencyWait else {
            if waitedForReferences {
                throw ReferenceProcessingFailure("Waiting for sounds or song processing took too long. Your song is unchanged. Send a new prompt when the dependency is ready.")
            }
            throw InstrumentDependencyError("Waiting for sounds took too long. Your song is unchanged. Finish installation in Sound Library and retry.")
        }
        guard activeElapsed() < maximumActiveTime else {
            throw AgentError.limit("Generation took too long. The project was not changed. Try a shorter section.")
        }
    }

    public func remainingTime() throws -> TimeInterval {
        try check()
        return max(0, maximumActiveTime - activeElapsed())
    }

    /// Sound consent/installation and local reference processing
    /// share one cumulative allowance. Composer/audio-inspection model calls,
    /// draft rendering and vocal generation still consume active work time.
    public func withDependencyWait<T: Sendable>(
        kind: GenerationDependency = .sounds,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try check()
        let token = UUID()
        if waitTokens.isEmpty { waitStartedAt = now() }
        waitTokens.insert(token)
        if kind == .referenceProcessing { waitedForReferences = true }
        defer { endWait(token) }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await self.waitUntilExpired()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try check()
            return result
        }
    }

    /// Rechecks both clocks instead of sleeping to a deadline captured before a
    /// download pause. The same watchdog is used by composition and Transcribe.
    public func waitUntilExpired() async throws -> Never {
        while true {
            try check()
            let remaining = waitTokens.isEmpty ? maximumActiveTime - activeElapsed()
                : maximumDependencyWait - dependencyElapsed()
            try await Task.sleep(for: .seconds(min(0.25, max(0.001, remaining))))
        }
    }

    private func dependencyElapsed() -> TimeInterval {
        excludedTime + (waitStartedAt.map { max(0, now() - $0) } ?? 0)
    }
    private func activeElapsed() -> TimeInterval { max(0, now() - startedAt - dependencyElapsed()) }
    private func endWait(_ token: UUID) {
        guard waitTokens.remove(token) != nil, waitTokens.isEmpty else { return }
        if let start = waitStartedAt { excludedTime += max(0, now() - start) }
        waitStartedAt = nil
    }

    public func snapshot() -> GenerationUsage { usage }

    func beginModel(_ model: String) throws {
        try check()
        usage.attemptedModels.append(model)
    }

    func recordUpgrade(reason: String) throws {
        try check()
        usage.routingReason = reason
    }

    func beginRequest(limit: Int) throws {
        try check()
        guard usage.requests < min(maximumRequests, limit) else {
            throw AgentError.limit("Generation reached its request limit. The project was not changed.")
        }
        guard usage.outputTokens < maximumOutputTokens else {
            throw AgentError.limit("Generation reached its token limit. The project was not changed.")
        }
        usage.requests += 1
    }

    /// Reserves one of at most two retries for the entire prompt. No retry is
    /// consumed when no request or backoff fits in the remaining budget.
    func reserveRetry(limit: Int) throws -> TimeInterval? {
        try check()
        guard usage.retries < maximumRetries,
              usage.requests < min(maximumRequests, limit), usage.outputTokens < maximumOutputTokens else { return nil }
        let delay: TimeInterval = usage.retries == 0 ? 1 : 3
        guard try remainingTime() > delay else {
            throw AgentError.limit("There is not enough time left to reconnect. The project was not changed.")
        }
        usage.retries += 1
        return delay
    }

    func recordUsage(inputTokens: Int, outputTokens: Int) throws {
        usage.inputTokens += max(0, inputTokens)
        usage.outputTokens += max(0, outputTokens)
        guard usage.outputTokens <= maximumOutputTokens else {
            throw AgentError.limit("Generation reached its token limit. The project was not changed. Try a shorter section.")
        }
        try check()
    }
}

public struct GenerationUsage: Sendable, Equatable {
    public var requests = 0
    public var retries = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var attemptedModels: [String] = []
    public var routingReason: String?
}
