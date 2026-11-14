import Foundation

public enum CommandOperation: String, Codable, CaseIterable, Sendable {
    case addTrack, deleteTrack, duplicateTrack, reorderTrack, renameTrack, setInstrument, setParameter, setMute, setSolo, setArmed
    case addClip, deleteClip, duplicateClip, moveClip, trimClip, splitClip, replaceNotes, addNote, updateNote, deleteNote, transpose, quantize, humanize, repeatClip
    case addAsset, setTempo, setLength, setKey, setLoop, setMetronome
}
/// Shared by manual edits and the model. UUIDs are stable across persisted projects and tool calls.
public struct ProjectCommand: Codable, Sendable, Equatable {
    public var op: CommandOperation
    public var trackID: UUID?
    public var clipID: UUID?
    public var noteID: UUID?
    public var targetTrackID: UUID?
    public var track: Track?
    public var clip: Clip?
    public var note: NoteEvent?
    public var notes: [NoteEvent]?
    public var value: Double?
    public var text: String?
    public var index: Int?
    public var startBeat: Double?
    public var lengthBeats: Double?
    public var asset: AudioAsset?
    public init(op: CommandOperation, trackID: UUID? = nil, clipID: UUID? = nil, noteID: UUID? = nil, targetTrackID: UUID? = nil, track: Track? = nil, clip: Clip? = nil, note: NoteEvent? = nil, notes: [NoteEvent]? = nil, value: Double? = nil, text: String? = nil, index: Int? = nil, startBeat: Double? = nil, lengthBeats: Double? = nil, asset: AudioAsset? = nil) {
        self.op = op; self.trackID = trackID; self.clipID = clipID; self.noteID = noteID; self.targetTrackID = targetTrackID
        self.track = track; self.clip = clip; self.note = note; self.notes = notes; self.value = value; self.text = text; self.index = index
        self.startBeat = startBeat; self.lengthBeats = lengthBeats; self.asset = asset
    }
}

