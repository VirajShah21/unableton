import SwiftUI
import UnabletonCore

struct PianoRollView: View {
    @ObservedObject var session: ProjectSession
    let clip: Clip
    @State private var snap: Double = 0.25
    @State private var noteLength: Double = 1
    @State private var showingClipProperties = false
    @FocusState private var focused: Bool
    private let beatWidth: CGFloat = 45
    private let keyWidth: CGFloat = 44
    private let rowHeight: CGFloat = 15
    private var preset: InstrumentPreset? { session.selectedTrack.flatMap { InstrumentCatalog.preset(id: $0.instrumentID) } }
    private var lowPitch: Int { preset?.isSampler == true ? preset!.minimumPitch : max(0, min(36, (clip.notes.map(\.pitch).min() ?? 40) - 3)) }
    private var highPitch: Int { preset?.isSampler == true ? preset!.maximumPitch : min(127, max(84, (clip.notes.map(\.pitch).max() ?? 80) + 3)) }
    private var initialPitch: Int { min(highPitch, max(lowPitch, session.selectedTrack?.instrumentID.contains("bass") == true ? 40 : 72)) }
    private var defaultPitch: Int { validPitch(session.selectedTrack?.instrumentID.contains("drums") == true || session.selectedTrack?.instrumentID.contains("bass") == true ? 36 : 60) }
    private var height: CGFloat { CGFloat(highPitch - lowPitch + 1) * rowHeight }
    private var width: CGFloat { max(600, CGFloat(clip.lengthBeats) * beatWidth) }
    private var selectedNote: NoteEvent? { clip.notes.first { $0.id == session.selectedNoteID } }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach((lowPitch...highPitch).reversed(), id: \.self) { pitch in
                                Text(TrackColors.noteName(pitch)).font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(width: keyWidth, height: rowHeight)
                                    .background(isBlack(pitch) ? Color.primary.opacity(0.13) : Color.primary.opacity(0.025))
                                    .overlay(alignment: .bottom) { Divider() }.id("pitch-\(pitch)")
                            }
                        }
                        ZStack(alignment: .topLeading) {
                            grid
                            ForEach(clip.notes) { note in noteView(note) }
                        }.frame(width: width, height: height)
                    }
                }
                .onAppear { reader.scrollTo("pitch-\(initialPitch)", anchor: .top) }
                .onChange(of: clip.id) { _, _ in reader.scrollTo("pitch-\(initialPitch)", anchor: .top) }
            }
            if let note = selectedNote { noteProperties(note) }
            else { Text(session.canEditMusic ? "Double-click to add a note. Drag to move; drag its right edge to resize. Arrow keys move a selected note." : "Select a note to inspect its pitch, timing, and velocity.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) { session.togglePlayback(); return .handled }
        .onKeyPress(.delete) {
            guard session.canEditMusic else { return .ignored }
            session.deleteNote(); return .handled
        }
        .onKeyPress(.upArrow) {
            guard session.canEditMusic else { return .ignored }
            shiftNote(pitch: 1); return .handled
        }
        .onKeyPress(.downArrow) {
            guard session.canEditMusic else { return .ignored }
            shiftNote(pitch: -1); return .handled
        }
        .onKeyPress(.leftArrow) {
            guard session.canEditMusic else { return .ignored }
            shiftNote(beat: -snap); return .handled
        }
        .onKeyPress(.rightArrow) {
            guard session.canEditMusic else { return .ignored }
            shiftNote(beat: snap); return .handled
        }
        .onChange(of: session.mode) { _, _ in showingClipProperties = false }
    }
    private var controls: some View {
        HStack {
            if session.canEditMusic {
                Picker("Snap", selection: $snap) { Text("1/4").tag(1.0); Text("1/8").tag(0.5); Text("1/16").tag(0.25); Text("1/32").tag(0.125) }.frame(width: 110)
                Picker("Length", selection: $noteLength) { Text("1/4").tag(1.0); Text("1/8").tag(0.5); Text("1/16").tag(0.25); Text("1 bar").tag(4.0) }.frame(width: 120)
                Button("Add Note") { addNote(beat: 0, pitch: defaultPitch) }
            } else {
                Text("Beat \((clip.startBeat + 1).formatted()) · \(clip.lengthBeats.formatted()) beats")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button(session.canEditMusic ? "Clip…" : "Clip Details…") { showingClipProperties.toggle() }
                .popover(isPresented: $showingClipProperties) { ClipPropertiesView(session: session, clip: clip) }
            Spacer()
            if session.canEditMusic { Menu("Edit") {
                Button("Quantize to Snap") { session.perform([ProjectCommand(op: .quantize, clipID: clip.id, value: snap)], name: "Quantize Notes") }
                Button("Humanize") { session.perform([ProjectCommand(op: .humanize, clipID: clip.id, value: 0.025)], name: "Humanize Notes") }
                Button("Transpose Up an Octave") { session.perform([ProjectCommand(op: .transpose, clipID: clip.id, value: 12)], name: "Transpose") }
                Button("Transpose Down an Octave") { session.perform([ProjectCommand(op: .transpose, clipID: clip.id, value: -12)], name: "Transpose") }
            }.fixedSize() }
            Text("\(clip.notes.count) notes").font(.caption).foregroundStyle(.secondary)
        }.controlSize(.small).padding(.horizontal, 10).frame(height: 35)
    }
    private var grid: some View {
        Canvas { context, size in
            for pitch in lowPitch...highPitch {
                let y = CGFloat(highPitch - pitch) * rowHeight
                if isBlack(pitch) { context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(.primary.opacity(0.045))) }
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.primary.opacity(pitch % 12 == 0 ? 0.16 : 0.05)), lineWidth: 0.5)
            }
            for division in 0...Int(clip.lengthBeats / snap) {
                let x = CGFloat(Double(division) * snap) * beatWidth
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.primary.opacity(division % Int(4 / snap) == 0 ? 0.18 : 0.055)), lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .musicEditing(session.canEditMusic) { view in
            view.gesture(SpatialTapGesture(count: 2).onEnded { tap in
                guard session.canEditMusic else { return }
                addNote(beat: snapBeat(tap.location.x / beatWidth), pitch: highPitch - Int(tap.location.y / rowHeight))
                focused = true
            })
        }
    }
    private func noteView(_ note: NoteEvent) -> some View {
        let selected = session.selectedNoteID == note.id
        return RoundedRectangle(cornerRadius: 3)
            .fill(TrackColors.color(session.selectedTrack?.colorIndex ?? 0).opacity(selected ? 0.95 : 0.65))
            .overlay { if selected { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.8), lineWidth: 1) } }
            .overlay(alignment: .trailing) {
                if session.canEditMusic { Rectangle().fill(.primary.opacity(0.25)).frame(width: 5)
                    .gesture(DragGesture(minimumDistance: 2).onEnded { drag in
                        var changed = note; changed.duration = max(snap, snapBeat(note.duration + drag.translation.width / beatWidth)); update(changed)
                    }) }
            }
            .frame(width: max(7, CGFloat(note.duration) * beatWidth - 1), height: rowHeight - 2)
            .offset(x: CGFloat(note.startBeat) * beatWidth, y: CGFloat(highPitch - note.pitch) * rowHeight + 1)
            .onTapGesture { session.selectedNoteID = note.id; focused = true }
            .musicEditing(session.canEditMusic) { view in
                view.gesture(DragGesture(minimumDistance: 4).onEnded { drag in
                guard session.canEditMusic else { return }
                var changed = note
                changed.startBeat = min(max(0, clip.lengthBeats - snap), max(0, snapBeat(note.startBeat + drag.translation.width / beatWidth)))
                changed.pitch = validPitch(note.pitch - Int((drag.translation.height / rowHeight).rounded()))
                update(changed); session.selectedNoteID = note.id
            })
                .contextMenu { Button("Delete Note", role: .destructive) { session.perform([ProjectCommand(op: .deleteNote, clipID: clip.id, noteID: note.id)], name: "Delete Note") } }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(TrackColors.noteName(note.pitch)), beat \(note.startBeat.formatted()), length \(note.duration.formatted()), velocity \(note.velocity)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.selectedNoteID = note.id; focused = true }
    }
    private func noteProperties(_ note: NoteEvent) -> some View {
        HStack(spacing: 16) {
            Text(TrackColors.noteName(note.pitch)).font(.caption).fontWeight(.medium)
            if session.canEditMusic {
                Stepper("Pitch \(note.pitch)", value: Binding(get: { note.pitch }, set: { var changed = note; changed.pitch = validPitch($0); update(changed) }), in: lowPitch...highPitch).fixedSize()
                Stepper("Velocity \(note.velocity)", value: Binding(get: { note.velocity }, set: { var changed = note; changed.velocity = $0; update(changed) }), in: 1...127).fixedSize()
            } else {
                Text("Pitch \(note.pitch)")
                Text("Start \(note.startBeat.formatted())")
                Text("Length \(note.duration.formatted())")
                Text("Velocity \(note.velocity)")
            }
            Spacer()
            if session.canEditMusic { Button("Delete Note") { session.deleteNote() } }
        }.font(.caption).controlSize(.small).padding(8).textSelection(.enabled)
    }
    private func addNote(beat: Double, pitch: Int) {
        guard session.canEditMusic, beat >= 0, beat < clip.lengthBeats else { return }
        guard isSupported(pitch) else { session.notice = "This instrument has no sample for \(TrackColors.noteName(pitch))."; return }
        let note = NoteEvent(pitch: pitch, startBeat: beat, duration: min(noteLength, clip.lengthBeats - beat))
        session.perform([ProjectCommand(op: .addNote, clipID: clip.id, note: note)], name: "Add Note")
        session.selectedNoteID = note.id
    }
    private func update(_ note: NoteEvent) {
        guard session.canEditMusic else { return }
        session.perform([ProjectCommand(op: .updateNote, clipID: clip.id, noteID: note.id, note: note)], name: "Edit Note")
    }
    private func shiftNote(beat: Double = 0, pitch: Int = 0) {
        guard session.canEditMusic, var note = selectedNote else { return }
        note.startBeat = min(max(0, clip.lengthBeats - snap), max(0, note.startBeat + beat)); note.pitch = validPitch(note.pitch + pitch); update(note)
    }
    private func isSupported(_ pitch: Int) -> Bool {
        guard pitch >= lowPitch, pitch <= highPitch else { return false }
        return preset?.supportedPitches?.contains(pitch) ?? true
    }
    private func validPitch(_ pitch: Int) -> Int {
        let clamped = min(highPitch, max(lowPitch, pitch))
        return preset?.supportedPitches?.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
    }
    private func snapBeat(_ beat: Double) -> Double { (beat / snap).rounded() * snap }
    private func isBlack(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }
}
