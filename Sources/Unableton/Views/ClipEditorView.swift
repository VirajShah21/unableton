import SwiftUI
import UnabletonCore

struct ClipEditorView: View {
    @ObservedObject var session: ProjectSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(session.selectedClip?.name ?? session.selectedTrack?.name ?? (session.canEditMusic ? "Editor" : "Inspect")).font(.headline).lineLimit(1)
                if let clip = session.selectedClip, let id = clip.transcriptionAssetID,
                   let asset = session.file.song.assets.first(where: { $0.id == id }), let take = asset.transcriptionTake {
                    Menu {
                        Text("\(take.transcript.mode.displayName) · \(take.transcript.events.count) detected events")
                        Button("Play Original Take") {
                            if let url = session.assetURLs[id] { session.previewURL = url; session.playPreview() }
                        }
                        Button("Transcribe Again…") {
                            if let url = session.assetURLs[id] {
                                session.transcription.configureMode(take.transcript.mode); session.showTranscription()
                                session.transcription.importTake(url: url, at: clip.startBeat, recordedTempo: take.recordedTempo)
                            }
                        }
                    } label: { Image(systemName: "waveform") }.menuStyle(.borderlessButton).fixedSize()
                        .help("Transcription source").accessibilityLabel("Transcription source")
                }
                Spacer()
                Picker(session.canEditMusic ? "Editor" : "Inspect", selection: $session.editorTab) {
                    Text("Notes").tag("Notes"); Text("Instrument").tag("Instrument"); Text("Effects").tag("Effects")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
                Button { session.editorVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(session.canEditMusic ? "Close editor" : "Close inspector").accessibilityLabel(session.canEditMusic ? "Close editor" : "Close inspector")
            }.padding(.horizontal, 14).frame(height: 42)
            Divider()
            if session.editorTab == "Notes" {
                if let clip = session.selectedClip {
                    if clip.kind == .notes { PianoRollView(session: session, clip: clip) }
                    else { audioClipEditor(clip) }
                } else {
                    ContentUnavailableView {
                        Label("Select a clip", systemImage: "pianokeys")
                    } description: {
                        Text(session.canEditMusic ? "Select a note clip to edit its notes, or add a new one." : "Select a clip to inspect its notes, audio, or source information.")
                    } actions: {
                        if session.canEditMusic { Button("Add Note Clip") { session.addNoteClip() } }
                    }
                }
            } else {
                InstrumentEditorView(session: session, effectsOnly: session.editorTab == "Effects")
            }
        }
    }
    private func audioClipEditor(_ clip: Clip) -> some View {
        Form {
            InspectionValue("Type", value: "Audio")
            if session.canEditMusic {
            EditableNumber(label: "Start beat", value: clip.startBeat + 1, range: 1...200_000) { value in
                session.perform([ProjectCommand(op: .moveClip, clipID: clip.id, startBeat: value - 1)], name: "Move Clip")
            }
            EditableNumber(label: "Length in beats", value: clip.lengthBeats, range: 0.0625...200_000) { value in
                session.perform([ProjectCommand(op: .trimClip, clipID: clip.id, lengthBeats: value)], name: "Trim Clip")
            }
            } else {
                InspectionValue("Start beat", value: (clip.startBeat + 1).formatted())
                InspectionValue("Length in beats", value: clip.lengthBeats.formatted())
            }
            if let asset = session.file.song.assets.first(where: { $0.id == clip.assetID }) {
                if let take = asset.vocalTake {
                    InspectionValue("Vocal provider", value: take.provider)
                    InspectionValue("Singer", value: take.singerID)
                    Text(take.score.lyrics.joined(separator: " ")).textSelection(.enabled)
                    Text("Rendered at \(take.score.tempo.formatted()) BPM. Ask the AI to revise these lyrics or the source melody and render a new take.").font(.caption).foregroundStyle(.secondary)
                    if let source = session.file.song.clip(take.sourceClipID), let track = session.file.song.tracks.first(where: { $0.clips.contains(where: { $0.id == source.id }) }) {
                        Button("Open Source Melody") { session.select(track: track.id, clip: source.id) }
                    }
                }
                InspectionValue("Source", value: asset.fileName)
                InspectionValue("Recording", value: "\(asset.duration.formatted(.number.precision(.fractionLength(1)))) s · \(Int(asset.sampleRate)) Hz · \(asset.channels) ch")
                if let derivation = asset.referenceDerivation { ReferenceAudioSourceView(session: session, derivation: derivation) }
            }
            Text("Audio clips keep their original playback speed when the song tempo changes.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).textSelection(.enabled)
    }
}

struct EditableNumber: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(label, text: $text)
            .focused($focused)
            .onSubmit { apply() }
            .onChange(of: focused) { _, active in if !active { apply() } }
            .onAppear { refresh() }.onChange(of: value) { _, _ in if !focused { refresh() } }
    }
    private func apply() {
        if let next = Double(text), next.isFinite, range.contains(next) {
            if next != value { commit(next) }
            text = next.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
        } else { refresh() }
    }
    private func refresh() { text = value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) }
}
