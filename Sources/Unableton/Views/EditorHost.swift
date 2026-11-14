import SwiftUI
import AppKit

struct EditorHost: View {
    @ObservedObject var document: UnabletonDocument
    @StateObject private var session: ProjectSession
    @SceneStorage("workspaceMode") private var restoredMode = ""
    @State private var didRestoreMode = false
    init(document: UnabletonDocument) {
        self.document = document
        _session = StateObject(wrappedValue: ProjectSession(document: document))
    }
    var body: some View {
        ContentView(session: session)
            .focusedSceneObject(session)
            .onAppear {
                guard !didRestoreMode else { return }
                didRestoreMode = true
                if let mode = WorkspaceMode(rawValue: restoredMode) { session.setMode(mode, remember: false) }
                else { restoredMode = session.mode.rawValue }
            }
            .onChange(of: session.mode) { _, mode in restoredMode = mode.rawValue }
            .background(WindowLifecycleView(document: document, undoManager: document.editingUndoManager, prepareClose: {
                session.transcription.prepareForClose()
                if session.audio.isRecording { session.finishRecording() }
            }, didClose: { session.close() }))
    }
}
