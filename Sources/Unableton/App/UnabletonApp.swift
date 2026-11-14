import SwiftUI
import AppKit

@main
struct UnabletonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        DocumentGroup(newDocument: { UnabletonDocument() }) { configuration in
            EditorHost(document: configuration.document)
        }
        .defaultSize(width: 1320, height: 820)
        .commands { EditorCommands() }
        Window("Sound Library", id: "sound-library") { SoundLibraryView() }
            .defaultSize(width: 1120, height: 740)
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        SoundAuditionController.shared.shutdown()
    }
}
