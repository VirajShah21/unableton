import SwiftUI
import UnabletonCore

struct TrackHeaderView: View {
    @ObservedObject var session: ProjectSession
    let track: Track
    @State private var renaming = false
    @State private var name = ""
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var selected: Bool { session.selection.trackID == track.id }
    private var color: Color { TrackColors.color(track.colorIndex) }
    var body: some View {
        Group {
            if session.canEditMusic {
                headerContents
                    .draggable("track:\(track.id)")
                    .dropDestination(for: String.self) { items, _ in
                        guard session.canEditMusic, let first = items.first, first.hasPrefix("track:"), let id = UUID(uuidString: String(first.dropFirst(6))), let index = session.file.song.tracks.firstIndex(where: { $0.id == track.id }) else { return false }
                        session.perform([ProjectCommand(op: .reorderTrack, trackID: id, index: index)], name: "Reorder Track")
                        return true
                    }
                    .contextMenu {
                        Button("Rename…") { guard session.canEditMusic else { return }; name = track.name; renaming = true }
                        Button("Duplicate") { edit(.init(op: .duplicateTrack, trackID: track.id), name: "Duplicate Track") }
                        Button("Move Up") { move(-1) }
                        Button("Move Down") { move(1) }
                        if track.kind == .instrument { Button("Add Note Clip") { session.addNoteClip(trackID: track.id) } }
                        Divider()
                        Button("Delete Track", role: .destructive) { edit(.init(op: .deleteTrack, trackID: track.id), name: "Delete Track") }
                    }
            } else {
                headerContents
                    .contextMenu {
                        Button("Inspect Track") { session.select(track: track.id); session.editorVisible = true; session.editorTab = "Instrument" }
                    }
            }
        }
        .onTapGesture { session.select(track: track.id) }
        .alert("Rename Track", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { edit(.init(op: .renameTrack, trackID: track.id, text: name), name: "Rename Track") }
        }
        .onChange(of: session.mode) { _, _ in renaming = false; name = "" }
        .accessibilityElement(children: .contain).accessibilityLabel("Track \(track.name)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction { session.select(track: track.id) }
    }
    private var instrumentName: String {
        track.kind == .audio ? "Audio" : InstrumentCatalog.preset(id: track.instrumentID)?.name ?? "Instrument"
    }
    private var symbol: String {
        guard track.kind == .instrument else { return "waveform" }
        let preset = InstrumentCatalog.preset(id: track.instrumentID)
        return preset?.category == "Drums" ? "square.grid.2x2.fill" : preset?.symbol ?? "pianokeys"
    }
    private var pan: String {
        if abs(track.pan) < 0.005 { return "Center" }
        return "\(track.pan < 0 ? "L" : "R") \(Int((abs(track.pan) * 100).rounded()))%"
    }
    private var headerContents: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color.mix(with: .primary, by: 0.35))
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.14), in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name).font(.callout).fontWeight(.semibold).lineLimit(1).help(track.name)
                    Text(instrumentName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(instrumentName)
                }
                Spacer(minLength: 0)
                if session.hasActiveClip(track) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .help("Clip active at playhead").accessibilityLabel("Clip active at playhead")
                }
            }
            if session.canEditMusic {
                HStack(spacing: 5) {
                    flag("M", active: track.isMuted, label: "Mute") { session.setTrackFlag(.setMute, track: track, enabled: !track.isMuted) }
                    flag("S", active: track.isSolo, label: "Solo") { session.setTrackFlag(.setSolo, track: track, enabled: !track.isSolo) }
                    if track.kind == .audio {
                        flag("R", active: track.isArmed, label: "Arm recording") { session.setTrackFlag(.setArmed, track: track, enabled: !track.isArmed) }
                    }
                    Spacer(minLength: 1)
                }
            } else {
                mixSummary
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovered ? 0.045 : 0))
        }
        .overlay {
            if selected, contrast == .increased {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .padding(.horizontal, 4).padding(.vertical, 3)
    }
    private var mixSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if track.isMuted || track.isSolo || (track.kind == .audio && track.isArmed) {
                HStack(spacing: 6) {
                    if track.isMuted { Text("Muted") }
                    if track.isSolo { Text("Solo") }
                    if track.kind == .audio, track.isArmed { Text("Armed") }
                }
            }
            Text("\(Int((track.volume * 100).rounded()))% · \(pan)")
        }
        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume \(Int((track.volume * 100).rounded())) percent, pan \(pan). Mute \(track.isMuted ? "on" : "off"), solo \(track.isSolo ? "on" : "off")\(track.kind == .audio ? ", recording arm \(track.isArmed ? "on" : "off")" : "").")
        .help("Volume \(Int((track.volume * 100).rounded()))% · Pan \(pan)")
    }
    private func flag(_ text: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button { if session.canEditMusic { action() } } label: { Text(text).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 16) }
            .buttonStyle(.bordered).controlSize(.mini).tint(active ? .accentColor : nil)
            .accessibilityLabel("\(label) \(track.name)").accessibilityValue(active ? "On" : "Off")
            .help(label)
    }
    private func move(_ offset: Int) {
        guard session.canEditMusic, let index = session.file.song.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        session.perform([ProjectCommand(op: .reorderTrack, trackID: track.id, index: index + offset)], name: "Reorder Track")
    }
    private func edit(_ command: ProjectCommand, name: String) {
        guard session.canEditMusic else { return }
        session.perform([command], name: name)
    }
}
