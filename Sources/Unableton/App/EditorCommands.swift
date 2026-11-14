import SwiftUI

struct EditorCommands: Commands {
    @FocusedObject private var session: ProjectSession?
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(WorkspaceMode.allCases) { mode in
                Toggle(mode.title, isOn: Binding(get: { session?.mode == mode }, set: { _ in session?.setMode(mode) }))
                .keyboardShortcut(mode == .superhuman ? "1" : "2", modifiers: [.control, .command])
                .disabled(session == nil)
            }
            Divider()
            Button("Show or Hide AI Chat") { session?.chatVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(session == nil)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Import Audio…") { session?.importAudio() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(session == nil)
            Button("Export WAV…") { session?.exportWAV() }.disabled(session?.file.song.tracks.isEmpty ?? true)
            Button("Export MIDI…") { session?.exportMIDI() }.disabled(session?.file.song.tracks.isEmpty ?? true)
        }
        CommandMenu("Track") {
            Button("Transcribe…") { session?.showTranscription() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(session == nil)
            if session?.canEditMusic == true {
                Divider()
                Button("Add Instrument Track") { session?.addInstrumentTrack() }.keyboardShortcut("t", modifiers: [.command])
                Button("Add Audio Track") { session?.addAudioTrack() }.keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("Add Note Clip") { session?.addNoteClip() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Duplicate Selection") { session?.duplicateSelection() }.keyboardShortcut("d", modifiers: [.command])
                Button("Delete Selection") { session?.deleteSelection() }.disabled(session?.selection.trackID == nil)
            }
        }
        CommandMenu("Transport") {
            Button(session?.audio.isPlaying == true ? "Pause" : "Play") { session?.togglePlayback() }.disabled(session == nil)
            Button("Stop") { session?.stop() }.keyboardShortcut(".", modifiers: [.command]).disabled(session == nil)
            Button(recordingActive ? "Stop Recording" : "Record") { session?.toggleRecording() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(session == nil)
            Divider()
            Toggle("Loop", isOn: Binding(get: { session?.file.song.loopEnabled == true }, set: { enabled in
                if let session, session.file.song.loopEnabled != enabled { session.toggleLoop() }
            })).disabled(session == nil)
            if session?.canEditMusic == true { Button("Metronome") { session?.toggleMetronome() } }
        }
    }
    private var recordingActive: Bool { session?.audio.isRecording == true || session?.audio.isTranscribingCapture == true }
}
