import AppKit
import SwiftUI
import UnabletonCore
import UnabletonAudio

struct TranscriptionView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var store: TranscriptionSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(minHeight: 0, maxHeight: .infinity).clipped()
            Divider()
            footer.fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .contain).accessibilityLabel("Transcribe")
    }
    private var header: some View {
        HStack(spacing: 12) {
            Text("Transcribe").font(.headline)
            Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if store.take != nil {
                Button("Record Again") { store.startCapture() }.controlSize(.small).disabled(captureBlocked)
                Menu {
                    Button("Listen to Recording") { store.playOriginal() }.disabled(!hasPlayableTake)
                    Button("Save Recording…") { store.saveOriginal() }
                    Button("Retry Analysis") { store.analyzeTake() }.disabled(!hasPlayableTake)
                    Menu("Interpret Recording As") {
                        ForEach(TranscriptionMode.allCases) { mode in
                            Button(mode.displayName) { store.configureMode(mode); store.analyzeTake() }
                        }
                    }.disabled(!hasPlayableTake)
                    Divider()
                    Button("Use Another Audio File…") { store.chooseAudioFile() }
                    Button("Show Recovered Takes") {
                        try? FileManager.default.createDirectory(at: TranscriptionSession.recoveryDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(TranscriptionSession.recoveryDirectory)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Recording actions")
                .disabled(store.isWorking || store.isCapturing)
            }
            Button { session.transcriptionVisible = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close Transcribe").accessibilityLabel("Close Transcribe")
        }.padding(.horizontal, 14).frame(height: 42)
    }
    @ViewBuilder private var content: some View {
        if store.isCapturing || store.isWorking {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        if store.phase != .recording { ProgressView().controlSize(.small) }
                        Text(workingTitle).font(.headline)
                        Spacer()
                        if store.phase == .recording {
                            Text("\(Int(session.audio.transcriptionElapsedSeconds)) / 60 s").monospacedDigit().font(.callout)
                        }
                    }
                    Text(store.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if store.isCapturing {
                        TranscriptionInputMeter(session: session)
                        Text(store.phase == .starting ? "Allow microphone access if macOS asks. Begin when the recording timer starts." : "Follow the arrangement above. Choose Stop & Transcribe when you finish; note detection starts automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(store.phase == .analyzing ? "Your recording is being turned into notes. It has not been added to the song." : "Your original recording and song are kept until this step finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        } else if store.transcript != nil {
            review
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = store.error {
                        failure(error)
                        Divider()
                    } else if store.take != nil {
                        Text("Your recording is ready to transcribe").font(.headline)
                        Text(takeSummary).font(.caption).foregroundStyle(.secondary)
                        Text("Analyze the recording to find notes, then preview the result and add it to your song.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Turn a performance into music").font(.headline)
                        Text("Choose what you’ll perform, record it, then choose Stop & Transcribe. You can preview the detected music before adding it to the song.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    TranscriptionCaptureOptionsView(session: session, store: store)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
    }
    private func failure(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.take == nil ? "Transcription couldn’t continue" : !hasPlayableTake ? "No microphone audio was recorded" : "Couldn’t transcribe this recording", systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.red)
            Text(error).font(.callout).textSelection(.enabled)
            if store.take != nil {
                Text(takeSummary).font(.caption).foregroundStyle(.secondary)
                Text(hasPlayableTake ? "Your original recording is kept. Retry analysis, listen to it, or save a copy." : "The recording contains no audio to transcribe. Check microphone access and your input device, then record again.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Retry Analysis") { store.analyzeTake() }.disabled(!hasPlayableTake)
                    Button("Listen to Recording") { store.playOriginal() }.disabled(!hasPlayableTake)
                    Button("Save Recording…") { store.saveOriginal() }
                }.controlSize(.small)
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Transcription error")
    }
    private var review: some View {
        GeometryReader { geometry in
            if geometry.size.height < 240 {
                ScrollView { reviewContents(detailsHeight: 150) }
            } else {
                reviewContents()
            }
        }
    }
    private func reviewContents(detailsHeight: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let error = store.error {
                    Label("This step couldn’t finish", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.red)
                    Text(error).font(.caption).textSelection(.enabled)
                } else if store.alreadyInserted {
                    Label("Added \(store.options.layers.count) \(store.options.layers.count == 1 ? "track" : "tracks") to your song", systemImage: "checkmark.circle").font(.headline)
                    Text("At \(destination). Play the result or show the added track in the arrangement.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Found \(store.transcript?.events.count ?? 0) \(store.mode == .beatboxing ? "drum hits" : "notes")").font(.headline)
                    Text("Preview does not add tracks. Choose Add to Song when you’re ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(reviewSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Picker("Transcription review", selection: $store.reviewTab) {
                Text("Notes").tag("Notes"); Text("Timing & Placement").tag("Timing"); Text("Sound & Layers").tag("Layers")
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                if store.reviewTab == "Notes" { TranscriptionNotesView(store: store, canEditMusic: session.canEditMusic) }
                else if store.reviewTab == "Timing" { TranscriptionTimingView(session: session, store: store) }
                else { TranscriptionLayersView(store: store) }
            }.frame(height: detailsHeight)
                .frame(maxWidth: .infinity, maxHeight: detailsHeight == nil ? .infinity : nil)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(footerStatus).font(.caption).lineLimit(2)
                if let result = store.prepared?.result {
                    Text("\(result.model) · \(result.inputTokens + result.outputTokens) tokens\(result.routingReason.map { " · \($0)" } ?? "")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if store.phase == .recording {
                Button("Stop & Transcribe") { store.finishCapture() }.buttonStyle(.borderedProminent).tint(.red)
            } else if store.isWorking {
                ProgressView().controlSize(.mini)
                Button("Cancel") { store.cancelWork() }
            } else if store.alreadyInserted {
                Button("Show Track") { store.revealInSong() }
                Button("Play in Song") { store.playInSong() }.buttonStyle(.borderedProminent)
            } else if store.transcript != nil {
                Button(store.effectiveOptions.requiresAI ? "Preview Arrangement" : "Preview Instrument") { store.preview() }
                Button("Add to Song") { store.addToSong() }
                    .buttonStyle(.borderedProminent).disabled(store.options.layers.count > store.availableTracks)
            } else if store.take != nil, hasPlayableTake {
                Button("Listen to Recording") { store.playOriginal() }
                Button("Transcribe Recording") { store.analyzeTake() }.buttonStyle(.borderedProminent)
            } else {
                Button("Use Audio File…") { store.chooseAudioFile() }.disabled(session.audio.isRecording)
                Button(store.take == nil ? "Record \(store.mode.displayName)" : "Record Again") { store.startCapture() }
                    .buttonStyle(.borderedProminent).disabled(captureBlocked)
            }
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
    }
    private var hasPlayableTake: Bool { (store.take?.duration ?? 0) > 0 }
    private var captureBlocked: Bool { store.isWorking || store.isCapturing || session.audio.isRecording || session.isGenerating }
    private var destination: String { TrackColors.position(store.effectiveOptions.insertionBeat, beatsPerBar: session.file.song.beatsPerBar) }
    private var takeSummary: String { "\((store.take?.duration ?? 0).formatted(.number.precision(.fractionLength(0...1)))) s · \(store.mode.displayName)" }
    private var reviewSummary: String {
        let sounds = store.options.layers.map { InstrumentCatalog.preset(id: $0.instrumentID)?.name ?? $0.name }.joined(separator: ", ")
        return "\(takeSummary) · \(sounds) · \(store.options.timing.displayName) · Start \(destination)"
    }
    private var footerStatus: String {
        if store.alreadyInserted { return "The entire addition can be undone with ⌘Z." }
        if store.transcript != nil, store.options.layers.count > store.availableTracks { return "Not enough track slots. Remove a layer or use another song." }
        if store.error != nil {
            if store.transcript != nil { return "Your recording is kept. Preview or Add to Song to retry." }
            if store.take == nil { return "Record a performance or choose an audio file to continue." }
            return hasPlayableTake ? "The recording is kept. Retry or record another take." : "Check the microphone input, then record again."
        }
        if store.take == nil, !store.isWorking, !store.isCapturing { return "Record → Review → Add to Song" }
        return store.status
    }
    private var step: String {
        if store.alreadyInserted { return "Added to Song" }
        switch store.phase {
        case .ready, .starting, .recording: return "1 · Record"
        case .analyzing, .review, .arranging: return "2 · Review"
        case .inserting: return "3 · Add to Song"
        }
    }
    private var workingTitle: String {
        switch store.phase {
        case .starting: return "Preparing the microphone…"
        case .recording:
            switch store.mode {
            case .whistle: return "Whistle now"
            case .humming: return "Hum now"
            case .singing: return "Sing now"
            case .beatboxing: return "Beatbox now"
            }
        case .analyzing: return "Finding notes in your recording…"
        case .arranging: return store.effectiveOptions.requiresAI ? "Preparing your arrangement…" : "Preparing the instrument…"
        case .inserting: return "Adding music to your song…"
        case .ready, .review: return "Transcribe"
        }
    }
}
