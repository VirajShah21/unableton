import SwiftUI
import UnabletonCore

struct ClipPropertiesView: View {
    @ObservedObject var session: ProjectSession
    let clip: Clip
    var body: some View {
        Form {
            Section("Clip") {
                if session.canEditMusic {
                EditableNumber(label: "Start beat", value: clip.startBeat + 1, range: 1...200_000) { value in
                    session.perform([ProjectCommand(op: .moveClip, clipID: clip.id, startBeat: value - 1)], name: "Move Clip")
                }
                EditableNumber(label: "Length in beats", value: clip.lengthBeats, range: 0.0625...200_000) { value in
                    session.perform([ProjectCommand(op: .trimClip, clipID: clip.id, lengthBeats: value)], name: "Trim Clip")
                }
                HStack {
                    Button("Trim Start to Playhead") {
                        session.perform([ProjectCommand(op: .trimClip, clipID: clip.id, startBeat: session.audio.currentBeat)], name: "Trim Clip")
                    }.disabled(!playheadInside)
                    Button("Split") {
                        session.perform([ProjectCommand(op: .splitClip, clipID: clip.id, startBeat: session.audio.currentBeat)], name: "Split Clip")
                    }.disabled(!playheadInside)
                }
                } else {
                    InspectionValue("Start beat", value: (clip.startBeat + 1).formatted())
                    InspectionValue("Length in beats", value: clip.lengthBeats.formatted())
                }
            }
            Section("Loop") {
                if session.canEditMusic {
                Toggle("Loop enabled", isOn: Binding(get: { session.file.song.loopEnabled }, set: { enabled in
                    setLoop(enabled: enabled)
                }))
                EditableNumber(label: "Start beat", value: session.file.song.loopStart + 1, range: 1...200_000) { value in
                    setLoop(start: value - 1)
                }
                EditableNumber(label: "Length in beats", value: session.file.song.loopEnd - session.file.song.loopStart, range: 0.0625...200_000) { value in
                    setLoop(length: value)
                }
                Button("Set Loop to This Clip") {
                    setLoop(start: clip.startBeat, length: clip.lengthBeats, enabled: true)
                }
                } else {
                    InspectionValue("Loop enabled", value: session.file.song.loopEnabled ? "On" : "Off")
                    InspectionValue("Start beat", value: (session.file.song.loopStart + 1).formatted())
                    InspectionValue("Length in beats", value: (session.file.song.loopEnd - session.file.song.loopStart).formatted())
                }
            }
        }.formStyle(.grouped).padding(4).frame(width: 350, height: 340).textSelection(.enabled)
    }
    private var playheadInside: Bool { session.audio.currentBeat > clip.startBeat && session.audio.currentBeat < clip.startBeat + clip.lengthBeats }
    private func setLoop(start: Double? = nil, length: Double? = nil, enabled: Bool? = nil) {
        guard session.canEditMusic else { return }
        session.perform([ProjectCommand(op: .setLoop, value: (enabled ?? session.file.song.loopEnabled) ? 1 : 0, startBeat: start ?? session.file.song.loopStart, lengthBeats: length ?? (session.file.song.loopEnd - session.file.song.loopStart))], name: "Change Loop")
    }
}