public struct ProjectError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ProjectEditor {
    public static func apply(_ commands: [ProjectCommand], to song: inout Song) throws {
        guard commands.count <= 128 else { throw ProjectError("An edit batch may contain at most 128 operations.") }
        var draft = song
        for command in commands { try execute(command, song: &draft) }
        try validate(draft)
        if !commands.isEmpty { draft.revision = song.revision + 1 }
        song = draft
    }
    public static func validate(_ song: Song) throws {
        guard song.tempo.isFinite, (30...300).contains(song.tempo), (1...12).contains(song.beatsPerBar), (1...4096).contains(song.lengthBars) else { throw ProjectError("Tempo must be 30–300 BPM and the song length must be 1–4096 bars.") }
        guard song.tracks.count <= 64, song.loopStart.isFinite, song.loopEnd.isFinite, song.loopStart >= 0, song.loopEnd > song.loopStart else { throw ProjectError("Invalid track count or loop range.") }
        var ids = Set<UUID>()
        for asset in song.assets {
            guard ids.insert(asset.id).inserted, asset.duration.isFinite, asset.duration >= 0, asset.sampleRate.isFinite, asset.sampleRate > 0, (1...32).contains(asset.channels), asset.fileName == (asset.fileName as NSString).lastPathComponent, !asset.fileName.isEmpty, asset.fileName != ".", asset.fileName != ".." else { throw ProjectError("Invalid audio asset.") }
            if let take = asset.vocalTake {
                guard !take.provider.isEmpty, take.provider.utf8.count <= 100, !take.singerID.isEmpty, take.singerID.utf8.count <= 512,
                      take.generatedAt.timeIntervalSinceReferenceDate.isFinite else { throw ProjectError("Invalid vocal take metadata.") }
                try take.score.validate()
            }
            if let take = asset.transcriptionTake {
                guard take.recordedTempo.isFinite, (30...300).contains(take.recordedTempo),
                      take.recordedStartBeat.isFinite, take.recordedStartBeat >= 0,
                      take.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw ProjectError("Invalid transcription take metadata.") }
                _ = try take.transcript.notes(tempo: take.recordedTempo)
            }
        }
        for track in song.tracks {
            guard ids.insert(track.id).inserted, track.volume.isFinite, (0...1.5).contains(track.volume), track.pan.isFinite, (-1...1).contains(track.pan), track.clips.count <= 4096 else { throw ProjectError("Invalid track or mixer value.") }
            if track.kind == .instrument, InstrumentCatalog.preset(id: track.instrumentID) == nil { throw ProjectError("Unknown instrument: \(track.instrumentID)") }
            for (key, value) in track.parameters {
                guard let descriptor = InstrumentCatalog.parameters(for: track.instrumentID).first(where: { $0.id == key }), value.isFinite, descriptor.range.contains(value) else { throw ProjectError("Unsupported parameter or out-of-range value: \(key)") }
            }
            for clip in track.clips {
                guard ids.insert(clip.id).inserted, clip.startBeat.isFinite, clip.startBeat >= 0, clip.lengthBeats.isFinite, clip.lengthBeats > 0, clip.startBeat + clip.lengthBeats <= 200_000, clip.sourceOffsetSeconds.isFinite, clip.sourceOffsetSeconds >= 0, clip.notes.count <= 65_536 else { throw ProjectError("Invalid clip timing or duplicate identifier.") }
                guard (track.kind == .instrument && clip.kind == .notes) || (track.kind == .audio && clip.kind == .audio) else { throw ProjectError("Audio and note clips need matching track types.") }
                if clip.kind == .audio {
                    guard let id = clip.assetID, let asset = song.assets.first(where: { $0.id == id }), clip.sourceOffsetSeconds < asset.duration else { throw ProjectError("The audio clip references a missing or empty asset.") }
                }
                if let source = clip.transcriptionAssetID {
                    guard song.assets.contains(where: { $0.id == source && $0.transcriptionTake != nil }) else { throw ProjectError("The transcribed clip references a missing source take.") }
                }
                for note in clip.notes {
                    guard ids.insert(note.id).inserted, (0...127).contains(note.pitch), (1...127).contains(note.velocity), note.startBeat.isFinite, note.startBeat >= 0, note.startBeat < clip.lengthBeats, note.duration.isFinite, note.duration > 0, note.duration <= 16_384 else { throw ProjectError("Invalid note pitch, velocity, duration, or identifier.") }
                    if let preset = InstrumentCatalog.preset(id: track.instrumentID) {
                        guard (preset.minimumPitch...preset.maximumPitch).contains(note.pitch), preset.supportedPitches?.contains(note.pitch) != false else { throw ProjectError("\(preset.name) does not support MIDI note \(note.pitch). Use its advertised playable pitch range \(preset.minimumPitch)–\(preset.maximumPitch) or select another instrument.") }
                    }
                }
            }
        }
    }
    private static func execute(_ c: ProjectCommand, song: inout Song) throws {
        func required<T>(_ value: T?, _ name: String) throws -> T { guard let value else { throw ProjectError("Missing \(name) for \(c.op.rawValue).") }; return value }
        func trackIndex() throws -> Int { guard let index = song.tracks.firstIndex(where: { $0.id == c.trackID }) else { throw ProjectError("Track not found.") }; return index }
        func location() throws -> (Int, Int) {
            for ti in song.tracks.indices where c.trackID == nil || song.tracks[ti].id == c.trackID {
                if let ci = song.tracks[ti].clips.firstIndex(where: { $0.id == c.clipID }) { return (ti, ci) }
            }
            throw ProjectError("Clip not found.")
        }
        switch c.op {
        case .addAsset:
            let asset = try required(c.asset, "asset")
            guard !song.assets.contains(where: { $0.id == asset.id }) else { throw ProjectError("Audio asset already exists.") }
            song.assets.append(asset)
        case .addTrack:
            let t = try required(c.track, "track")
            song.tracks.insert(t, at: min(max(c.index ?? song.tracks.count, 0), song.tracks.count))
        case .deleteTrack: song.tracks.remove(at: try trackIndex())
        case .duplicateTrack:
            let i = try trackIndex(); var t = song.tracks[i]; t.id = UUID(); t.name += " copy"; t.isArmed = false
            t.clips = t.clips.map { copyClip($0) }; song.tracks.insert(t, at: i + 1)
        case .reorderTrack:
            let t = song.tracks.remove(at: try trackIndex()); song.tracks.insert(t, at: min(max(c.index ?? 0, 0), song.tracks.count))
        case .renameTrack: song.tracks[try trackIndex()].name = try required(c.text, "text")
        case .setInstrument:
            let i = try trackIndex(); guard song.tracks[i].kind == .instrument else { throw ProjectError("Audio tracks do not load instruments.") }
            song.tracks[i].instrumentID = try required(c.text, "text"); song.tracks[i].parameters = [:]
        case .setParameter:
            let i = try trackIndex(), key = try required(c.text, "text"), value = try required(c.value, "value")
            if key == "volume" { song.tracks[i].volume = value }
            else if key == "pan" { song.tracks[i].pan = value }
            else { song.tracks[i].parameters[key] = value }
        case .setMute: song.tracks[try trackIndex()].isMuted = (c.value ?? 0) != 0
        case .setSolo: song.tracks[try trackIndex()].isSolo = (c.value ?? 0) != 0
        case .setArmed:
            let i = try trackIndex(); guard song.tracks[i].kind == .audio else { throw ProjectError("Arm an audio track to record.") }
            song.tracks[i].isArmed = (c.value ?? 0) != 0
        case .addClip:
            let i = try trackIndex(); if let asset = c.asset, !song.assets.contains(where: { $0.id == asset.id }) { song.assets.append(asset) }
            song.tracks[i].clips.append(try required(c.clip, "clip"))
        case .deleteClip:
            let (ti, ci) = try location(); song.tracks[ti].clips.remove(at: ci)
        case .duplicateClip, .repeatClip:
            let (ti, ci) = try location(), original = song.tracks[ti].clips[ci]
            let count = c.op == .repeatClip ? max(1, min(c.index ?? 1, 128)) : 1
            for n in 1...count { var clip = copyClip(original); clip.startBeat = (c.startBeat ?? original.startBeat + original.lengthBeats) + Double(n - 1) * original.lengthBeats; song.tracks[ti].clips.append(clip) }
        case .moveClip:
            let (ti, ci) = try location(); var clip = song.tracks[ti].clips.remove(at: ci)
            clip.startBeat = try required(c.startBeat, "startBeat")
            let target = c.targetTrackID ?? song.tracks[ti].id
            guard let dst = song.tracks.firstIndex(where: { $0.id == target }) else { throw ProjectError("Destination track not found.") }
            song.tracks[dst].clips.append(clip)
        case .trimClip:
            let (ti, ci) = try location(); var clip = song.tracks[ti].clips[ci]
            if let start = c.startBeat {
                let delta = start - clip.startBeat
                if clip.kind == .audio { clip.sourceOffsetSeconds += delta * 60 / song.tempo }
                else { clip.notes = clip.notes.compactMap { n in var n = n; n.startBeat -= delta; if n.startBeat + n.duration <= 0 { return nil }; if n.startBeat < 0 { n.duration += n.startBeat; n.startBeat = 0 }; return n } }
                clip.startBeat = start; clip.lengthBeats -= delta
            }
            if let length = c.lengthBeats { clip.lengthBeats = length }
            clip.notes.removeAll { $0.startBeat >= clip.lengthBeats }; song.tracks[ti].clips[ci] = clip
        case .splitClip:
            let (ti, ci) = try location(), original = song.tracks[ti].clips[ci]
            let cut = try required(c.startBeat, "startBeat") - original.startBeat
            guard cut > 0, cut < original.lengthBeats else { throw ProjectError("Split inside the clip.") }
            var left = original, right = copyClip(original)
            left.lengthBeats = cut; right.startBeat += cut; right.lengthBeats -= cut
            left.notes = original.notes.compactMap { n in guard n.startBeat < cut else { return nil }; var n = n; n.duration = min(n.duration, cut - n.startBeat); return n }
            right.notes = original.notes.compactMap { n in guard n.startBeat + n.duration > cut else { return nil }; var n = n; n.id = UUID(); let end = n.startBeat + n.duration; n.startBeat = max(0, n.startBeat - cut); n.duration = end - cut - n.startBeat; return n }
            if original.kind == .audio { right.sourceOffsetSeconds += cut * 60 / song.tempo }
            song.tracks[ti].clips[ci] = left; song.tracks[ti].clips.insert(right, at: ci + 1)
        case .replaceNotes:
            let (ti, ci) = try location(); song.tracks[ti].clips[ci].notes = try required(c.notes, "notes")
        case .addNote:
            let (ti, ci) = try location(); song.tracks[ti].clips[ci].notes.append(try required(c.note, "note"))
        case .updateNote:
            let (ti, ci) = try location(); guard let ni = song.tracks[ti].clips[ci].notes.firstIndex(where: { $0.id == c.noteID }) else { throw ProjectError("Note not found.") }
            var n = try required(c.note, "note"); n.id = song.tracks[ti].clips[ci].notes[ni].id; song.tracks[ti].clips[ci].notes[ni] = n
        case .deleteNote:
            let (ti, ci) = try location(); guard song.tracks[ti].clips[ci].notes.contains(where: { $0.id == c.noteID }) else { throw ProjectError("Note not found.") }; song.tracks[ti].clips[ci].notes.removeAll { $0.id == c.noteID }
        case .transpose, .quantize, .humanize:
            let (ti, ci) = try location(), amount = c.value ?? (c.op == .quantize ? 0.25 : 0)
            guard amount.isFinite else { throw ProjectError("Invalid amount.") }
            var clip = song.tracks[ti].clips[ci]
            if c.op == .transpose {
                guard (-127...127).contains(amount) else { throw ProjectError("Transpose by at most 127 semitones.") }
                for i in clip.notes.indices { clip.notes[i].pitch += Int(amount.rounded()) }
            } else if c.op == .quantize {
                guard (0.015625...16).contains(amount) else { throw ProjectError("Invalid quantize grid.") }
                for i in clip.notes.indices { clip.notes[i].startBeat = min(max(0, (clip.notes[i].startBeat / amount).rounded() * amount), max(0, clip.lengthBeats - amount)); clip.notes[i].duration = max(amount, (clip.notes[i].duration / amount).rounded() * amount) }
            } else {
                guard (0...0.25).contains(amount) else { throw ProjectError("Humanize timing by 0–0.25 beats.") }
                // Stable per-note jitter makes undo, repeated runs, and previews reproducible.
                for i in clip.notes.indices {
                    let byte = clip.notes[i].id.uuid.0
                    let jitter = (Double(byte) / 255 - 0.5) * amount * 2
                    clip.notes[i].startBeat = min(max(0, clip.notes[i].startBeat + jitter), max(0, clip.lengthBeats - 0.001))
                    clip.notes[i].velocity = min(127, max(1, clip.notes[i].velocity + Int(jitter * 40)))
                }
            }
            song.tracks[ti].clips[ci] = clip
        case .setTempo: song.tempo = try required(c.value, "value")
        case .setLength: song.lengthBars = try required(c.index, "index")
        case .setKey: song.key = try required(c.text, "text")
        case .setLoop:
            if let start = c.startBeat { song.loopStart = start }; if let length = c.lengthBeats { song.loopEnd = song.loopStart + length }; song.loopEnabled = (c.value ?? 1) != 0
        case .setMetronome: song.metronomeEnabled = (c.value ?? 0) != 0
        }
    }
    private static func copyClip(_ original: Clip) -> Clip {
        var c = original; c.id = UUID(); c.notes = c.notes.map { n in var n = n; n.id = UUID(); return n }; return c
    }
}
