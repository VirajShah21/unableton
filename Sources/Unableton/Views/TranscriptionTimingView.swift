import SwiftUI
import UnabletonCore

struct TranscriptionTimingView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var store: TranscriptionSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Timing", selection: $store.options.timing) {
                    ForEach(TranscriptionTiming.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                if store.options.timing == .autoTime {
                    Picker("Adjustment", selection: $store.options.adjustment) {
                        ForEach(TranscriptionAdjustment.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text(store.options.adjustment == .minor ? "AI can move each onset and note length by up to a sixteenth note. Pitches and note count stay fixed." : "AI can reshape the rhythm to fit your chosen length and surrounding music. Pitches, note count, and event order stay fixed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Keep the detected onsets, note lengths, and rests. No snapping or additional notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.effectiveOptions.requiresAI {
                    EditableNumber(label: "Section length (beats)", value: store.options.targetLengthBeats, range: 0.0625...4096) { store.options.targetLengthBeats = $0 }
                        .textFieldStyle(.roundedBorder)
                    Text("Used for accompaniment and major timing adjustments. Uses the model selected in Settings.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Insert where recording started", isOn: $store.insertAtRecordedPosition)
                if store.insertAtRecordedPosition {
                    Text("Start: \(TrackColors.position(store.take?.startBeat ?? 0, beatsPerBar: session.file.song.beatsPerBar))").font(.caption).foregroundStyle(.secondary)
                } else {
                    EditableNumber(label: "Insert at beat", value: store.options.insertionBeat + 1, range: 1...200_000) { store.options.insertionBeat = $0 - 1 }
                        .textFieldStyle(.roundedBorder)
                    Button("Use Current Playhead") { store.options.insertionBeat = session.audio.currentBeat }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).disabled(store.isWorking || store.isCapturing)
        }
    }
}
