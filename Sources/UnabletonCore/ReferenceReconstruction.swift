import Foundation

/// A versioned local measurement. This is separate from legacy, unfiltered MIDI.
public struct ReferenceReconstruction: Codable, Sendable, Equatable {
    public static let currentProfile = "local-reconstruction-v4"
    public var isCurrentProfile: Bool { profile == Self.currentProfile }
    public var profile: String
    public var sourceStartSeconds: Double
    public var sourceEndSeconds: Double
    public var tempo: Double?
    public var tempoQuality: Double
    public var parts: [ReferenceReconstructionPart]
    public var warnings: [String]

    public init(profile: String = Self.currentProfile, sourceStartSeconds: Double, sourceEndSeconds: Double,
                tempo: Double? = nil, tempoQuality: Double = 0, parts: [ReferenceReconstructionPart], warnings: [String] = []) {
        self.profile = profile; self.sourceStartSeconds = sourceStartSeconds; self.sourceEndSeconds = sourceEndSeconds
        self.tempo = tempo; self.tempoQuality = tempoQuality; self.parts = parts; self.warnings = warnings
    }

    public func validate(maximumDuration: Double = 600) throws {
        // Old measurements remain valid document history and may still own
        // clips in Undo. Only the planner requires freshly analyzed data.
        guard ["local-reconstruction-v1", "local-reconstruction-v2", "local-reconstruction-v3", Self.currentProfile].contains(profile),
              maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 600.001,
              sourceStartSeconds.isFinite, sourceEndSeconds.isFinite, sourceStartSeconds >= 0,
              sourceEndSeconds > sourceStartSeconds, sourceEndSeconds <= maximumDuration + 0.001,
              tempo == nil || (tempo!.isFinite && (30...300).contains(tempo!)),
              tempoQuality.isFinite, (0...1).contains(tempoQuality),
              parts.count <= 12, Set(parts.map(\.id)).count == parts.count,
              parts.reduce(0, { $0 + $1.notes.count }) <= 65_536,
              warnings.count <= 16, warnings.allSatisfy({ $0.utf8.count <= 1024 }) else {
            throw ProjectError("Invalid or oversized reference reconstruction measurements.")
        }
        for part in parts {
            guard !part.id.isEmpty, part.id.utf8.count <= 128,
                  ["bass", "accompaniment", "drums"].contains(part.role),
                  !part.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, part.name.utf8.count <= 120,
                  !part.notes.isEmpty, part.relativeGain.isFinite, (0...1).contains(part.relativeGain),
                  part.suggestedParameters.count <= InstrumentCatalog.parameterDescriptors.count,
                  part.suggestedParameters.allSatisfy({ key, value in
                      value.isFinite && InstrumentCatalog.parameterDescriptors.first(where: { $0.id == key })?.range.contains(value) == true
                  }) else { throw ProjectError("Invalid reconstructed instrument part.") }
            var previousStart = -Double.infinity, previousEnd = -Double.infinity
            for note in part.notes {
                guard (0...127).contains(note.pitch), (1...127).contains(note.velocity),
                      note.startSeconds.isFinite, note.durationSeconds.isFinite, note.durationSeconds > 0,
                      note.startSeconds >= sourceStartSeconds - 0.001,
                      note.startSeconds + note.durationSeconds <= sourceEndSeconds + 0.001,
                      note.startSeconds >= previousStart,
                      part.role != "bass" || note.startSeconds >= previousEnd - 0.001,
                      part.role != "drums" || [36, 38, 42, 46].contains(note.pitch) else {
                    throw ProjectError("Invalid reconstructed note timing, pitch or bass overlap.")
                }
                previousStart = note.startSeconds; previousEnd = note.startSeconds + note.durationSeconds
            }
        }
    }
}

public struct ReferenceReconstructionPart: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var role: String
    public var name: String
    public var notes: [MIDITimedNote]
    /// Relative amplitude contribution within the broad source role. Balance
    /// divides by the role's L2 norm; this is not a power/energy probability.
    public var relativeGain: Double
    public var suggestedParameters: [String: Double]
    public init(id: String, role: String, name: String, notes: [MIDITimedNote], relativeGain: Double,
                suggestedParameters: [String: Double] = [:]) {
        self.id = id; self.role = role; self.name = name; self.notes = notes
        self.relativeGain = relativeGain; self.suggestedParameters = suggestedParameters
    }
}

