import Foundation
import SwiftUI
import UnabletonCore
import UnabletonAudio

struct TranscriptionCaptureOptionsView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var store: TranscriptionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What will you perform?").font(.caption).foregroundStyle(.secondary)
            Picker("Performance type", selection: Binding(get: { store.mode }, set: {
                store.configureMode($0)
                if (store.take?.duration ?? 0) > 0 { store.analyzeTake() }
            })) {
                ForEach(TranscriptionMode.allCases) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().disabled(store.isWorking || store.isCapturing)
            Text(performanceDescription).font(.caption).foregroundStyle(.secondary)
            Text("While recording").font(.caption).foregroundStyle(.secondary)
            Picker("While recording", selection: $store.audition) {
                ForEach(TranscriptionAudition.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().disabled(store.isWorking || store.isCapturing)
                .onChange(of: store.audition) { _, _ in
                    if store.rehearsing, session.audio.isPlaying { store.rehearsing = false; store.rehearse() }
                }
            Text(auditionDescription).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(store.rehearsing && session.audio.isPlaying ? "Pause Rehearsal" : "Rehearse Without Recording") { store.rehearse() }
                    .disabled(store.isWorking || store.isCapturing || session.audio.isRecording)
                Toggle("Follow playhead", isOn: $store.followPlayhead).font(.caption).toggleStyle(.checkbox)
            }.controlSize(.small)
            Text("Your recording stays on this Mac. Optional AI arrangement receives detected notes and song context.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var performanceDescription: String {
        switch store.mode {
        case .whistle: "Whistle one clear melody. The detected notes will play on the instrument you choose."
        case .humming: "Hum one clear melody. The detected notes will play on the instrument you choose."
        case .singing: "Sing one melody. Transcribe finds its notes, not the words."
        case .beatboxing: "Beatbox a rhythm. Review the estimated kick, snare and hi-hat hits before adding them."
        }
    }
    private var auditionDescription: String {
        switch store.audition {
        case .accompaniment: "Hear the song while you perform. Use headphones to keep it out of the microphone."
        case .visualOnly: "Follow the moving playhead and active tracks without hearing the song."
        case .solo: "Perform without the song or metronome. The playhead still shows your position."
        }
    }
}

struct TranscriptionInputMeter: View {
    @ObservedObject var session: ProjectSession
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Microphone input").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(inputStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: displayedLevel)
                .progressViewStyle(.linear)
                .accessibilityLabel("Microphone input level")
                .accessibilityValue("\(inputStatus), \(decibels)")
            if session.audio.transcriptionElapsedSeconds >= 2, !session.audio.transcriptionHasInput {
                Label("No microphone audio is reaching the recorder. Check microphone access and the input device in macOS Sound settings.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if session.audio.transcriptionElapsedSeconds >= 2, level < 0.003 {
                Text("Input is connected but quiet. Move closer to the microphone or increase its input level in macOS Sound settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var level: Double {
        let value = session.audio.transcriptionInputLevel
        return value.isFinite ? min(1, max(0, value)) : 0
    }
    private var displayedLevel: Double {
        min(1, max(0, (20 * log10(max(level, 0.000001)) + 60) / 60))
    }
    private var inputStatus: String {
        if !session.audio.transcriptionHasInput { return "Waiting for input" }
        return level >= 0.003 ? "Sound detected" : "Input connected"
    }
    private var decibels: String {
        level > 0 ? "\((20 * log10(level)).formatted(.number.precision(.fractionLength(0)))) dBFS" : "−∞ dBFS"
    }
}
