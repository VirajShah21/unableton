import Foundation
import Testing
@testable import UnabletonAI

struct GenerationBudgetTests {
    @Test func requestAndRetryReservationsShareOneCounter() async throws {
        let budget = GenerationBudget(maximumRequests: 4)
        try await budget.beginRequest(limit: 4)
        #expect(try await budget.reserveRetry(limit: 4) == 1)
        try await budget.beginRequest(limit: 4)
        #expect(try await budget.reserveRetry(limit: 4) == 3)
        try await budget.beginRequest(limit: 4)
        #expect(try await budget.reserveRetry(limit: 4) == nil)
        let usage = await budget.snapshot()
        #expect(usage.requests == 3)
        #expect(usage.retries == 2)
    }

    @Test func unusableRetriesDoNotConsumeTheirAllowance() async throws {
        let full = GenerationBudget(maximumRequests: 1)
        try await full.beginRequest(limit: 1)
        #expect(try await full.reserveRetry(limit: 1) == nil)
        #expect(await full.snapshot().retries == 0)
        let short = GenerationBudget(timeout: 0.1)
        await #expect(throws: AgentError.self) { _ = try await short.reserveRetry(limit: 32) }
        #expect(await short.snapshot().retries == 0)
    }

    @Test func invalidLimitsAndHardCapsAreChecked() async throws {
        for budget in [GenerationBudget(maximumRequests: 0), GenerationBudget(timeout: .nan), GenerationBudget(timeout: 0), GenerationBudget(maximumRetries: -1)] {
            await #expect(throws: AgentError.self) { try await budget.check() }
        }
        let budget = GenerationBudget(maximumRequests: 100, timeout: 1000, maximumRetries: 100)
        #expect(budget.maximumRequests == 32)
        #expect(try await budget.remainingTime() <= 300)
        #expect(try await budget.reserveRetry(limit: 64) == 1)
        #expect(try await budget.reserveRetry(limit: 64) == 3)
        #expect(try await budget.reserveRetry(limit: 64) == nil)
    }

    @Test func deadlineAndOutputBudgetRemainAbsolute() async throws {
        let budget = GenerationBudget(timeout: 0.02)
        try await budget.beginRequest(limit: 32)
        try await budget.recordUsage(inputTokens: 100, outputTokens: 65_536)
        await #expect(throws: AgentError.self) { try await budget.beginRequest(limit: 32) }
        try await Task.sleep(for: .milliseconds(40))
        await #expect(throws: AgentError.self) { try await budget.remainingTime() }
        #expect(await budget.snapshot().requests == 1)
        #expect(await budget.snapshot().outputTokens == 65_536)
    }
}

private final class BudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ amount: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += amount }
}

private actor BudgetGate {
    private var entered = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func hasEntered() -> Bool { entered }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

struct DependencyBudgetTests {
    private func entered(_ gate: BudgetGate) async throws {
        for _ in 0..<1000 {
            if await gate.hasEntered() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw InstrumentDependencyError("Test dependency scope did not start")
    }

    @Test func overlappingWaitsPauseOnceAndPreserveEveryCounter() async throws {
        let clock = BudgetClock()
        let budget = GenerationBudget(timeout: 100, now: { clock.now() })
        try await budget.beginModel("first")
        try await budget.beginRequest(limit: 32)
        _ = try await budget.reserveRetry(limit: 32)
        try await budget.recordUpgrade(reason: "constraints")
        try await budget.recordUsage(inputTokens: 42, outputTokens: 17)
        clock.advance(10)
        let first = BudgetGate(), second = BudgetGate()
        let a = Task { try await budget.withDependencyWait { await first.wait() } }
        try await entered(first)
        clock.advance(60)
        let b = Task { try await budget.withDependencyWait { await second.wait() } }
        try await entered(second)
        clock.advance(60)
        await first.release(); try await a.value
        clock.advance(60)
        await second.release(); try await b.value
        #expect(try await budget.remainingTime() == 90)
        clock.advance(20)
        #expect(try await budget.remainingTime() == 70)
        let usage = await budget.snapshot()
        #expect(usage.requests == 1 && usage.retries == 1)
        #expect(usage.inputTokens == 42 && usage.outputTokens == 17)
        #expect(usage.attemptedModels == ["first"] && usage.routingReason == "constraints")
    }

    @Test func failingWaitResumesClockAndExhaustedWaitCannotRestart() async throws {
        let clock = BudgetClock()
        let budget = GenerationBudget(timeout: 100, maximumDependencyWait: 50, now: { clock.now() })
        await #expect(throws: InstrumentDependencyError.self) {
            try await budget.withDependencyWait {
                clock.advance(20)
                throw InstrumentDependencyError("Download failed")
            }
        }
        clock.advance(10)
        #expect(try await budget.remainingTime() == 90)
        await #expect(throws: InstrumentDependencyError.self) {
            try await budget.withDependencyWait { clock.advance(31) }
        }
        await #expect(throws: InstrumentDependencyError.self) {
            try await budget.withDependencyWait { }
        }
    }

    @Test func expiredActiveBudgetCannotBeRevivedByDownload() async throws {
        let clock = BudgetClock()
        let budget = GenerationBudget(timeout: 10, now: { clock.now() })
        clock.advance(11)
        await #expect(throws: AgentError.self) {
            try await budget.withDependencyWait { }
        }
    }

    @Test func watchdogSurvivesPausedWallTimeAndExpiresAfterResume() async throws {
        let budget = GenerationBudget(timeout: 0.1)
        let watchdog = Task<Void, any Error> { try await budget.waitUntilExpired() }
        try await budget.withDependencyWait {
            try await Task.sleep(for: .milliseconds(180))
        }
        #expect(try await budget.remainingTime() > 0)
        await #expect(throws: AgentError.self) { try await watchdog.value }
    }

    @Test func dependencyWaitHasOwnTimeoutAndCancellation() async throws {
        let short = GenerationBudget(timeout: 100, maximumDependencyWait: 0.03)
        await #expect(throws: InstrumentDependencyError.self) {
            try await short.withDependencyWait { try await Task.sleep(for: .seconds(60)) }
        }
        let budget = GenerationBudget(timeout: 100)
        let task = Task {
            try await budget.withDependencyWait { try await Task.sleep(for: .seconds(60)) }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await budget.remainingTime() > 99)
    }
}