public struct ReferenceReconstructionProvenance: Codable, Sendable, Equatable {
    public var profile: String
    public var partID: String
    public var sourceStartSeconds: Double
    public var sourceEndSeconds: Double
    public init(profile: String, partID: String, sourceStartSeconds: Double, sourceEndSeconds: Double) {
        self.profile = profile; self.partID = partID
        self.sourceStartSeconds = sourceStartSeconds; self.sourceEndSeconds = sourceEndSeconds
    }
    public func validate(maximumDuration: Double) throws {
        guard !profile.isEmpty, profile.utf8.count <= 120, !partID.isEmpty, partID.utf8.count <= 128,
              sourceStartSeconds.isFinite, sourceEndSeconds.isFinite, sourceStartSeconds >= 0,
              sourceEndSeconds > sourceStartSeconds, sourceEndSeconds <= maximumDuration + 0.001 else {
            throw ProjectError("Invalid reference-note reconstruction provenance.")
        }
    }
}

/// The caller chooses real catalog sounds and mixer settings explicitly.
public struct ReferenceReconstructionSelection: Sendable, Equatable {
    public var partID: String
    public var instrumentID: String
    public var parameters: [String: Double]
    public var volume: Double
    public var pan: Double
    public init(partID: String, instrumentID: String, parameters: [String: Double], volume: Double, pan: Double = 0) {
        self.partID = partID; self.instrumentID = instrumentID; self.parameters = parameters; self.volume = volume; self.pan = pan
    }
}

public struct ReferenceReconstructionPlan: Sendable {
    public let commands: [ProjectCommand]
    public let trackIDs: [UUID]
    public let clipIDs: [UUID]
    public let noteCount: Int
    public let warnings: [String]
}

