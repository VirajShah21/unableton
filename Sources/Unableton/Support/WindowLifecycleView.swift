import AppKit
import SwiftUI

/// Finalize recordings before the document controller asks whether to save.
/// Forward all other delegate messages to the document window's original delegate.
struct WindowLifecycleView: NSViewRepresentable {
    let document: UnabletonDocument
    let undoManager: UndoManager
    let prepareClose: () -> Void
    let didClose: () -> Void
    func makeNSView(context: Context) -> LifecycleView {
        let view = LifecycleView(); view.document = document; view.proxy.editingUndoManager = undoManager; view.proxy.prepareClose = prepareClose; view.proxy.didClose = didClose
        return view
    }
    func updateNSView(_ nsView: LifecycleView, context: Context) {
        nsView.proxy.editingUndoManager = undoManager; nsView.proxy.prepareClose = prepareClose; nsView.proxy.didClose = didClose
    }
    final class LifecycleView: NSView {
        let proxy = WindowDelegateProxy()
        var document: UnabletonDocument?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== proxy else { return }
            proxy.original = window.delegate; window.delegate = proxy
            if let document = window.windowController?.document as? NSDocument {
                document.hasUndoManager = true
                document.undoManager = proxy.editingUndoManager
                self.document?.nativeDocument = document
            }
        }
    }
    final class WindowDelegateProxy: NSObject, NSWindowDelegate {
        weak var original: (any NSWindowDelegate)?
        var editingUndoManager: UndoManager?
        var prepareClose: (() -> Void)?
        var didClose: (() -> Void)?
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editingUndoManager }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            prepareClose?()
            return original?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            didClose?(); original?.windowWillClose?(notification)
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
