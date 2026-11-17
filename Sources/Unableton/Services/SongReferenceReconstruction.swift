import Foundation
import UnabletonCore
import UnabletonAI
import UnabletonAudio

extension SongReferenceRuntime {
    func reconstructionRange(_ arguments: JSONValue, attachment: SongAttachment) throws -> (Double, Double) {
        let start = try optionalNumber(arguments, "source_start_seconds") ?? 0
        let end = try optionalNumber(arguments, "source_end_seconds") ?? attachment.duration
        guard start >= 0, end > start, end <= attachment.duration + 0.001 else {
            throw AgentError.invalidTool("Choose a nonempty reconstruction range inside the attached song.")
        }
        return (start, min(end, attachment.duration))
    }

    func reconstruction(_ attachment: SongAttachment, source: URL, start: Double, end: Double) async throws -> ReferenceReconstruction {
        if let saved = reconstructions[attachment.id], saved.profile == ReferenceReconstruction.currentProfile,
           saved.sourceStartSeconds == start, saved.sourceEndSeconds == end {
            try saved.validate(maximumDuration: attachment.duration)
            return saved
        }
        _ = try await separation(attachment, source: source)
        status(attachment.id, "Measuring bass, accompaniment and drum events locally…")
        let processing = try await processingSession()
        let result = try await processing.reconstruct(source: source, sha256: attachment.sha256,
            startSeconds: start, endSeconds: end, budget: budget)
        try result.validate(maximumDuration: attachment.duration)
        try await updateReconstruction(attachment.id, result)
        reconstructions[attachment.id] = result
        status(attachment.id, "Reconstruction measurements ready")
        return result
    }

    func reconstructionFits(_ score: ReferenceReconstruction, attachment: SongAttachment) async throws -> [String: ReferenceSoundFit] {
        guard !score.parts.isEmpty, let original = sources[attachment.id] else { return [:] }
        // A saved score can outlive its temporary stems or the installed sound
        // inventory. Reuse the project cache, or separate locally again, before
        // comparing the current installed instruments against the real source.
        let separation = try await separation(attachment, source: original)
        let resources: InstrumentResources
        if let heldFittingResources { resources = heldFittingResources }
        else {
            resources = try await fittingResources()
            heldFittingResources = resources
        }
        var fits: [String: ReferenceSoundFit] = [:]
        for part in score.parts {
            try await budget.check()
            let key = "\(attachment.id)|\(score.profile)|\(score.sourceStartSeconds)|\(score.sourceEndSeconds)|\(part.id)"
            if let cached = reconstructionSoundFits[key] { fits[part.id] = cached; continue }
            let stem = part.role == "bass" ? "bass" : part.role == "drums" ? "drums" : "other"
            guard let url = separation.audio.first(where: { $0.name == stem })?.url else { continue }
            status(attachment.id, "Comparing local sounds for \(part.name)…")
            let folder = directory.appendingPathComponent("SoundFit-\(UUID())", isDirectory: true)
            let fit = try await budget.withDependencyWait(kind: .referenceProcessing) {
                try await referenceWork {
                    defer { try? FileManager.default.removeItem(at: folder) }
                    return try ReferenceSoundMatcher.fit(part: part, sourceURL: url, sourceStartSeconds: score.sourceStartSeconds,
                        sourceEndSeconds: score.sourceEndSeconds, directory: folder, resources: resources, siblingParts: score.parts)
                }
            }
            fits[part.id] = fit; reconstructionSoundFits[key] = fit
        }
        status(attachment.id, "Reconstruction sound comparison ready")
        return fits
    }