public enum ReferenceReconstructionPlanner {
    /// Muting explicitly named tracks keeps all prior music available to Undo.
    /// Notes retain source seconds, with no quantization, transposition or invented accompaniment.
    public static func plan(song: Song, attachmentID: UUID, reconstruction: ReferenceReconstruction,
                            startBeat: Double, selections: [ReferenceReconstructionSelection],
                            replaceTrackIDs: [UUID]) throws -> ReferenceReconstructionPlan {
        try ProjectEditor.validate(song)
        try reconstruction.validate()
        guard reconstruction.isCurrentProfile else {
            throw ProjectError("This reconstruction uses an older analysis profile. Reanalyze the attached song before creating new reconstruction tracks; existing music has been preserved.")
        }
        guard startBeat.isFinite, startBeat >= 0, startBeat <= 200_000,
              !selections.isEmpty, selections.count <= reconstruction.parts.count,
              Set(selections.map(\.partID)).count == selections.count,
              song.tracks.count + selections.count <= 64,
              Set(replaceTrackIDs).count == replaceTrackIDs.count,
              replaceTrackIDs.allSatisfy({ song.track($0) != nil }) else {
            throw ProjectError("Choose distinct measured parts and existing replacement tracks within the 64-track limit.")
        }
        let replacement = Set(replaceTrackIDs)
        guard !song.tracks.contains(where: { $0.isSolo && !replacement.contains($0.id) }) else {
            throw ProjectError("A retained track is soloed. Clear its Solo state or explicitly include it in replacement before reconstruction.")
        }
        let beatsPerSecond = song.tempo / 60
        let length = (reconstruction.sourceEndSeconds - reconstruction.sourceStartSeconds) * beatsPerSecond
        guard startBeat + length <= 200_000 else { throw ProjectError("The reconstructed source range exceeds the timeline limit.") }
        var commands: [ProjectCommand] = [], trackIDs: [UUID] = [], clipIDs: [UUID] = [], noteCount = 0
        for track in song.tracks where replacement.contains(track.id) {
            if !track.isMuted { commands.append(ProjectCommand(op: .setMute, trackID: track.id, value: 1)) }
            if track.isSolo { commands.append(ProjectCommand(op: .setSolo, trackID: track.id, value: 0)) }
        }
        for (index, selection) in selections.enumerated() {
            guard let part = reconstruction.parts.first(where: { $0.id == selection.partID }) else {
                throw ProjectError("Choose a measured reconstruction part ID.")
            }
            guard let preset = InstrumentCatalog.preset(id: selection.instrumentID) else {
                throw ProjectError("Choose a catalog sound for \(part.name).")
            }
            guard selection.volume.isFinite, (0...1.5).contains(selection.volume) else {
                throw ProjectError("Volume for \(part.name) must be finite and between 0 and 1.5; received \(selection.volume).")
            }
            guard selection.pan.isFinite, (-1...1).contains(selection.pan) else {
                throw ProjectError("Pan for \(part.name) must be finite and between -1 and 1.")
            }
            guard (part.role == "drums") == preset.roles.contains("drums") else {
                throw ProjectError("\(preset.name) is incompatible with the measured \(part.role) part \(part.name).")
            }
            for (key, value) in selection.parameters.sorted(by: { $0.key < $1.key }) {
                guard value.isFinite, InstrumentCatalog.parameters(for: preset.id).first(where: { $0.id == key })?.range.contains(value) == true else {
                    throw ProjectError("\(preset.name) has an unsupported or out-of-range \(key) parameter for \(part.name).")
                }
            }
            guard part.notes.allSatisfy({
                (preset.minimumPitch...preset.maximumPitch).contains($0.pitch)
                    && preset.supportedPitches?.contains($0.pitch) != false
                    && preset.unrenderablePitches?.contains($0.pitch) != true
            }) else { throw ProjectError("\(preset.name) cannot play every measured pitch. Choose another sound; no notes were transposed or omitted.") }
            if part.role == "drums", preset.id != "drums.electronic" {
                guard let mapping = preset.pitchMap, part.notes.allSatisfy({ mapping[$0.pitch] != nil }) else {
                    throw ProjectError("\(preset.name) does not advertise a complete General MIDI drum mapping for this part. Choose a mapped drum kit or Electronic drums.")
                }
            }
            let track = Track(name: part.name, instrumentID: preset.id, colorIndex: song.tracks.count + index,
                              volume: selection.volume, pan: selection.pan, parameters: selection.parameters)
            let notes = part.notes.map { event in
                NoteEvent(pitch: event.pitch, startBeat: max(0, event.startSeconds - reconstruction.sourceStartSeconds) * beatsPerSecond,
                          duration: min(event.durationSeconds, reconstruction.sourceEndSeconds - event.startSeconds) * beatsPerSecond,
                          velocity: event.velocity)
            }
            var clip = Clip(name: part.name, startBeat: startBeat, lengthBeats: length, notes: notes)
            clip.referenceAttachmentID = attachmentID
            clip.referenceReconstruction = ReferenceReconstructionProvenance(profile: reconstruction.profile, partID: part.id,
                sourceStartSeconds: reconstruction.sourceStartSeconds, sourceEndSeconds: reconstruction.sourceEndSeconds)
            commands.append(ProjectCommand(op: .addTrack, track: track))
            commands.append(ProjectCommand(op: .addClip, trackID: track.id, clip: clip))
            trackIDs.append(track.id); clipIDs.append(clip.id); noteCount += notes.count
        }
        guard commands.count <= 128 else { throw ProjectError("The reconstruction exceeds one 128-operation transaction. Replace fewer tracks or select fewer parts.") }
        var candidate = song
        try ProjectEditor.apply(commands, to: &candidate)
        var warnings = reconstruction.warnings
        if song.tracks.contains(where: { !$0.isMuted && !replacement.contains($0.id) && !$0.clips.isEmpty }) {
            warnings.append("Existing tracks remain audible alongside the reconstruction.")
        }
        return ReferenceReconstructionPlan(commands: commands, trackIDs: trackIDs, clipIDs: clipIDs,
                                           noteCount: noteCount, warnings: Array(warnings.prefix(16)))
    }
}
