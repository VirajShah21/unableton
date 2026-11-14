import AppKit
import UnabletonCore

@MainActor
protocol SoundDownloadConsentPresenting: AnyObject {
    func present(id: UUID, bankIDs: Set<String>, automatic: Bool, completion: @escaping @MainActor (Bool) -> Void)
    func update(id: UUID, bankIDs: Set<String>)
    func dismiss(id: UUID)
}

/// Automatic requests share one explicit opt-in. Manual requests share a sheet
/// only when they disclose the exact same banks. Unrelated approvals serialize.
@MainActor
final class SoundDownloadConsentCoordinator {
    private struct Waiter {
        let banks: Set<String>
        let continuation: CheckedContinuation<Bool, Never>
    }
    private struct Group {
        let id = UUID()
        let automatic: Bool
        var waiters: [UUID: Waiter]
        var banks: Set<String> { waiters.values.reduce(into: []) { $0.formUnion($1.banks) } }
        func accepts(_ banks: Set<String>, automatic: Bool) -> Bool {
            self.automatic == automatic && (automatic || self.banks == banks)
        }
    }
    private let presenter: any SoundDownloadConsentPresenting
    private let automaticApproval: @MainActor () -> Void
    private var active: Group?
    private var queued: [Group] = []

    init(presenter: any SoundDownloadConsentPresenting,
         automaticApproval: @escaping @MainActor () -> Void) {
        self.presenter = presenter; self.automaticApproval = automaticApproval
    }

    func request(bankIDs: Set<String>, automatic: Bool) async throws -> Bool {
        try Task.checkCancellation()
        let token = UUID()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let waiter = Waiter(banks: bankIDs, continuation: continuation)
                if var group = active, group.accepts(bankIDs, automatic: automatic) {
                    group.waiters[token] = waiter; active = group
                    presenter.update(id: group.id, bankIDs: group.banks)
                } else if let index = queued.firstIndex(where: { $0.accepts(bankIDs, automatic: automatic) }) {
                    queued[index].waiters[token] = waiter
                } else { queued.append(Group(automatic: automatic, waiters: [token: waiter])) }
                pump()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(token) } }
        try Task.checkCancellation()
        return accepted
    }

    private func cancel(_ token: UUID) {
        if var group = active, let waiter = group.waiters.removeValue(forKey: token) {
            waiter.continuation.resume(returning: false)
            if group.waiters.isEmpty {
                // Retire the token before dismissing AppKit's sheet. Its delayed
                // completion must never resolve a subsequent group's waiters.
                active = nil; presenter.dismiss(id: group.id); pump()
            } else {
                active = group; presenter.update(id: group.id, bankIDs: group.banks)
            }
            return
        }
        for index in queued.indices {
            if let waiter = queued[index].waiters.removeValue(forKey: token) {
                waiter.continuation.resume(returning: false)
                if queued[index].waiters.isEmpty { queued.remove(at: index) }
                return
            }
        }
    }
    private func pump() {
        guard active == nil, !queued.isEmpty else { return }
        let group = queued.removeFirst(); active = group
        presenter.present(id: group.id, bankIDs: group.banks, automatic: group.automatic) { [weak self] accepted in
            self?.finish(group.id, accepted: accepted)
        }
    }
    private func finish(_ id: UUID, accepted: Bool) {
        guard let group = active, group.id == id else { return }
        active = nil
        if accepted && group.automatic && !group.waiters.isEmpty { automaticApproval() }
        for waiter in group.waiters.values { waiter.continuation.resume(returning: accepted) }
        pump()
    }
}

@MainActor
final class NativeSoundDownloadConsentPresenter: SoundDownloadConsentPresenting {
    private var current: (id: UUID, alert: NSAlert, automatic: Bool)?
    func present(id: UUID, bankIDs: Set<String>, automatic: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard let window = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow ?? NSApp.keyWindow else {
            completion(false); return
        }
        let alert = NSAlert()
        alert.messageText = automatic ? "Allow automatic sound downloads?" : "Download required sounds?"
        alert.addButton(withTitle: automatic ? "Allow & Download" : "Download Required Sounds")
        alert.addButton(withTitle: "Cancel")
        current = (id, alert, automatic)
        update(id: id, bankIDs: bankIDs)
        alert.beginSheetModal(for: window) { [weak self] response in
            if self?.current?.id == id { self?.current = nil }
            completion(response == .alertFirstButtonReturn)
        }
    }
    func update(id: UUID, bankIDs: Set<String>) {
        guard let current, current.id == id else { return }
        let banks = bankIDs.compactMap { SoundBankCatalog.bank(id: $0) }
        let size = ByteCountFormatter.string(fromByteCount: banks.reduce(0) { $0 + $1.downloadBytes }, countStyle: .file)
        let names = InstrumentCatalog.presets.filter { preset in preset.soundBankID.map(bankIDs.contains) ?? false }.map(\.name)
        let listedNames = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "")
        current.alert.informativeText = "Required sounds: \(listedNames).\n\n\(banks.count) sound bank(s), about \(size). " +
            (current.automatic ? "Allow Unableton to download sounds selected by AI for this and future generations. You can turn this off in Settings." : "These sounds will be installed for all your songs and remain available offline.")
    }
    func dismiss(id: UUID) {
        guard let current, current.id == id else { return }
        self.current = nil
        current.alert.window.sheetParent?.endSheet(current.alert.window, returnCode: .alertSecondButtonReturn)
    }
}
