import Foundation
import AVFAudio
import Testing
import UnabletonCore
import UnabletonAI
import UnabletonAudio
@testable import Unableton

private enum RuntimeProviderMode: Sendable { case audioOnly, validMIDI, allMelodicMIDI, unauthorizedVocalMIDI, malformedAudio, malformedMIDI, waiting }
private actor RuntimeSongProvider: SongReferenceProcessing {
    let source: URL
    let mode: RuntimeProviderMode
    private var separations = 0
    private var transcriptions = 0
    private var transcriptionStems: [[String]] = []
    init(source: URL, mode: RuntimeProviderMode) { self.source = source; self.mode = mode }
    func separate(preparedAudio: URL, into directory: URL, maximumScratchBytes: Int64) async throws -> ReferenceSeparation {
        separations += 1
        if mode == .waiting { try await Task.sleep(for: .seconds(60)) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var audio: [ReferenceArtifact] = []
        for name in ["vocals", "bass", "drums"] {
            let url = directory.appendingPathComponent("\(name).wav")
            if mode == .malformedAudio { try Data([0, 1, 2]).write(to: url) }
            else { try FileManager.default.copyItem(at: source, to: url) }
            audio.append(ReferenceArtifact(name: name, url: url))
        }
        return ReferenceSeparation(audio: audio, midi: [])
    }
    func transcribe(separation: ReferenceSeparation, into directory: URL, maximumScratchBytes: Int64) async throws -> [ReferenceArtifact] {
        transcriptions += 1
        transcriptionStems.append(separation.audio.map(\.name))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var midi: [ReferenceArtifact] = []
        let names: [String]
        if mode == .allMelodicMIDI { names = separation.audio.filter { ["bass", "vocals"].contains($0.name) }.map(\.name) }
        else if mode == .unauthorizedVocalMIDI { names = ["vocals"] }
        else { names = mode == .malformedMIDI || mode == .validMIDI ? ["bass"] : [] }
        for name in names {
            let url = directory.appendingPathComponent("\(name).mid")
            var song = Song(); song.tempo = 120
            song.tracks = [Track(name: "Measured \(name)", instrumentID: "synth.bass", clips: [
                Clip(lengthBeats: 2, notes: [NoteEvent(pitch: name == "vocals" ? 72 : 48, startBeat: 0.5, duration: 1, velocity: 90)])
            ])]
            let data = mode == .malformedMIDI ? Data("MThd".utf8) : try MIDIExporter.data(for: song)
            try data.write(to: url); midi.append(ReferenceArtifact(name: name, url: url))
        }
        return midi
    }
    func calls() -> Int { separations }
    func transcriptionCalls() -> Int { transcriptions }
    func requestedStems() -> [[String]] { transcriptionStems }
}
private struct RuntimeNeverInspector: ReferenceAudioInspecting {
    func inspect(audio: URL, question: String, budget: GenerationBudget) async throws -> String {
        throw ReferenceProcessingFailure("This local runtime test must never upload audio.")
    }
}
private actor RuntimeMetadataUpdates {
    var values = 0
    let reject: Bool
    init(reject: Bool = false) { self.reject = reject }
    func record(_ id: UUID, _ analysis: JSONValue?, _ midi: MIDIImport?) throws {
        values += 1
        if reject { throw ProjectError("Fixture metadata cannot be saved") }
    }
    func count() -> Int { values }
}

private struct ReferenceRuntimeFixture: Sendable {
    let directory: URL
    let source: URL
    let attachment: SongAttachment
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReferenceRuntimeTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("original.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = Float(sin(Double(index) * 2 * .pi * 220 / 16_000) * 0.1) }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        attachment = SongAttachment(fileName: "original.wav", duration: 1, sampleRate: 16_000, channels: 1,
            byteCount: try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!, sha256: try SongAttachmentLimits.sha256(file: source))
    }
    func runtime(mode: RuntimeProviderMode = .audioOnly, prompt: String = "", updates: RuntimeMetadataUpdates = RuntimeMetadataUpdates()) -> (SongReferenceRuntime, RuntimeSongProvider) {
        let provider = RuntimeSongProvider(source: source, mode: mode)
        let processing = ReferenceProcessing(provider: provider, directory: directory.appendingPathComponent("processing")) { source, _ in source }
        let runtime = SongReferenceRuntime(attachments: [attachment], sources: [attachment.id: source],
            directory: directory.appendingPathComponent("draft"), budget: GenerationBudget(), processor: { processing },
            inspector: RuntimeNeverInspector(), lease: nil, vocalNotesUserPrompt: prompt, update: { try await updates.record($0, $1, $2) }, status: { _, _ in })
        return (runtime, provider)
    }
    func inspect(_ detail: String) -> JSONValue {
        .object(["attachment_id": .string(attachment.id.uuidString), "detail": .string(detail),
                 "part_id": .null, "start_index": .null, "count": .null])
    }
    func insertion(stem: String = "source", beat: Double = 4) -> JSONValue {
        .object(["attachment_id": .string(attachment.id.uuidString), "stem": .string(stem),
                 "stem_names": stem == "mix" ? .array([.string("bass"), .string("drums")]) : .null,
                 "track_name": .string("Attached audio"), "source_start_seconds": .number(0.2), "source_end_seconds": .number(0.8),
                 "start_beat": .number(beat), "source_tempo": .null, "target_tempo": .null,
                 "fade_in_beats": .number(0.2), "fade_out_beats": .number(0.2), "target_track_id": .null])
    }
}

