import Foundation
import UnabletonCore
import UnabletonAudio
import UnabletonAI

extension SongReferenceRuntime {
    func placement(_ arguments: JSONValue, attachment: SongAttachment, song: Song, kind: TrackKind) throws -> (Double, Double, Double, String, UUID?) {
        let start = try number(arguments, "source_start_seconds", range: 0...attachment.duration)
        let end = try number(arguments, "source_end_seconds", range: 0...attachment.duration)
        let beat = try number(arguments, "start_beat", range: 0...200_000)
        guard end > start, let name = arguments["track_name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 120 else { throw AgentError.invalidTool("Choose a nonempty source range and a short track name.") }
        var target: UUID?
        if let value = arguments["target_track_id"]?.stringValue {
            guard let id = UUID(uuidString: value), song.track(id)?.kind == kind else { throw AgentError.invalidTool("Choose an existing compatible target track, or null for a new track.") }
            target = id
        } else if song.tracks.count >= 64 { throw AgentError.invalidTool("The song already has 64 tracks. Choose an existing target track or remove a track first.") }
        return (start, end, beat, name, target)
    }
    func insertNotes(_ attachment: SongAttachment, source: URL, arguments: JSONValue, song: Song) async throws -> ReferenceToolResult {
        let (start, end, beat, name, existingTarget) = try placement(arguments, attachment: attachment, song: song, kind: .instrument)
        guard let instrument = arguments["instrument_id"]?.stringValue, let preset = InstrumentCatalog.preset(id: instrument),
              let partID = arguments["part_id"]?.stringValue else { throw AgentError.invalidTool("Choose a catalog instrument_id and returned MIDI part_id.") }
        let score: MIDIImport
        if let saved = scores[attachment.id] { score = saved }
        else { score = try await midi(attachment, source: source) }
        guard let part = score.parts.first(where: { $0.id == partID }) else { throw AgentError.invalidTool("The MIDI part_id is not in this attachment.") }
        guard let stem = part.referenceStem, ["bass", "other"].contains(stem) || (stem == "vocals" && allowsVocalNoteConversion) else {
            throw AgentError.invalidTool("Vocals stay as audio by default. To convert a vocal melody, explicitly request: \(ReferenceVocalNotesPolicy.requestExample)")
        }
        let measured = part.notes.filter { $0.startSeconds < end && $0.startSeconds + $0.durationSeconds > start }
        guard !measured.isEmpty else { throw AgentError.invalidTool("That source range contains no measured notes in this part.") }
        guard measured.allSatisfy({ (preset.minimumPitch...preset.maximumPitch).contains($0.pitch) && preset.supportedPitches?.contains($0.pitch) != false && preset.unrenderablePitches?.contains($0.pitch) != true }) else {
            throw AgentError.invalidTool("The chosen sound cannot play every extracted pitch. Choose a compatible catalog sound; notes were not transposed or omitted.")
        }
        if let target = existingTarget, song.track(target)?.instrumentID != instrument { throw AgentError.invalidTool("The target track uses another instrument. Choose its actual instrument_id, a new track, or explicitly change it first.") }
        var commands: [ProjectCommand] = []
        let target: UUID
        if let existingTarget { target = existingTarget }
        else {
            let track = Track(name: name, instrumentID: instrument, colorIndex: song.tracks.count)
            target = track.id; commands.append(ProjectCommand(op: .addTrack, track: track))
        }
        let notes = measured.map { event -> NoteEvent in
            let eventStart = max(start, event.startSeconds), eventEnd = min(end, event.startSeconds + event.durationSeconds)
            return NoteEvent(pitch: event.pitch, startBeat: (eventStart - start) * song.tempo / 60,
                             duration: (eventEnd - eventStart) * song.tempo / 60, velocity: event.velocity)
        }
        var clip = Clip(name: name, startBeat: beat, lengthBeats: (end - start) * song.tempo / 60, notes: notes)
        clip.referenceAttachmentID = attachment.id
        commands.append(ProjectCommand(op: .addClip, trackID: target, clip: clip))
        return ReferenceToolResult(output: .object(["ok": .bool(true), "track_id": .string(target.uuidString), "clip_id": .string(clip.id.uuidString),
            "notes_inserted": .number(Double(notes.count)), "note": .string("Measured MIDI inserted as editable notes. Local transcription may contain errors; pitches were preserved.")]), commands: commands)
    }
    func insertAudio(_ attachment: SongAttachment, source: URL, arguments: JSONValue, song: Song) async throws -> ReferenceToolResult {
        let (start, end, beat, name, existingTarget) = try placement(arguments, attachment: attachment, song: song, kind: .audio)
        guard let stem = arguments["stem"]?.stringValue else { throw AgentError.invalidTool("Choose source or an exact returned stem name.") }
        let namesValue = arguments["stem_names"]
        guard namesValue == nil || namesValue == .null || namesValue?.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true else { throw AgentError.invalidTool("stem_names must be null or an array of exact stem-name strings.") }
        let mixNames = namesValue?.arrayValue?.compactMap(\.stringValue) ?? []
        let mixGain = try optionalNumber(arguments, "mix_gain") ?? 1
        guard mixGain.isFinite, (0.001...1).contains(mixGain),
              (stem == "mix" ? (!mixNames.isEmpty && mixNames.count <= 12 && Set(mixNames).count == mixNames.count) : mixNames.isEmpty) else { throw AgentError.invalidTool("For a mix choose 1–12 distinct returned stem_names and mix_gain 0.001–1. Other stems use null stem_names.") }
        let sourceTempo = try optionalNumber(arguments, "source_tempo"), targetTempo = try optionalNumber(arguments, "target_tempo")
        guard (sourceTempo == nil) == (targetTempo == nil), [sourceTempo, targetTempo].allSatisfy({ $0 == nil || ($0!.isFinite && (30...300).contains($0!)) }) else { throw AgentError.invalidTool("Supply both source and target BPM, or null for both.") }
        let fadeIn = try number(arguments, "fade_in_beats", range: 0...200_000)
        let fadeOut = try number(arguments, "fade_out_beats", range: 0...200_000)
        let rate = (sourceTempo != nil && targetTempo != nil) ? targetTempo! / sourceTempo! : 1
        guard (0.5...2).contains(rate) else { throw AgentError.invalidTool("Tempo alignment supports half to twice the source tempo.") }
        let expectedLength = (end - start) / rate * song.tempo / 60
        guard beat + expectedLength <= 200_000, fadeIn + fadeOut <= expectedLength + 0.000001 else { throw AgentError.invalidTool("Choose valid placement and fade lengths that fit the prepared clip.") }
        let fingerprint = "\(attachment.id)|\(stem)|\(mixNames.sorted())|\(mixGain)|\(start)|\(end)|\(sourceTempo ?? 0)|\(targetTempo ?? 0)"
        let prepared: (AudioAsset, URL)
        if let cached = derivations[fingerprint] { prepared = cached }
        else {
            let inputs: [URL]
            if stem == "mix" {
                let separation = try await separation(attachment, source: source)
                inputs = try mixNames.map { name in
                    guard let result = separation.audio.first(where: { $0.name == name }) else { throw AgentError.invalidTool("Use only exact returned audio_stems names in stem_names.") }
                    return result.url
                }
            } else { inputs = [try await audioSource(attachment, original: source, stem: stem)] }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try reserveDraftBytes(Int64(ceil((end - start) / rate * 48_000 * 6)) + 65_536)
            let id = UUID(), output = directory.appendingPathComponent("\(id).wav")
            status(attachment.id, "Preparing \(stem == "source" ? "source audio" : stem)…")
            let metadata = try await referenceWork {
                do {
                    return try ReferenceAudioProcessor.renderMix(sources: inputs, to: output, startSeconds: start,
                        durationSeconds: end - start, sourceTempo: sourceTempo, targetTempo: targetTempo, gain: mixGain)
                } catch let error as AudioError {
                    if error.localizedDescription.lowercased().contains("clip") { throw AgentError.invalidTool("The selected stem mix clips. Lower mix_gain and retry this local preparation; separated stems are cached.") }
                    throw error
                }
            }
            var asset = AudioAsset(id: id, fileName: "\(id).wav", duration: metadata.duration, sampleRate: metadata.sampleRate, channels: metadata.channels)
            asset.referenceDerivation = ReferenceAudioDerivation(attachmentID: attachment.id, stem: stem, sourceStartSeconds: start,
                sourceEndSeconds: end, sourceTempo: sourceTempo, targetTempo: targetTempo, stemNames: stem == "mix" ? mixNames : nil, mixGain: mixGain)
            prepared = (asset, output); derivations[fingerprint] = prepared; derived[id] = output
        }
        let length = prepared.0.duration * song.tempo / 60
        guard fadeIn + fadeOut <= length + 0.000001 else { throw AgentError.invalidTool("Clip fades must fit inside the prepared audio clip.") }
        var commands: [ProjectCommand] = []
        if !song.assets.contains(where: { $0.id == prepared.0.id }) { commands.append(ProjectCommand(op: .addAsset, asset: prepared.0)) }
        let target: UUID
        if let existingTarget { target = existingTarget }
        else {
            let track = Track(name: name, kind: .audio, colorIndex: song.tracks.count, parameters: ["cutoff": 20_000, "delay": 0, "reverb": 0, "drive": 0])
            target = track.id; commands.append(ProjectCommand(op: .addTrack, track: track))
        }
        var clip = Clip(name: name, kind: .audio, startBeat: beat, lengthBeats: length, assetID: prepared.0.id)
        clip.referenceAttachmentID = attachment.id; clip.fadeInBeats = fadeIn; clip.fadeOutBeats = fadeOut
        commands.append(ProjectCommand(op: .addClip, trackID: target, clip: clip))
        status(attachment.id, "Audio ready")
        return ReferenceToolResult(output: .object(["ok": .bool(true), "track_id": .string(target.uuidString), "clip_id": .string(clip.id.uuidString),
            "asset_id": .string(prepared.0.id.uuidString), "duration_seconds": .number(prepared.0.duration),
            "note": .string("Original/stem audio staged with source provenance. It does not follow later tempo changes; prepare again after changing tempo.")]), commands: commands)
    }
}
