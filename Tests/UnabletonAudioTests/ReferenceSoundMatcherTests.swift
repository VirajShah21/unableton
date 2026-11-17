import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAudio

@Suite(.serialized)
struct ReferenceSoundMatcherTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReferenceSoundMatcherTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func render(part: ReferenceReconstructionPart, instrument: String, parameters: [String: Double],
                        volume: Double, duration: Double, to url: URL, resources: InstrumentResources = .empty) throws {
        var song = Song(); song.tempo = 120; song.lengthBars = 1
        let notes = part.notes.map { NoteEvent(pitch: $0.pitch, startBeat: $0.startSeconds * 2,
            duration: $0.durationSeconds * 2, velocity: $0.velocity) }
        song.tracks = [Track(instrumentID: instrument, volume: volume, parameters: parameters,
            clips: [Clip(lengthBeats: duration * 2, notes: notes)])]
        let report = try OfflineRenderer.render(song: song, assets: [:], to: url, lengthBeats: duration * 2, resources: resources)
        #expect(!report.silent && report.clippedSamples == 0)
    }

    @Test func realBassRenderPrefersMatchingWaveformWithoutPresetWobble() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let parameters: [String: Double] = ["oscillator": 0, "attack": 0.005, "decay": 0.08,
            "sustain": 0.8, "release": 0.08, "cutoff": 350, "lfoDepth": 0, "detune": 0,
            "drive": 0, "delay": 0, "reverb": 0]
        let part = ReferenceReconstructionPart(id: "bass", role: "bass", name: "Measured bass",
            notes: [.init(pitch: 40, startSeconds: 0.45, durationSeconds: 0.55, velocity: 90),
                    .init(pitch: 43, startSeconds: 1.35, durationSeconds: 0.7, velocity: 100)],
            relativeGain: 1, suggestedParameters: parameters)
        let target = folder.appendingPathComponent("Target.wav")
        try render(part: part, instrument: "synth.bass", parameters: parameters, volume: 0.3, duration: 3.5, to: target)
        let sentinel = folder.appendingPathComponent("Keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let fit = try ReferenceSoundMatcher.fit(part: part, sourceURL: target,
            sourceStartSeconds: 0, sourceEndSeconds: 3.5, directory: folder)
        #expect(fit.instrumentID == "synth.bass")
        #expect(fit.parameters["oscillator"] == 0)
        #expect(fit.parameters["lfoDepth"] == 0 && fit.parameters["detune"] == 0)
        #expect(fit.spectralDistance < 0.01 && fit.envelopeDistance < 0.01)
        #expect(abs(fit.volume - 0.3) < 0.01)
        #expect(abs(fit.sourceGain - 0.3) < 0.01)
        #expect((2...36).contains(fit.testedCandidates))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(try !FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("SoundFit-") })
    }

    @Test func sourceOffsetAndRestsAreComparedAgainstActualPluckEnvelope() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let parameters: [String: Double] = ["oscillator": 1, "cutoff": 4_000,
            "lfoDepth": 0, "detune": 0, "drive": 0, "delay": 0, "reverb": 0]
        let part = ReferenceReconstructionPart(id: "other", role: "accompaniment", name: "Measured accompaniment",
            notes: [.init(pitch: 64, startSeconds: 11.25, durationSeconds: 0.4, velocity: 95),
                    .init(pitch: 67, startSeconds: 12.1, durationSeconds: 0.3, velocity: 85)],
            relativeGain: 0.7, suggestedParameters: parameters)
        let target = folder.appendingPathComponent("Target.wav")
        try render(part: part, instrument: "synth.pluck", parameters: parameters, volume: 0.25, duration: 13, to: target)
        let fit = try ReferenceSoundMatcher.fit(part: part, sourceURL: target,
            sourceStartSeconds: 10, sourceEndSeconds: 13, directory: folder)
        #expect(fit.instrumentID == "synth.pluck")
        #expect(fit.spectralDistance < 0.015 && fit.envelopeDistance < 0.015)
        #expect((0...1.5).contains(fit.volume))
        #expect((3...36).contains(fit.testedCandidates))
        #expect(part.notes[0].startSeconds == 11.25 && part.notes[1].startSeconds == 12.1)
    }

    @Test func cancelledFitDoesNotStartRenderingOrCreateTemporaryFiles() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let part = ReferenceReconstructionPart(id: "bass", role: "bass", name: "Bass",
            notes: [.init(pitch: 40, startSeconds: 0.2, durationSeconds: 0.2, velocity: 80)], relativeGain: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReferenceSoundMatcher.fit(part: part, sourceURL: folder.appendingPathComponent("NotRead.wav"),
                sourceStartSeconds: 0, sourceEndSeconds: 1, directory: folder)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func highGainPartsUseOneScaleAndRetainTheirMeasuredRatios() throws {
        func part(_ id: String, _ role: String, _ gain: Double) -> ReferenceReconstructionPart {
            ReferenceReconstructionPart(id: id, role: role, name: id,
                notes: [.init(pitch: role == "drums" ? 36 : 48, startSeconds: 0, durationSeconds: 0.2, velocity: 80)],
                relativeGain: gain)
        }
        let parts = [part("bass", "bass", 1), part("other", "accompaniment", 0.8),
                     part("texture", "accompaniment", 0.2), part("drums", "drums", 0.5)]
        let raw = ["bass": 20.0, "other": 10.0, "texture": 10.0, "drums": 5.0]
        let fits = raw.mapValues { gain in
            ReferenceSoundFit(instrumentID: "synth.bass", parameters: [:], sourceGain: gain, volume: min(1.5, gain),
                spectralDistance: 0.2, envelopeDistance: 0.1, testedCandidates: 1)
        }
        let volumes = ReferenceSoundMatcher.balancedVolumes(parts: parts, fits: fits)
        let bass = try #require(volumes["bass"]), drums = try #require(volumes["drums"])
        let other = try #require(volumes["other"]), texture = try #require(volumes["texture"])
        #expect(abs(bass - 1.5) < 0.000001)
        #expect(abs(bass / drums - 4) < 0.000001)
        #expect(abs(other / texture - 4) < 0.000001) // relativeGain is an amplitude share.
        #expect(abs(other - 10 * 0.8 / sqrt(0.8 * 0.8 + 0.2 * 0.2) * 0.075) < 0.000001)
        #expect(volumes.values.allSatisfy { (0...1.5).contains($0) })
        #expect(abs(other * other + texture * texture - pow(10 * 0.075, 2)) < 0.000001)
    }

    @Test func quietPartsAreNotIndependentlyBoostedOrClamped() throws {
        let parts = [ReferenceReconstructionPart(id: "bass", role: "bass", name: "Bass",
            notes: [.init(pitch: 40, startSeconds: 0, durationSeconds: 0.2, velocity: 80)], relativeGain: 1),
            ReferenceReconstructionPart(id: "other", role: "accompaniment", name: "Other",
            notes: [.init(pitch: 64, startSeconds: 0, durationSeconds: 0.2, velocity: 80)], relativeGain: 0.1)]
        let fits = ["bass": 0.5, "other": 0.005].mapValues { gain in
            ReferenceSoundFit(instrumentID: "synth.bass", parameters: [:], sourceGain: gain, volume: min(1.5, gain),
                spectralDistance: 0, envelopeDistance: 0, testedCandidates: 1)
        }
        let volumes = ReferenceSoundMatcher.balancedVolumes(parts: parts, fits: fits)
        #expect(volumes["bass"] == 0.5)
        #expect(volumes["other"] == 0.005)
    }

    @Test func suppliedInstalledSamplerCanWinTheActualRenderSearch() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let bank = folder.appendingPathComponent("Fixture.sf2")
        try SoundFontFixture.write(to: bank)
        let resources = InstrumentResources(urls: ["sampled.piano": bank])
        let sampleParameters: [String: Double] = ["cutoff": 20_000, "drive": 0, "delay": 0, "reverb": 0]
        let part = ReferenceReconstructionPart(id: "keys", role: "accompaniment", name: "Measured keyboard",
            notes: [.init(pitch: 64, startSeconds: 0.35, durationSeconds: 0.3, velocity: 90),
                    .init(pitch: 72, startSeconds: 1.1, durationSeconds: 0.45, velocity: 100)],
            relativeGain: 1, suggestedParameters: sampleParameters.merging(["oscillator": 3, "lfoDepth": 0, "attack": 0.1]) { _, new in new })
        let target = folder.appendingPathComponent("Sampled target.wav")
        try render(part: part, instrument: "sampled.piano", parameters: sampleParameters, volume: 0.3,
            duration: 2, to: target, resources: resources)
        let fit = try ReferenceSoundMatcher.fit(part: part, sourceURL: target, sourceStartSeconds: 0, sourceEndSeconds: 2,
            directory: folder, resources: resources, candidateIDs: ["sampled.piano", "synth.pluck", "synth.pad"])
        #expect(fit.instrumentID == "sampled.piano")
        #expect(fit.spectralDistance < 0.02 && fit.envelopeDistance < 0.02)
        #expect(Set(fit.parameters.keys).isSubset(of: ["cutoff", "drive", "delay", "reverb"]))
        #expect(fit.testedCandidates >= 3 && fit.testedCandidates <= 36)
    }

    @Test func missingExplicitSamplerDoesNotBecomeAnUnrequestedSynth() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let part = ReferenceReconstructionPart(id: "keys", role: "accompaniment", name: "Keys",
            notes: [.init(pitch: 64, startSeconds: 0.2, durationSeconds: 0.2, velocity: 80)], relativeGain: 1)
        #expect(throws: MissingInstruments.self) {
            try ReferenceSoundMatcher.fit(part: part, sourceURL: folder.appendingPathComponent("Not read.wav"),
                sourceStartSeconds: 0, sourceEndSeconds: 1, directory: folder,
                candidateIDs: ["sampled.piano", "synth.pluck"])
        }
        #expect(throws: MissingInstruments.self) {
            try ReferenceSoundMatcher.fit(part: part, sourceURL: folder.appendingPathComponent("Not read.wav"),
                sourceStartSeconds: 0, sourceEndSeconds: 1, directory: folder,
                resources: InstrumentResources(urls: ["sampled.piano": folder.appendingPathComponent("Missing.sf2")]),
                candidateIDs: ["sampled.piano", "synth.pluck"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func reviewedBassFamilyRemainsEligibleWhenCatalogRolesDescribeItsLeadUse() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let preset = try #require(InstrumentCatalog.preset(id: "freepats.synthbasslead"))
        #expect(!preset.roles.contains("bass")) // The reviewed name/family also supplies a musical hint.
        let bank = folder.appendingPathComponent("Bass and lead fixture.sf2")
        try SoundFontFixture.write(to: bank, program: UInt16(preset.program), bank: preset.bank)
        let resources = InstrumentResources(urls: [preset.id: bank])
        let parameters: [String: Double] = ["cutoff": 20_000, "drive": 0, "delay": 0, "reverb": 0]
        let part = ReferenceReconstructionPart(id: "bass", role: "bass", name: "Measured bass",
            notes: [.init(pitch: 40, startSeconds: 0.25, durationSeconds: 0.4, velocity: 90),
                    .init(pitch: 43, startSeconds: 1.0, durationSeconds: 0.45, velocity: 95)],
            relativeGain: 1, suggestedParameters: parameters)
        let target = folder.appendingPathComponent("Sampled bass.wav")
        try render(part: part, instrument: preset.id, parameters: parameters, volume: 0.3,
            duration: 2, to: target, resources: resources)
        let fit = try ReferenceSoundMatcher.fit(part: part, sourceURL: target, sourceStartSeconds: 0,
            sourceEndSeconds: 2, directory: folder, resources: resources,
            candidateIDs: [preset.id, "synth.bass"])
        #expect(fit.instrumentID == preset.id)
        #expect(fit.spectralDistance < 0.02 && fit.envelopeDistance < 0.02)
        #expect(Set(fit.parameters.keys).isSubset(of: ["cutoff", "drive", "delay", "reverb"]))
    }

    @Test func normalizedGainRemainsInsideSharedCommandBoundsAfterRounding() throws {
        let part = ReferenceReconstructionPart(id: "bass", role: "bass", name: "Bass",
            notes: [.init(pitch: 43, startSeconds: 0, durationSeconds: 1, velocity: 80)], relativeGain: 1)
        let score = ReferenceReconstruction(sourceStartSeconds: 0, sourceEndSeconds: 1, parts: [part])
        let fit = ReferenceSoundFit(instrumentID: "synth.bass", parameters: [:], sourceGain: 2.1376,
            volume: 1.5, spectralDistance: 0, envelopeDistance: 0, testedCandidates: 1)
        let volumes = ReferenceSoundMatcher.balancedVolumes(parts: [part], fits: [part.id: fit])
        let volume = try #require(volumes[part.id])
        let plan = try ReferenceReconstructionPlanner.plan(song: Song(), attachmentID: UUID(), reconstruction: score,
            startBeat: 0, selections: [.init(partID: part.id, instrumentID: fit.instrumentID, parameters: [:], volume: volume)],
            replaceTrackIDs: [])
        #expect(!plan.commands.isEmpty && volume <= 1.5)
    }

    @Test func unknownSustainedPadIsRecoveredAcrossAttackHoldAndRelease() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let part = ReferenceReconstructionPart(id: "texture", role: "accompaniment", name: "Held texture",
            notes: [.init(pitch: 60, startSeconds: 0.3, durationSeconds: 8, velocity: 90),
                    .init(pitch: 67, startSeconds: 9, durationSeconds: 6, velocity: 90)],
            relativeGain: 1) // No target ADSR or waveform is given to the fitter.
        var controls = InstrumentCatalog.defaults(for: "synth.pad")
        controls.merge(["lfoDepth": 0, "drive": 0, "delay": 0, "reverb": 0]) { _, new in new }
        let target = folder.appendingPathComponent("Unknown sustained patch.wav")
        try render(part: part, instrument: "synth.pad", parameters: controls, volume: 0.3, duration: 18, to: target)
        let fit = try ReferenceSoundMatcher.fit(part: part, sourceURL: target, sourceStartSeconds: 0,
            sourceEndSeconds: 18, directory: folder,
            candidateIDs: ["synth.pluck", "synth.pad", "synth.lead", "synth.strings"])
        #expect(fit.instrumentID == "synth.pad")
        #expect((fit.articulationDistance ?? 1) < 0.03)
        #expect(fit.envelopeDistance < 0.03)
        let excerpts = try #require(fit.excerpts)
        #expect(excerpts.count == 3)
        #expect(excerpts.contains { $0.preRollSeconds > 2 && !$0.warmupTruncated })
        #expect((excerpts.last?.startSeconds ?? 0) - (excerpts.first?.startSeconds ?? 0) > 8)
    }

    @Test func separatedPassagesHaveToAgreeOnTheSamePluckSound() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let part = ReferenceReconstructionPart(id: "motif", role: "accompaniment", name: "Repeated motif",
            notes: [0.25, 6.25, 12.25].flatMap { start in
                [MIDITimedNote(pitch: 72, startSeconds: start, durationSeconds: 0.25, velocity: 90),
                 MIDITimedNote(pitch: 76, startSeconds: start + 0.7, durationSeconds: 0.3, velocity: 85)]
            }, relativeGain: 1)
        var controls = InstrumentCatalog.defaults(for: "synth.pluck")
        controls.merge(["lfoDepth": 0, "drive": 0, "delay": 0, "reverb": 0]) { _, new in new }
        let target = folder.appendingPathComponent("Three passages.wav")
        try render(part: part, instrument: "synth.pluck", parameters: controls, volume: 0.3, duration: 15, to: target)
        let fit = try ReferenceSoundMatcher.fit(part: part, sourceURL: target, sourceStartSeconds: 0,
            sourceEndSeconds: 15, directory: folder, candidateIDs: ["synth.pluck", "synth.pad", "synth.lead"])
        #expect(fit.instrumentID == "synth.pluck")
        let excerpts = try #require(fit.excerpts)
        #expect(excerpts.count == 3)
        #expect(excerpts.first!.startSeconds < 1 && excerpts.last!.endSeconds > 13)
        #expect(fit.spectralDistance < 0.03 && fit.envelopeDistance < 0.03)
    }

    @Test func hiHatUsesItsUnpitchedBandAndPreservesTheBrightAttack() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let part = ReferenceReconstructionPart(id: "hats", role: "drums", name: "Closed hats",
            notes: [0.2, 0.6, 1.0, 1.4].map { .init(pitch: 42, startSeconds: $0, durationSeconds: 0.1, velocity: 95) },
            relativeGain: 1)
        let controls: [String: Double] = ["attack": 0.001, "decay": 0.03, "sustain": 1, "release": 0.08,
            "cutoff": 20_000, "detune": 0, "drive": 0, "delay": 0, "reverb": 0, "lfoDepth": 0]
        let target = folder.appendingPathComponent("Bright closed hats.wav")
        try render(part: part, instrument: "drums.electronic", parameters: controls, volume: 0.3, duration: 2, to: target)
        let fit = try ReferenceSoundMatcher.fit(part: part, sourceURL: target, sourceStartSeconds: 0,
            sourceEndSeconds: 2, directory: folder)
        #expect(fit.instrumentID == "drums.electronic")
        #expect(fit.parameters["cutoff"] == 20_000 && fit.parameters["attack"] == 0.001)
        #expect(fit.spectralDistance < 0.015 && fit.envelopeDistance < 0.015)
    }

    @Test func upperVoiceSoundChoiceIgnoresLowDroneInTheSameStem() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let parameters: [String: Double] = ["oscillator": 1, "cutoff": 4_000, "lfoDepth": 0,
            "detune": 0, "drive": 0, "delay": 0, "reverb": 0]
        let melody = ReferenceReconstructionPart(id: "melody", role: "accompaniment", name: "Upper melody",
            notes: [.init(pitch: 84, startSeconds: 0.5, durationSeconds: 0.25, velocity: 90),
                    .init(pitch: 88, startSeconds: 1.4, durationSeconds: 0.3, velocity: 95)],
            relativeGain: 0.2, suggestedParameters: parameters)
        let drone = ReferenceReconstructionPart(id: "drone", role: "bass", name: "Low drone",
            notes: [.init(pitch: 36, startSeconds: 0, durationSeconds: 2, velocity: 110)], relativeGain: 0.8)
        let clean = folder.appendingPathComponent("Upper.wav"), low = folder.appendingPathComponent("Low.wav")
        try render(part: melody, instrument: "synth.pluck", parameters: parameters, volume: 0.25, duration: 2, to: clean)
        try render(part: drone, instrument: "synth.bass", parameters: ["oscillator": 0, "lfoDepth": 0,
            "detune": 0, "drive": 0, "delay": 0, "reverb": 0, "attack": 0.01, "release": 0.01],
            volume: 0.8, duration: 2, to: low)
        let combined = folder.appendingPathComponent("Combined.wav")
        _ = try ReferenceAudioProcessor.renderMix(sources: [clean, low], to: combined, startSeconds: 0, durationSeconds: 2)
        let choices: Set<String> = ["synth.pluck", "synth.pad", "synth.lead"]
        let single = try ReferenceSoundMatcher.fit(part: melody, sourceURL: clean, sourceStartSeconds: 0,
            sourceEndSeconds: 2, directory: folder, candidateIDs: choices)
        let mixed = try ReferenceSoundMatcher.fit(part: melody, sourceURL: combined, sourceStartSeconds: 0,
            sourceEndSeconds: 2, directory: folder, candidateIDs: choices)
        #expect(single.instrumentID == "synth.pluck" && mixed.instrumentID == "synth.pluck")
        #expect(mixed.spectralDistance < 0.03 && mixed.envelopeDistance < 0.03)
        // The lower stem's energy must not become a louder upper melody.
        #expect(single.gainBasis == "part-envelope-v1" && mixed.gainBasis == single.gainBasis)
        #expect(abs(mixed.sourceGain - single.sourceGain) < 0.02)
    }
    @Test func independentPartGainIsNotAllocatedASecondTime() throws {
        let notes = [MIDITimedNote(pitch: 60, startSeconds: 0, durationSeconds: 1, velocity: 90)]
        let parts = [ReferenceReconstructionPart(id: "held", role: "accompaniment", name: "Held", notes: notes, relativeGain: 0.9),
                     ReferenceReconstructionPart(id: "quiet", role: "accompaniment", name: "Quiet", notes: notes, relativeGain: 0.1)]
        let fits = ["held": 0.3, "quiet": 0.1].mapValues { gain in
            ReferenceSoundFit(instrumentID: "synth.pad", parameters: [:], sourceGain: gain, volume: gain,
                spectralDistance: 0, envelopeDistance: 0, testedCandidates: 1, gainBasis: "part-envelope-v1")
        }
        let volumes = ReferenceSoundMatcher.balancedVolumes(parts: parts, fits: fits)
        #expect(volumes["held"] == 0.3 && volumes["quiet"] == 0.1)
        let encoded = try JSONEncoder().encode(fits["held"]!)
        #expect(try JSONDecoder().decode(ReferenceSoundFit.self, from: encoded) == fits["held"])
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "gainBasis")
        let old = try JSONDecoder().decode(ReferenceSoundFit.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.gainBasis == nil && old.sourceGain == 0.3)
    }

    @Test func upperVoiceHarmonicsDoNotChangeALowerVoiceIntoABrightPatch() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let controls: [String: Double] = ["oscillator": 0, "attack": 0.005, "decay": 0.08,
            "sustain": 0.8, "release": 0.03, "cutoff": 6_000, "lfoDepth": 0, "detune": 0,
            "drive": 0, "delay": 0, "reverb": 0]
        let lower = ReferenceReconstructionPart(id: "lower", role: "accompaniment", name: "Low held tone",
            notes: [.init(pitch: 48, startSeconds: 0.2, durationSeconds: 2.2, velocity: 90)], relativeGain: 0.5,
            suggestedParameters: controls)
        let upper = ReferenceReconstructionPart(id: "upper", role: "accompaniment", name: "Upper attacks",
            notes: [0.4, 1.1, 1.8].map { .init(pitch: 72, startSeconds: $0, durationSeconds: 0.25, velocity: 110) },
            relativeGain: 0.5)
        let clean = folder.appendingPathComponent("Lower.wav"), bright = folder.appendingPathComponent("Upper.wav")
        try render(part: lower, instrument: "synth.lead", parameters: controls, volume: 0.25, duration: 3, to: clean)
        try render(part: upper, instrument: "synth.lead", parameters: ["oscillator": 1, "attack": 0.001,
            "cutoff": 10_000, "lfoDepth": 0, "detune": 0, "drive": 0, "delay": 0, "reverb": 0],
            volume: 0.65, duration: 3, to: bright)
        let mixed = folder.appendingPathComponent("Both.wav")
        _ = try ReferenceAudioProcessor.renderMix(sources: [clean, bright], to: mixed, startSeconds: 0, durationSeconds: 3)
        let baseline = try ReferenceSoundMatcher.fit(part: lower, sourceURL: clean, sourceStartSeconds: 0,
            sourceEndSeconds: 3, directory: folder, candidateIDs: ["synth.lead", "synth.pluck", "synth.pad"],
            siblingParts: [lower, upper])
        let fit = try ReferenceSoundMatcher.fit(part: lower, sourceURL: mixed, sourceStartSeconds: 0,
            sourceEndSeconds: 3, directory: folder, candidateIDs: ["synth.lead", "synth.pluck", "synth.pad"],
            siblingParts: [lower, upper])
        #expect(baseline.parameters["oscillator"] == 0)
        #expect(fit.parameters["oscillator"] == baseline.parameters["oscillator"])
        #expect(abs(fit.sourceGain - baseline.sourceGain) < 0.03)
        #expect(fit.spectralDistance < 0.04 && fit.envelopeDistance < 0.04)
    }

}
