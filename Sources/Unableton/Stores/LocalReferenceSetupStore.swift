import Foundation
import AppKit
import Combine
import UnabletonAudio

struct LocalReferenceAvailability: Sendable, Equatable {
    var installed: Bool
    var message: String
}

/// Readiness checks never install packages, download models, or upload audio.
@MainActor
final class LocalReferenceSetupStore: ObservableObject {
    typealias Check = @Sendable () async -> LocalReferenceAvailability
    typealias Install = @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void

    static let shared: LocalReferenceSetupStore = {
        let resources = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("LocalProcessing", isDirectory: true)
        let engine = LocalReferenceEngine(resourcesDirectory: resources)
        return LocalReferenceSetupStore(check: {
            let state = await Task.detached { engine.state() }.value
            return LocalReferenceAvailability(installed: state.installed, message: state.message)
        }, install: { status in try await engine.install(status: status) })
    }()

    @Published private(set) var availability: LocalReferenceAvailability?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var isCanceling = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?

    private let check: Check
    private let installer: Install
    private var setupTask: Task<Void, Never>?
    private var operationID = UUID()
    private var checkID = UUID()
    private var termination: AnyCancellable?

    init(check: @escaping Check, install: @escaping Install, notifications: NotificationCenter = .default) {
        self.check = check; self.installer = install
        termination = notifications.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
    }

    func refresh() async {
        guard !isInstalling else { return }
        let id = UUID(); checkID = id; isChecking = true
        defer { if checkID == id, !isInstalling { isChecking = false } }
        let result = await check()
        guard !Task.isCancelled, checkID == id, !isInstalling else { return }
        availability = result; isChecking = false
        if result.installed { error = nil; status = "" }
    }

    func install() {
        guard !isInstalling, !isChecking else { return }
        let id = UUID(), installer = installer, check = check
        operationID = id; checkID = UUID()
        isInstalling = true; isCanceling = false; error = nil
        status = "Setting up local song processing…"
        setupTask = Task { [weak self] in
            defer {
                if let self, self.operationID == id {
                    self.isInstalling = false; self.isCanceling = false; self.setupTask = nil
                }
            }
            do {
                try await installer { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.isInstalling, !self.isCanceling else { return }
                        self.status = text
                    }
                }
                try Task.checkCancellation()
                let ready = await check()
                try Task.checkCancellation()
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                self.availability = ready
                self.status = ready.installed ? "Local processing is ready." : ready.message
                if !ready.installed { self.error = ready.message }
            } catch is CancellationError {
                if let self, self.operationID == id { self.status = "Setup canceled. You can retry." }
            } catch {
                if let self, self.operationID == id { self.error = error.localizedDescription; self.status = "Setup couldn’t finish." }
            }
        }
    }

    func cancel() {
        guard isInstalling, !isCanceling else { return }
        isCanceling = true; status = "Canceling setup…"; setupTask?.cancel()
    }
}