struct ReferenceRuntimeTests {
    private func noteInsertion(_ fixture: ReferenceRuntimeFixture, partID: String) -> JSONValue {
        .object(["attachment_id": .string(fixture.attachment.id.uuidString), "part_id": .string(partID),
            "instrument_id": .string("synth.lead"), "track_name": .string("Measured melody"),
            "source_start_seconds": .number(0), "source_end_seconds": .number(1), "start_beat": .number(0),
            "target_track_id": .null, "include_vocals": .bool(true)]) // A model flag cannot authorize conversion.
    }

    @Test func defaultMIDIExcludesVocalsAndExplicitCurrentRequestCanInsertThem() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (normal, provider) = fixture.runtime(mode: .allMelodicMIDI, prompt: "Replicate the song closely. Keep vocals as audio.")
        let result = try await normal.tools().execute("inspect_reference", fixture.inspect("midi"), Song())
        let parts = try #require(result.output["parts"]?.arrayValue)
        #expect(parts.count == 1 && parts[0]["source_stem"] == .string("bass"))
        #expect(await provider.requestedStems() == [["bass"]])
        #expect(!normal.tools().allowsVocalNoteConversion)
        await #expect(throws: AgentError.self) {
            _ = try await normal.tools().execute("insert_reference_notes", noteInsertion(fixture, partID: "vocals:1:0:0"), Song())
        }
        let (authorized, explicitProvider) = fixture.runtime(mode: .allMelodicMIDI, prompt: "Please convert the vocals into instrument notes.")
        let explicit = try await authorized.tools().execute("inspect_reference", fixture.inspect("midi"), Song())
        let vocal = try #require(explicit.output["parts"]?.arrayValue?.first { $0["source_stem"] == .string("vocals") })
        #expect(authorized.tools().allowsVocalNoteConversion)
        #expect(await explicitProvider.requestedStems() == [["vocals", "bass"]])
        let insertion = try await authorized.tools().execute("insert_reference_notes", noteInsertion(fixture, partID: #require(vocal["part_id"]?.stringValue)), Song())
        var song = Song(); try ProjectEditor.apply(insertion.commands, to: &song)
        #expect(song.tracks.first?.clips.first?.notes.map(\.pitch) == [72])
    }

    @Test func unauthorizedProviderVocalMIDICannotEnterCacheOrDraft() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (runtime, provider) = fixture.runtime(mode: .unauthorizedVocalMIDI)
        for _ in 0..<2 {
            await #expect(throws: ReferenceProcessingFailure.self) {
                _ = try await runtime.tools().execute("inspect_reference", fixture.inspect("midi"), Song())
            }
        }
        #expect(await provider.transcriptionCalls() == 1)
        #expect(await runtime.scores[fixture.attachment.id] == nil)
    }

    @Test func savedVocalAndLegacyScoresCannotBypassCurrentRequestPolicy() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var attachment = fixture.attachment
        attachment.midi = MIDIImport(parts: [
            .init(id: "saved-bass", name: "Bass", channel: 0, program: 0, isPercussion: false,
                  notes: [.init(pitch: 48, startSeconds: 0, durationSeconds: 1, velocity: 80)], referenceStem: "bass"),
            .init(id: "saved-vocals", name: "Vocals", channel: 0, program: 0, isPercussion: false,
                  notes: [.init(pitch: 72, startSeconds: 0, durationSeconds: 1, velocity: 80)], referenceStem: "vocals")
        ], duration: 1, initialTempo: 120)
        let provider = RuntimeSongProvider(source: fixture.source, mode: .validMIDI)
        let processing = ReferenceProcessing(provider: provider, directory: fixture.directory.appendingPathComponent("saved-processing"))
        func runtime(_ attachment: SongAttachment) -> SongReferenceRuntime {
            SongReferenceRuntime(attachments: [attachment], sources: [attachment.id: fixture.source],
                directory: fixture.directory.appendingPathComponent("saved-draft"), budget: GenerationBudget(), processor: { processing },
                inspector: RuntimeNeverInspector(), lease: nil, update: { _, _, _ in }, status: { _, _ in })
        }
        let saved = runtime(attachment)
        let summary = try await saved.tools().execute("inspect_reference", fixture.inspect("midi"), Song())
        #expect(summary.output["parts"]?.arrayValue?.map { $0["source_stem"] } == [.string("bass")])
        await #expect(throws: AgentError.self) {
            _ = try await saved.tools().execute("insert_reference_notes", noteInsertion(fixture, partID: "saved-vocals"), Song())
        }
        #expect(await provider.transcriptionCalls() == 0)
        attachment.midi?.parts[0].referenceStem = nil
        let legacy = runtime(attachment)
        let refreshed = try await legacy.tools().execute("inspect_reference", fixture.inspect("midi"), Song())
        #expect(refreshed.output["parts"]?.arrayValue?.first?["part_id"] != .string("saved-bass"))
        #expect(refreshed.output["parts"]?.arrayValue?.count == 1)
        #expect(await provider.transcriptionCalls() == 1)
    }

    @Test func reopenedScoreStillComparesCurrentInstalledSounds() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var attachment = fixture.attachment
        attachment.reconstruction = ReferenceReconstruction(sourceStartSeconds: 0, sourceEndSeconds: 1,
            parts: [.init(id: "bass", role: "bass", name: "Bass", notes: [
                .init(pitch: 57, startSeconds: 0.2, durationSeconds: 0.4, velocity: 80)
            ], relativeGain: 1)])
        let provider = RuntimeSongProvider(source: fixture.source, mode: .audioOnly)
        let processing = ReferenceProcessing(provider: provider, directory: fixture.directory.appendingPathComponent("processing"))
        let resourceRequests = RuntimeMetadataUpdates()
        let runtime = SongReferenceRuntime(attachments: [attachment], sources: [attachment.id: fixture.source],
            directory: fixture.directory.appendingPathComponent("draft"), budget: GenerationBudget(), processor: { processing },
            inspector: RuntimeNeverInspector(), lease: nil, update: { _, _, _ in }, fittingResources: {
                try await resourceRequests.record(fixture.attachment.id, nil, nil)
                return .empty
            }, status: { _, _ in })
        let first = try await runtime.tools().execute("inspect_reference", fixture.inspect("reconstruction"), Song())
        let second = try await runtime.tools().execute("inspect_reference", fixture.inspect("reconstruction"), Song())
        let comparison = try #require(first.output["parts"]?.arrayValue?.first?["sound_comparison"])
        #expect(comparison["instrumentID"] == .string("synth.bass"))
        #expect((comparison["testedCandidates"]?.doubleValue ?? 0) > 0)
        #expect(first.output == second.output)
        #expect(await provider.calls() == 1) // Reuse temporary stems without retranscribing the saved score.
        #expect(await resourceRequests.count() == 1)
    }

    private func reconstructionArguments(_ fixture: ReferenceRuntimeFixture, replacing: UUID, end: Double = 1) -> JSONValue {
        .object(["attachment_id": .string(fixture.attachment.id.uuidString), "source_start_seconds": .number(0),
            "source_end_seconds": .number(end), "start_beat": .number(4),
            "replace_track_ids": .array([.string(replacing.uuidString)]),
            "parts": .array([.object(["part_id": .string("bass"), "instrument_id": .string("synth.bass"),
                "parameters": .array([.object(["id": .string("oscillator"), "value": .number(0)]),
                    .object(["id": .string("lfoDepth"), "value": .number(0)])]),
                "volume": .number(0.3), "pan": .number(0)])])])
    }

    @Test func cleanedSavedProfileOverridesLegacyMIDIAndReplacesOnlyExplicitTracks() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var attachment = fixture.attachment
        attachment.midi = MIDIImport(parts: [.init(id: "legacy", name: "Raw artifact", channel: 0, program: 0,
            isPercussion: false, notes: [.init(pitch: 72, startSeconds: 0, durationSeconds: 1, velocity: 120)])], duration: 1, initialTempo: 120)
        attachment.reconstruction = ReferenceReconstruction(sourceStartSeconds: 0, sourceEndSeconds: 1,
            parts: [.init(id: "bass", role: "bass", name: "Measured bass", notes: [
                .init(pitch: 43, startSeconds: 0.25, durationSeconds: 0.5, velocity: 70)
            ], relativeGain: 0.5)])
        let runtime = SongReferenceRuntime(attachments: [attachment], sources: [attachment.id: fixture.source],
            directory: fixture.directory.appendingPathComponent("draft"), budget: GenerationBudget(),
            processor: { throw ReferenceProcessingFailure("A current saved profile needs no model work") },
            inspector: RuntimeNeverInspector(), lease: nil, update: { _, _, _ in }, status: { _, _ in })
        var song = Song(); song.tempo = 120
        let old = Track(name: "Old guess", instrumentID: "synth.pad")
        let retained = Track(name: "Keep", instrumentID: "synth.lead")
        song.tracks = [old, retained]
        let result = try await runtime.tools().execute("reconstruct_reference", reconstructionArguments(fixture, replacing: old.id), song)
        #expect(!song.tracks[0].isMuted && song.tracks.count == 2)
        try ProjectEditor.apply(result.commands, to: &song)
        #expect(song.tracks[0].isMuted && !song.tracks[1].isMuted)
        let added = try #require(song.tracks.last), clip = try #require(added.clips.first)
        #expect(clip.notes.count == 1 && clip.notes[0].pitch == 43)
        #expect(clip.notes[0].startBeat == 0.5 && clip.notes[0].duration == 1)
        #expect(added.parameters["lfoDepth"] == 0)
        #expect(clip.referenceReconstruction?.profile == ReferenceReconstruction.currentProfile)
    }

    @Test(arguments: ["partial", "local-reconstruction-v1", "local-reconstruction-v2", "local-reconstruction-v3"])
    func savedMeasurementsRequireMatchingRangeAndCurrentProfile(staleCase: String) async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var attachment = fixture.attachment
        attachment.reconstruction = ReferenceReconstruction(profile: staleCase == "partial" ? ReferenceReconstruction.currentProfile : staleCase,
            sourceStartSeconds: 0, sourceEndSeconds: staleCase == "partial" ? 0.5 : 1,
            parts: [.init(id: "bass", role: "bass", name: "Bass", notes: [
                .init(pitch: 43, startSeconds: 0.1, durationSeconds: 0.2, velocity: 80)
            ], relativeGain: 1)])
        let runtime = SongReferenceRuntime(attachments: [attachment], sources: [attachment.id: fixture.source],
            directory: fixture.directory.appendingPathComponent("draft"), budget: GenerationBudget(),
            processor: { throw ReferenceProcessingFailure("Models intentionally unavailable") },
            inspector: RuntimeNeverInspector(), lease: nil, update: { _, _, _ in }, status: { _, _ in })
        var song = Song(); let old = Track(); song.tracks = [old]
        await #expect(throws: ReferenceProcessingFailure.self) {
            _ = try await runtime.tools().execute("reconstruct_reference", reconstructionArguments(fixture, replacing: old.id), song)
        }
        #expect(!song.tracks[0].isMuted && song.tracks.count == 1)
    }

    @Test func rhythmAnalysisNeedsNoModelsAndRejectsLegacyCloudAnalysis() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var attachment = fixture.attachment
        attachment.analysis = .object(["description": .string("Legacy cloud description")])
        let updates = RuntimeMetadataUpdates()
        let runtime = SongReferenceRuntime(attachments: [attachment], sources: [attachment.id: fixture.source],
            directory: fixture.directory.appendingPathComponent("draft"), budget: GenerationBudget(),
            processor: { throw ReferenceProcessingFailure("Models are intentionally unavailable") },
            inspector: RuntimeNeverInspector(), lease: nil,
            update: { try await updates.record($0, $1, $2) }, status: { _, _ in })
        let first = try await runtime.tools().execute("inspect_reference", fixture.inspect("analysis"), Song())
        let cached = try await runtime.tools().execute("inspect_reference", fixture.inspect("analysis"), Song())
        #expect(first.output["analysis_engine"] == .string("local-rhythm-v1"))
        #expect(first.output["description"] == nil)
        #expect(cached.output == first.output)
        #expect(await updates.count() == 1)
        #expect(!runtime.tools().allowsAudioInspection)
    }

    @Test func stemsDoNotTranscribeAndSavedNotePagesDoNotRepeatInference() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (runtime, provider) = fixture.runtime(mode: .validMIDI)
        _ = try await runtime.tools().execute("inspect_reference", fixture.inspect("stems"), Song())
        #expect(await provider.transcriptionCalls() == 0)
        await #expect(throws: AgentError.self) {
            _ = try await runtime.tools().execute("inspect_reference", fixture.inspect("notes"), Song())
        }
        let midi = try await runtime.tools().execute("inspect_reference", fixture.inspect("midi"), Song())
        let parts = try await runtime.tools().execute("inspect_reference", fixture.inspect("notes"), Song())
        #expect(midi.output["midi_available"] == .bool(true))
        #expect(parts.output["parts"] == midi.output["parts"])
        #expect(await provider.calls() == 1)
        #expect(await provider.transcriptionCalls() == 1)
    }

    @Test func audioStemsRemainDiscoverableWhenNoMIDIWasReturned() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (runtime, provider) = fixture.runtime()
        let result = try await runtime.tools().execute("inspect_reference", fixture.inspect("stems"), Song())
        #expect(result.commands.isEmpty)
        #expect(result.output["audio_stems"] == .array([.string("vocals"), .string("bass"), .string("drums")]))
        #expect(result.output["midi_available"] == .bool(false))
        #expect(result.output["parts"] == .array([]))
        #expect(await provider.calls() == 1)
        #expect(await provider.transcriptionCalls() == 0)
        let serialized = String(decoding: try JSONEncoder().encode(result.output), as: UTF8.self)
        #expect(!serialized.contains(fixture.directory.path))
        #expect(try SongAttachmentLimits.sha256(file: fixture.source) == fixture.attachment.sha256)
    }

    @Test func invalidProviderAudioAndMIDIStopAsDependencyFailures() async throws {
        for mode in [RuntimeProviderMode.malformedAudio, .malformedMIDI] {
            let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let (runtime, provider) = fixture.runtime(mode: mode)
            for _ in 0..<2 {
                await #expect(throws: ReferenceProcessingFailure.self) {
                    _ = try await runtime.tools().execute("inspect_reference", fixture.inspect(mode == .malformedAudio ? "stems" : "midi"), Song())
                }
            }
            #expect(await provider.calls() == 1) // Invalid output never restarts local separation.
            #expect(await runtime.assets(for: Song()).isEmpty)
            #expect(try SongAttachmentLimits.sha256(file: fixture.source) == fixture.attachment.sha256)
        }
    }

    @Test func requiredMetadataFailurePreventsSuccessfulReferenceInsertion() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let updates = RuntimeMetadataUpdates(reject: true)
        let (runtime, provider) = fixture.runtime(mode: .validMIDI, updates: updates)
        await #expect(throws: ReferenceProcessingFailure.self) {
            _ = try await runtime.tools().execute("inspect_reference", fixture.inspect("midi"), Song())
        }
        #expect(await updates.count() == 1)
        #expect(await runtime.scores[fixture.attachment.id] == nil)
        #expect(await provider.calls() == 1)
        #expect(await runtime.assets(for: Song()).isEmpty)
    }

    @Test func originalAudioProducesEditableFadedClipsAndReusesOneStagedAsset() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (runtime, provider) = fixture.runtime()
        var song = Song(); song.tempo = 120
        let first = try await runtime.tools().execute("insert_reference_audio", fixture.insertion(), song)
        #expect(song.tracks.isEmpty && song.assets.isEmpty)
        try ProjectEditor.apply(first.commands, to: &song)
        let firstAsset = try #require(song.assets.first), firstClip = try #require(song.tracks.first?.clips.first)
        #expect(firstClip.kind == .audio && song.tracks.first?.kind == .audio)
        #expect(firstClip.startBeat == 4)
        #expect(abs(firstClip.lengthBeats - 1.2) < 0.001)
        #expect(firstClip.fadeInBeats == 0.2 && firstClip.fadeOutBeats == 0.2)
        #expect(firstClip.referenceAttachmentID == fixture.attachment.id)
        #expect(firstAsset.referenceDerivation?.attachmentID == fixture.attachment.id)
        #expect(firstAsset.referenceDerivation?.sourceStartSeconds == 0.2)
        #expect(firstAsset.referenceDerivation?.sourceEndSeconds == 0.8)
        let second = try await runtime.tools().execute("insert_reference_audio", fixture.insertion(beat: 8), song)
        try ProjectEditor.apply(second.commands, to: &song)
        #expect(song.assets.count == 1)
        #expect(song.tracks.flatMap(\.clips).allSatisfy { $0.assetID == firstAsset.id })
        let files = await runtime.tools().assets(song)
        #expect(files.count == 1)
        let output = try #require(files[firstAsset.id])
        let audio = try AVAudioFile(forReading: output)
        #expect(audio.processingFormat.channelCount == 2 && audio.processingFormat.sampleRate == 48_000)
        #expect(abs(Double(audio.length) / 48_000 - 0.6) < 0.001)
        #expect(await provider.calls() == 0) // Original audio needs no cloud processing.
        let savedSong = song
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.tools().execute("inspect_reference", fixture.inspect("metadata"), savedSong)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try SongAttachmentLimits.sha256(file: fixture.source) == fixture.attachment.sha256)
    }

    @Test func selectedStemMixIsOneEditableAudioLayerWithSourceProvenance() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (runtime, provider) = fixture.runtime()
        var song = Song(); song.tempo = 120
        let result = try await runtime.tools().execute("insert_reference_audio", fixture.insertion(stem: "mix"), song)
        try ProjectEditor.apply(result.commands, to: &song)
        #expect(song.tracks.count == 1 && song.assets.count == 1)
        let clip = try #require(song.tracks.first?.clips.first), asset = try #require(song.assets.first)
        #expect(clip.kind == .audio && clip.fadeInBeats == 0.2 && clip.fadeOutBeats == 0.2)
        #expect(asset.referenceDerivation?.attachmentID == fixture.attachment.id)
        #expect(abs(asset.duration - 0.6) < 0.001)
        let files = await runtime.tools().assets(song)
        #expect(files.count == 1)
        let file = try AVAudioFile(forReading: #require(files[asset.id]))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channel[$1])) }
        #expect(peak > 0.19 && peak < 0.21) // Exactly two 0.1-amplitude stems; vocals excluded.
        #expect(await provider.calls() == 1)
        #expect(try SongAttachmentLimits.sha256(file: fixture.source) == fixture.attachment.sha256)
    }

    @Test func cancellationDuringProviderWorkRetainsOriginalAndReturnsNoCommands() async throws {
        let fixture = try ReferenceRuntimeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (runtime, provider) = fixture.runtime(mode: .waiting)
        let task = Task { try await runtime.tools().execute("inspect_reference", fixture.inspect("stems"), Song()) }
        for _ in 0..<1000 {
            if await provider.calls() == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await provider.calls() == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await runtime.assets(for: Song()).isEmpty)
        #expect(try SongAttachmentLimits.sha256(file: fixture.source) == fixture.attachment.sha256)
    }
}
