import SwiftUI

struct TransportControlsView: View {
    @ObservedObject var session: ProjectSession

    private var recordingActive: Bool { session.audio.isRecording || session.audio.isTranscribingCapture }

    var body: some View {
        HStack(spacing: 2) {
            Button { session.stop() } label: {
                Image(systemName: "stop.fill").frame(width: 22, height: 26)
            }
            .help("Stop (⌘.)")
            .accessibilityLabel("Stop")

            Button { session.togglePlayback() } label: {
                Image(systemName: session.audio.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 26)
            }
            .help("Play or pause (Space in the arrangement)")
            .accessibilityLabel(session.audio.isPlaying ? "Pause" : "Play")
            .accessibilityValue(session.audio.isPlaying ? "Playing" : "Stopped")

            Button { session.toggleRecording() } label: {
                Image(systemName: recordingActive ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(recordingActive ? Color.red : Color.primary)
                    .frame(width: 22, height: 26)
            }
            .help(recordingActive ? "Stop recording (⇧⌘R)" : "Record audio (⇧⌘R)")
            .accessibilityLabel(recordingActive ? "Stop recording" : "Record audio")
            .accessibilityValue(recordingActive ? "On" : "Off")

            Button { session.toggleLoop() } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(session.file.song.loopEnabled ? Color.accentColor : Color.primary)
                    .frame(width: 22, height: 26)
            }
            .help("Loop")
            .accessibilityLabel("Loop")
            .accessibilityValue(session.file.song.loopEnabled ? "On" : "Off")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport")
    }
}
