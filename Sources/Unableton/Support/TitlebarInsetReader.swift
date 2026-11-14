import AppKit
import SwiftUI

/// Reads a document window's native titlebar inset for its sidebar surface.
/// It does not replace, move or change the window's standard controls/delegate.
struct TitlebarInsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> InsetView {
        let view = InsetView(); view.onChange = onChange; return view
    }
    func updateNSView(_ view: InsetView, context: Context) { view.onChange = onChange; view.measure() }
    static func dismantleNSView(_ view: InsetView, coordinator: ()) { view.stopObserving() }

    final class InsetView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastInset: CGFloat?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.measure() }
                })
            }
            measure()
        }
        override func layout() { super.layout(); measure() }
        func measure() {
            guard let window else { return }
            let inset = max(0, window.frame.height - window.contentLayoutRect.maxY)
            guard inset.isFinite, lastInset != inset else { return }
            lastInset = inset
            // Publish after AppKit/SwiftUI finish their current layout update.
            Task { @MainActor [weak self] in
                guard let self, self.window === window, self.lastInset == inset else { return }
                self.onChange?(inset)
            }
        }
        func stopObserving() {
            for token in observers { NotificationCenter.default.removeObserver(token) }
            observers.removeAll(); lastInset = nil
        }
    }
}
