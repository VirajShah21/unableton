import Foundation
import AppKit
import Testing
@testable import Unableton

private enum SetupFixtureError: LocalizedError {
    case failed
    var errorDescription: String? { "The model download failed." }
}

private actor LocalSetupFixture {
    private var installed = false
    private var checks = 0
    private var calls = 0
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var progress: [Int: @Sendable (String) -> Void] = [:]

    func check() -> LocalReferenceAvailability {
        checks += 1
        return LocalReferenceAvailability(installed: installed, message: installed ? "Models verified." : "Local models are not installed.")
    }
    func install(status: @escaping @Sendable (String) -> Void) async throws {
        let index = calls; calls += 1; progress[index] = status
        status("Downloading local models…")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { pending[index] = continuation }
            }
        } onCancel: { Task { await self.cancel(index) } }
        try Task.checkCancellation()
        installed = true
    }
    func callCount() -> Int { calls }
    func checkCount() -> Int { checks }
    func finish(_ index: Int, error: (any Error)? = nil) {
        guard let continuation = pending.removeValue(forKey: index) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func emit(_ index: Int, _ message: String) { progress[index]?(message) }
    private func cancel(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CancellationError()) }
}

@MainActor
private func waitForSetup(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw SetupFixtureError.failed }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct LocalReferenceSetupTests {
    private func store(_ fixture: LocalSetupFixture) -> LocalReferenceSetupStore {
        LocalReferenceSetupStore(check: { await fixture.check() }, install: { status in try await fixture.install(status: status) })
    }

    @Test func readinessCheckNeverInstallsAndRepeatedSetupSharesOneOperation() async throws {
        let fixture = LocalSetupFixture(), store = store(fixture)
        await store.refresh()
        #expect(await fixture.callCount() == 0)
        #expect(store.availability?.installed == false)
        store.install(); store.install()
        try await waitForSetup { await fixture.callCount() == 1 }
        #expect(store.isInstalling)
        await fixture.finish(0)
        try await waitForSetup { !store.isInstalling }
        #expect(store.availability?.installed == true)
        #expect(store.error == nil)
        #expect(await fixture.checkCount() == 2)
    }

    @Test func failureIsVisibleAndExplicitRetryCanComplete() async throws {
        let fixture = LocalSetupFixture(), store = store(fixture)
        store.install()
        try await waitForSetup { await fixture.callCount() == 1 }
        await fixture.finish(0, error: SetupFixtureError.failed)
        try await waitForSetup { !store.isInstalling }
        #expect(store.error == "The model download failed.")
        store.install()
        try await waitForSetup { await fixture.callCount() == 2 }
        #expect(store.error == nil)
        await fixture.finish(1)
        try await waitForSetup { !store.isInstalling }
        #expect(store.availability?.installed == true)
    }

    @Test func cancellationStopsSetupAndLateProgressCannotReplaceRetry() async throws {
        let fixture = LocalSetupFixture(), store = store(fixture)
        store.install()
        try await waitForSetup { await fixture.callCount() == 1 }
        store.cancel()
        try await waitForSetup { !store.isInstalling }
        #expect(!store.isCanceling)
        #expect(store.status.contains("canceled"))
        store.install()
        try await waitForSetup { await fixture.callCount() == 2 && store.status == "Downloading local models…" }
        await fixture.emit(0, "Old setup says ready")
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.status == "Downloading local models…")
        await fixture.finish(1)
        try await waitForSetup { !store.isInstalling }
        #expect(store.availability?.installed == true)
    }

    @Test func appTerminationCancelsAnOwnedSetupOperation() async throws {
        let fixture = LocalSetupFixture(), notifications = NotificationCenter()
        let store = LocalReferenceSetupStore(check: { await fixture.check() }, install: { status in
            try await fixture.install(status: status)
        }, notifications: notifications)
        store.install()
        try await waitForSetup { await fixture.callCount() == 1 }
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        try await waitForSetup { !store.isInstalling }
        #expect(store.status.contains("canceled"))
    }
}