    func reconstructionSummary(_ score: ReferenceReconstruction, fits: [String: ReferenceSoundFit] = [:]) throws -> JSONValue {
        let balancedVolumes = ReferenceSoundMatcher.balancedVolumes(parts: score.parts, fits: fits)
        let parts = try score.parts.map { part -> JSONValue in
            let pitches = Set(part.notes.map(\.pitch))
            let candidates = InstrumentCatalog.presets.filter { preset in
                (part.role == "drums") == preset.roles.contains("drums")
                && (part.role != "drums" || preset.id == "drums.electronic" || preset.pitchMap != nil)
                && pitches.allSatisfy {
                    (preset.minimumPitch...preset.maximumPitch).contains($0)
                        && preset.supportedPitches?.contains($0) != false
                        && preset.unrenderablePitches?.contains($0) != true
                }
            }.sorted { lhs, rhs in
                let preferred = part.role == "bass" ? "synth.bass" : part.role == "drums" ? "drums.electronic" : "synth.pluck"
                if (lhs.id == preferred) != (rhs.id == preferred) { return lhs.id == preferred }
                let lhsRole = lhs.roles.contains(part.role) || (part.role == "accompaniment" && lhs.roles.contains("harmony"))
                let rhsRole = rhs.roles.contains(part.role) || (part.role == "accompaniment" && rhs.roles.contains("harmony"))
                if lhsRole != rhsRole { return lhsRole }
                return lhs.id < rhs.id
            }
            let fit = fits[part.id]
            let siblings = score.parts.filter { $0.role == part.role }
            let gainNorm = sqrt(siblings.reduce(0) { $0 + $1.relativeGain * $1.relativeGain })
            let share = fit?.gainBasis == "part-envelope-v1" ? 1 : gainNorm > 0 ? part.relativeGain / gainNorm : 1 / sqrt(Double(max(1, siblings.count)))
            let suggestedVolume = balancedVolumes[part.id] ?? min(0.65, 0.55 * part.relativeGain * share)
            var comparison: JSONValue = .null
            if let fit, case .object(var values) = try JSONValue.encode(fit) {
                values["unscaled_volume"] = .number(fit.volume)
                values["shared_stem_gain_share"] = .number(share)
                values["volume"] = .number(suggestedVolume)
                comparison = .object(values)
            }
            return .object([
                "part_id": .string(part.id), "role": .string(part.role), "name": .string(part.name),
                "note_count": .number(Double(part.notes.count)),
                "first_note_seconds": .number(part.notes.first?.startSeconds ?? score.sourceStartSeconds),
                "minimum_pitch": .number(Double(pitches.min() ?? 0)), "maximum_pitch": .number(Double(pitches.max() ?? 0)),
                "relative_gain": .number(part.relativeGain),
                "suggested_volume": .number(suggestedVolume),
                "suggested_parameters": try .encode(fit?.parameters ?? part.suggestedParameters),
                "sound_comparison": comparison,
                "instrument_candidates": .array(candidates.prefix(10).map { preset in
                    .object(["instrument_id": .string(preset.id), "name": .string(preset.name),
                             "roles": .array(preset.roles.map(JSONValue.string)), "sampled": .bool(preset.isSampler)])
                }),
                "note_excerpt": try .encode(Array(part.notes.prefix(12)))
            ])
        }
        return .object([
            "profile": .string(score.profile), "source_start_seconds": .number(score.sourceStartSeconds),
            "source_end_seconds": .number(score.sourceEndSeconds), "tempo_estimate": score.tempo.map(JSONValue.number) ?? .null,
            "tempo_quality": .number(score.tempoQuality), "parts": .array(parts), "warnings": try .encode(score.warnings),
            "note": .string("These are filtered local estimates, separate from raw MIDI. Vocals are excluded. A sound_comparison compares local renders of installed catalog instruments and built-in synths with source spectrum and envelope; distances are not listening judgments. Null means no render comparison was available for the saved score. Instrument candidates are pitch-compatible choices, not identified original instruments. Choose explicit replacement tracks to avoid layering conflicting arrangements. Source seconds and rests are preserved.")
        ])
    }

    func reconstruct(_ attachment: SongAttachment, source: URL, arguments: JSONValue, song: Song) async throws -> ReferenceToolResult {
        let (start, end) = try reconstructionRange(arguments, attachment: attachment)
        let beat = try number(arguments, "start_beat", range: 0...200_000)
        guard let values = arguments["parts"]?.arrayValue, !values.isEmpty, values.count <= 12,
              let replacements = arguments["replace_track_ids"]?.arrayValue, replacements.count <= 64 else {
            throw AgentError.invalidTool("Choose measured parts and explicitly list any tracks to replace.")
        }
        let trackIDs = try replacements.map { value -> UUID in
            guard let raw = value.stringValue, let id = UUID(uuidString: raw), song.track(id) != nil else {
                throw AgentError.invalidTool("Replacement IDs must name current tracks.")
            }
            return id
        }
        let selections = try values.map { value -> ReferenceReconstructionSelection in
            guard let part = value["part_id"]?.stringValue, let instrument = value["instrument_id"]?.stringValue,
                  let pairs = value["parameters"]?.arrayValue, pairs.count <= InstrumentCatalog.parameterDescriptors.count else {
                throw AgentError.invalidTool("Each measured part needs a catalog instrument and explicit sound parameters.")
            }
            var parameters: [String: Double] = [:]
            for pair in pairs {
                guard let id = pair["id"]?.stringValue, let number = pair["value"]?.doubleValue, number.isFinite,
                      parameters[id] == nil else { throw AgentError.invalidTool("Sound parameters must be distinct finite id/value pairs.") }
                parameters[id] = number
            }
            return ReferenceReconstructionSelection(partID: part, instrumentID: instrument, parameters: parameters,
                volume: try number(value, "volume", range: 0...1.5), pan: try number(value, "pan", range: -1...1))
        }
        let measured = try await reconstruction(attachment, source: source, start: start, end: end)
        let plan = try ReferenceReconstructionPlanner.plan(song: song, attachmentID: attachment.id,
            reconstruction: measured, startBeat: beat, selections: selections, replaceTrackIDs: trackIDs)
        return ReferenceToolResult(output: .object([
            "ok": .bool(true), "profile": .string(measured.profile), "source_start_seconds": .number(start), "source_end_seconds": .number(end),
            "track_ids": .array(plan.trackIDs.map { .string($0.uuidString) }), "clip_ids": .array(plan.clipIDs.map { .string($0.uuidString) }),
            "notes_inserted": .number(Double(plan.noteCount)), "muted_track_ids": .array(trackIDs.map { .string($0.uuidString) }),
            "warnings": try .encode(plan.warnings),
            "note": .string("Measured instrumental reconstruction staged. Prior tracks were retained and explicitly muted for Undo. Source timing is preserved; sounds and drum classes are approximations. The host renders the actual draft before accepting this tool.")
        ]), commands: plan.commands)
    }
}
