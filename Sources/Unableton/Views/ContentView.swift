import SwiftUI
import UnabletonCore

struct ContentView: View {
    @ObservedObject var session: ProjectSession
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("clipEditorHeight") private var preferredEditorHeight = 280.0
    @SceneStorage("transcriptionHeight") private var preferredTranscriptionHeight = 380.0
    @State private var workspaceHeight: CGFloat = 768
    @State private var titlebarInset: CGFloat = 0
    var body: some View {
        FloatingChatWorkspace(session: session) {
            workspace
        }
        .frame(minWidth: 1000, minHeight: 660)
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(TitlebarInsetReader { titlebarInset = $0 })
        .alert("Unableton", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .onChange(of: session.audio.error) { _, value in
            if let value {
                if session.transcription.isCapturing, !session.audio.isTranscribingCapture { session.transcription.captureFailed(value) }
                else { session.errorMessage = value }
            }
        }
        .onChange(of: session.audio.interruptedRecording) { _, _ in session.recoverInterruptedRecording() }
        .onChange(of: session.audio.completedTranscription) { _, _ in
            if let take = session.audio.takeCompletedTranscription() { session.showTranscription(); session.transcription.receive(take) }
        }
        .onChange(of: session.audio.interruptedTranscription) { _, _ in
            if let take = session.audio.takeInterruptedTranscription() { session.showTranscription(); session.transcription.receive(take, interrupted: true) }
        }
    }
    private var workspace: some View {
        VStack(spacing: 0) {
            TimelineView(session: session, titlebarInset: titlebarInset)
                .frame(minWidth: 540, minHeight: 260, maxHeight: .infinity)
                // The timeline extends only its decorative musical backdrop;
                // native scrollbars and controls stay on the visible canvas.
                .padding(.top, titlebarInset)
                .ignoresSafeArea(.container, edges: .top)
            if session.editorVisible || session.transcriptionVisible {
                PaneResizeHandle(axis: .vertical, label: session.canEditMusic ? "Editor height" : "Inspector height", coordinateSpace: "musicWorkspace", size: Binding(
                    get: { paneHeight },
                    set: {
                        let value = Double(min(maximumEditorHeight, max(200, $0)))
                        if session.transcriptionVisible { preferredTranscriptionHeight = value } else { preferredEditorHeight = value }
                    }
                ))
                Group {
                    if session.transcriptionVisible { TranscriptionView(session: session, store: session.transcription) }
                    else { ClipEditorView(session: session) }
                }.frame(height: paneHeight)
            }
        }
        .overlay(alignment: .topTrailing) {
            WorkspaceNoticeView(session: session)
                .frame(maxWidth: 360)
                .padding(.top, 54).padding(.horizontal, 16)
        }
        .coordinateSpace(name: "musicWorkspace")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { workspaceHeight = $0 }
    }
    private var maximumEditorHeight: CGFloat { min(460, max(200, workspaceHeight - 300)) }
    private var paneHeight: CGFloat { min(CGFloat(session.transcriptionVisible ? preferredTranscriptionHeight : preferredEditorHeight), maximumEditorHeight) }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // The native toolbar aligns transport with the traffic lights,
            // over the shared track glass, ahead of the document title.
            TransportControlsView(session: session).frame(width: 104)
        }.sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) {
            HStack(spacing: 16) {
                Text(TrackColors.position(session.audio.currentBeat, beatsPerBar: session.file.song.beatsPerBar))
                    .monospacedDigit().frame(minWidth: 70).accessibilityLabel("Position \(TrackColors.position(session.audio.currentBeat))")
                if session.canEditMusic {
                    TempoControl(session: session).fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("\(session.file.song.tempo.formatted(.number.precision(.fractionLength(0...1)))) BPM")
                        .monospacedDigit().font(.callout)
                        .accessibilityLabel("Tempo \(session.file.song.tempo.formatted()) beats per minute")
                }
                Text(session.file.song.key).font(.callout).foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View mode", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                ForEach(WorkspaceMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.menu)
            .help(session.canEditMusic ? "Producer: edit music directly" : "Superhuman: compose with AI and inspect every detail")
            .accessibilityValue(session.mode.title)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if session.canEditMusic {
                Menu {
                    Button("Instrument Track") { session.addInstrumentTrack() }
                    Button("Audio Track") { session.addAudioTrack() }
                    Button("Note Clip") { session.addNoteClip() }
                    Divider()
                    Button("Import Audio…") { session.importAudio() }
                } label: { Label("Add", systemImage: "plus") }
            } else {
                Button { session.importAudio() } label: { Label("Import Audio", systemImage: "square.and.arrow.down") }
                    .help("Import a recording or vocal (⇧⌘I)")
            }
            Button {
                SoundLibraryNavigation.shared.reveal(from: session)
                openWindow(id: "sound-library")
            } label: { Label("Sound Library", systemImage: "pianokeys") }
                .help("Browse, preview, download, and choose instruments")
                .accessibilityLabel("Sound Library")
            Button { session.editorVisible.toggle() } label: { Label(session.canEditMusic ? "Editor" : "Inspect", systemImage: "rectangle.bottomthird.inset.filled") }
                .help(session.canEditMusic ? "Show or hide editor" : "Show or hide inspector")
            Button { session.showTranscription() } label: { Label("Transcribe", systemImage: "waveform") }
                .help("Transcribe a performance (⇧⌘T)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { session.chatVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("Show or hide AI chat (⌃⌘S)")
                .accessibilityLabel(session.chatVisible ? "Hide AI chat" : "Show AI chat")
        }
    }
}

private struct TempoControl: View {
    @ObservedObject var session: ProjectSession
    @State private var text = "140"
    var body: some View {
        HStack(spacing: 3) {
            TextField("Tempo", text: $text).textFieldStyle(.plain).frame(width: 48).multilineTextAlignment(.trailing)
                .onSubmit { if session.canEditMusic, let value = Double(text) { session.setTempo(value) }; refresh() }
                .accessibilityLabel("Tempo in beats per minute")
            Text("BPM").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
        .onChange(of: session.file.song.tempo) { _, _ in refresh() }
    }
    private func refresh() { text = session.file.song.tempo.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) }
}
