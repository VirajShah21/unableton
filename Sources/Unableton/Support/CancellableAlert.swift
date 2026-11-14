import AppKit

/// A sheet must not outlive the operation that requested it (for example Stop
/// during recording preparation). AppKit's completion runs once after dismissal.
@MainActor
final class CancellableAlert {
    let alert: NSAlert
    let window: NSWindow
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    init(_ alert: NSAlert, for window: NSWindow) { self.alert = alert; self.window = window }
    func response() async throws -> NSApplication.ModalResponse {
        try Task.checkCancellation()
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(.abort); return }
                alert.beginSheetModal(for: window) { [self] in finish($0) }
            }
        } onCancel: { Task { @MainActor [self] in
            if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .abort) }
            finish(.abort)
        } }
        try Task.checkCancellation()
        return response
    }
    private func finish(_ response: NSApplication.ModalResponse) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: response)
    }
}
