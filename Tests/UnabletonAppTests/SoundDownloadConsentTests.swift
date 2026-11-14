import Foundation
import Testing
@testable import Unableton

@MainActor
private final class ConsentPresenterFixture: SoundDownloadConsentPresenting {
    struct Call { let id: UUID; let automatic: Bool }
    var calls: [Call] = []
    var banks: [UUID: Set<String>] = [:]
    var dismissed: [UUID] = []
    private var completions: [UUID: @MainActor (Bool) -> Void] = [:]
    func present(id: UUID, bankIDs: Set<String>, automatic: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        calls.append(Call(id: id, automatic: automatic)); banks[id] = bankIDs; completions[id] = completion
    }
    func update(id: UUID, bankIDs: Set<String>) { banks[id] = bankIDs }
    func dismiss(id: UUID) { dismissed.append(id) }
    func respond(_ id: UUID, _ accepted: Bool) { completions[id]?(accepted) }
}

@MainActor
struct SoundDownloadConsentTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Consent fixture did not reach the expected state")
    }

    @Test func automaticWaitersShareUpdatedTotalsAndCancelIndependently() async throws {
        let presenter = ConsentPresenterFixture()
        var approvals = 0
        let coordinator = SoundDownloadConsentCoordinator(presenter: presenter) { approvals += 1 }
        let first = Task { try await coordinator.request(bankIDs: ["piano"], automatic: true) }
        try await wait { presenter.calls.count == 1 }
        let id = try #require(presenter.calls.first?.id)
        let second = Task { try await coordinator.request(bankIDs: ["guitar"], automatic: true) }
        try await wait { presenter.banks[id] == ["piano", "guitar"] }
        #expect(presenter.calls.count == 1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(presenter.banks[id] == ["guitar"])
        #expect(presenter.dismissed.isEmpty)
        presenter.respond(id, true)
        #expect(try await second.value)
        #expect(approvals == 1)
    }

    @Test func lateCompletionOfCanceledSheetCannotResolveNewRequest() async throws {
        let presenter = ConsentPresenterFixture()
        var approvals = 0
        let coordinator = SoundDownloadConsentCoordinator(presenter: presenter) { approvals += 1 }
        let first = Task { try await coordinator.request(bankIDs: ["piano"], automatic: true) }
        try await wait { presenter.calls.count == 1 }
        let old = try #require(presenter.calls.first?.id)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(presenter.dismissed == [old])
        let second = Task { try await coordinator.request(bankIDs: ["guitar"], automatic: true) }
        try await wait { presenter.calls.count == 2 }
        let current = try #require(presenter.calls.last?.id)
        #expect(current != old)
        presenter.respond(old, true)
        #expect(approvals == 0)
        presenter.respond(current, true)
        #expect(try await second.value)
        #expect(approvals == 1)
    }

    @Test func manualApprovalDoesNotAuthorizeAutomaticOrDifferentManualDownloads() async throws {
        let presenter = ConsentPresenterFixture()
        var approvals = 0
        let coordinator = SoundDownloadConsentCoordinator(presenter: presenter) { approvals += 1 }
        let manual = Task { try await coordinator.request(bankIDs: ["piano"], automatic: false) }
        try await wait { presenter.calls.count == 1 }
        let automatic = Task { try await coordinator.request(bankIDs: ["guitar"], automatic: true) }
        let otherManual = Task { try await coordinator.request(bankIDs: ["drums"], automatic: false) }
        for _ in 0..<10 { await Task.yield() }
        let first = try #require(presenter.calls.first?.id)
        #expect(presenter.banks[first] == ["piano"])
        #expect(presenter.calls.count == 1)
        presenter.respond(first, true)
        #expect(try await manual.value)
        #expect(approvals == 0)
        try await wait { presenter.calls.count == 2 }
        let second = try #require(presenter.calls.last)
        presenter.respond(second.id, true)
        try await wait { presenter.calls.count == 3 }
        let third = try #require(presenter.calls.last)
        #expect(second.automatic != third.automatic)
        #expect(presenter.banks[second.id] != presenter.banks[third.id])
        presenter.respond(third.id, false)
        let automaticResult = try await automatic.value, manualResult = try await otherManual.value
        #expect(automaticResult == second.automatic)
        #expect(manualResult != second.automatic)
        #expect(approvals == (second.automatic ? 1 : 0))
    }

    @Test func cancelingQueuedManualRequestDoesNotShowItsSheet() async throws {
        let presenter = ConsentPresenterFixture()
        let coordinator = SoundDownloadConsentCoordinator(presenter: presenter) {}
        let first = Task { try await coordinator.request(bankIDs: ["piano"], automatic: false) }
        try await wait { presenter.calls.count == 1 }
        let second = Task { try await coordinator.request(bankIDs: ["guitar"], automatic: false) }
        for _ in 0..<10 { await Task.yield() }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        presenter.respond(try #require(presenter.calls.first?.id), false)
        #expect(try await first.value == false)
        #expect(presenter.calls.count == 1)
    }
}
