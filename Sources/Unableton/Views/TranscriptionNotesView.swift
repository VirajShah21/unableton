import SwiftUI
import UnabletonCore

struct TranscriptionNotesView: View {
    @ObservedObject var store: TranscriptionSession
    let canEditMusic: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let transcript = store.transcript {
                ForEach(transcript.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Pitch / drum").frame(width: 125, alignment: .leading)
                            Text("Start (s)").frame(width: 75)
                            Text("Length (s)").frame(width: 75)
                            Text("Confidence").frame(width: 70)
                        }.font(.caption).foregroundStyle(.secondary)
                        ForEach(transcript.events) { event in
                            HStack {
                                if !canEditMusic {
                                    Text(transcript.mode == .beatboxing ? drumName(event.pitch) : TrackColors.noteName(event.pitch))
                                        .frame(width: 125, alignment: .leading)
                                    Text(event.startSeconds.formatted(.number.precision(.fractionLength(0...3)))).frame(width: 75)
                                    Text(event.durationSeconds.formatted(.number.precision(.fractionLength(0...3)))).frame(width: 75)
                                } else {
                                if transcript.mode == .beatboxing {
                                    Picker("Drum", selection: Binding(get: { event.pitch }, set: { store.updateEvent(event.id, pitch: $0) })) {
                                        Text("Kick").tag(36); Text("Snare").tag(38); Text("Closed hi-hat").tag(42)
                                        Text("Open hi-hat").tag(46); Text("Tom").tag(45); Text("Crash").tag(49)
                                    }.labelsHidden().frame(width: 125)
                                } else {
                                    Stepper(TrackColors.noteName(event.pitch), value: Binding(get: { event.pitch }, set: { store.updateEvent(event.id, pitch: $0) }), in: 0...127)
                                        .frame(width: 125).accessibilityLabel("Detected note \(TrackColors.noteName(event.pitch))")
                                }
                                EditableNumber(label: "Start seconds", value: event.startSeconds, range: 0...transcript.duration) { store.updateEvent(event.id, start: $0) }
                                    .frame(width: 75).textFieldStyle(.roundedBorder)
                                EditableNumber(label: "Duration seconds", value: event.durationSeconds, range: 0.001...transcript.duration) { store.updateEvent(event.id, duration: $0) }
                                    .frame(width: 75).textFieldStyle(.roundedBorder)
                                }
                                Text(event.confidence.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption).foregroundStyle(event.confidence < 0.65 ? .orange : .secondary).frame(width: 70)
                            }
                        }
                    }.padding(.bottom, 6)
                }
                Text(canEditMusic ? "Detected MIDI pitches and timing are estimates. Review them here or edit notes in the piano roll after insertion." : "Detected MIDI pitches and timing are estimates. Inspect them here; use Producer to correct individual events.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.textSelection(.enabled)
            .disabled(canEditMusic && (store.isWorking || store.isCapturing))
    }
    private func drumName(_ pitch: Int) -> String {
        switch pitch {
        case 36: "Kick"
        case 38: "Snare"
        case 42: "Closed hi-hat"
        case 46: "Open hi-hat"
        case 45: "Tom"
        case 49: "Crash"
        default: TrackColors.noteName(pitch)
        }
    }
}
