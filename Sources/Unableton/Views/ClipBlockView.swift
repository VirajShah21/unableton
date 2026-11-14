import SwiftUI
import UnabletonCore

struct ClipBlockView: View {
    @ObservedObject var session: ProjectSession
    let track: Track
    let clip: Clip
    private var selected: Bool { session.selection.clipID == clip.id }
    var body: some View {
        Group {
            if session.canEditMusic {
                clipContents
                    .contextMenu {
                        Button("Edit Clip") { session.select(track: track.id, clip: clip.id) }
                        Button("Duplicate") { edit(.init(op: .duplicateClip, clipID: clip.id), name: "Duplicate Clip") }
                        Button("Split at Playhead") { edit(.init(op: .splitClip, clipID: clip.id, startBeat: session.audio.currentBeat), name: "Split Clip") }
                        Button("Move Earlier One Beat") { edit(.init(op: .moveClip, clipID: clip.id, startBeat: max(0, clip.startBeat - 1)), name: "Move Clip") }
                        Button("Move Later One Beat") { edit(.init(op: .moveClip, clipID: clip.id, startBeat: clip.startBeat + 1), name: "Move Clip") }
                        Divider()
                        Button("Delete", role: .destructive) { edit(.init(op: .deleteClip, clipID: clip.id), name: "Delete Clip") }
                    }
            } else {
                clipContents
                    .contextMenu {
                        Button("Inspect Clip") { session.select(track: track.id, clip: clip.id) }
                    }
            }
        }
        .onTapGesture { session.select(track: track.id, clip: clip.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.name): \(clip.name), \(clip.kind == .notes ? "notes" : "audio"), beat \(Int(clip.startBeat + 1)), \(clip.lengthBeats.formatted()) beats")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityAction { session.select(track: track.id, clip: clip.id) }
    }
    private var clipContents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(clip.name).font(.caption).fontWeight(.medium).lineLimit(1).padding(.horizontal, 6).padding(.top, 4)
            Canvas { context, size in
                if clip.kind == .notes {
                    let pitches = clip.notes.map(\.pitch)
                    let minimum = (pitches.min() ?? 48) - 2; let maximum = (pitches.max() ?? 72) + 2
                    for note in clip.notes {
                        let x = note.startBeat / clip.lengthBeats * size.width
                        let y = (1 - Double(note.pitch - minimum) / Double(max(1, maximum - minimum))) * max(1, size.height - 4)
                        let rect = CGRect(x: x, y: y, width: max(2, note.duration / clip.lengthBeats * size.width), height: 3)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.primary.opacity(0.65)))
                    }
                } else if let id = clip.assetID, let peaks = session.waveforms[id], !peaks.isEmpty {
                    var waveform = Path()
                    for (index, peak) in peaks.enumerated() {
                        let x = Double(index) / Double(peaks.count) * size.width
                        let magnitude = Double(peak) * size.height * 0.45
                        waveform.move(to: CGPoint(x: x, y: size.height / 2 - magnitude)); waveform.addLine(to: CGPoint(x: x, y: size.height / 2 + magnitude))
                    }
                    context.stroke(waveform, with: .color(.primary.opacity(0.7)), lineWidth: 1)
                } else {
                    var line = Path(); line.move(to: CGPoint(x: 0, y: size.height / 2)); line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(line, with: .color(.primary.opacity(0.5)), lineWidth: 1)
                }
            }.padding(.horizontal, 4).padding(.bottom, 4)
        }
        .background(TrackColors.color(track.colorIndex).opacity(selected ? 0.52 : 0.28), in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : TrackColors.color(track.colorIndex).opacity(0.5), lineWidth: selected ? 2 : 0.7) }
        .contentShape(Rectangle())
    }
    private func edit(_ command: ProjectCommand, name: String) {
        guard session.canEditMusic else { return }
        session.perform([command], name: name)
    }
}
