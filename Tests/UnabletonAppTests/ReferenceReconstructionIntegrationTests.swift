import Foundation
import Testing
@preconcurrency import AVFAudio
import UnabletonCore
import UnabletonAudio
import UnabletonLibrary

/// Explicit local acceptance harness. It neither downloads models nor calls a provider.
/// Outputs are retained for inspection, so every run requires a fresh output directory.
struct ReferenceReconstructionIntegrationTests {
    @Test(.enabled(if: ["UNABLETON_RECONSTRUCTION_FIXTURE", "UNABLETON_REFERENCE_PROJECT", "UNABLETON_RECONSTRUCTION_OUTPUT"]
        .allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }))
    func realMeasuredPartsProduceAnEditablePackageAndProductionWAV() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureURL = URL(fileURLWithPath: try #require(environment["UNABLETON_RECONSTRUCTION_FIXTURE"]))
        let sourceProjectURL = URL(fileURLWithPath: try #require(environment["UNABLETON_REFERENCE_PROJECT"]), isDirectory: true)
        let output = URL(fileURLWithPath: try #require(environment["UNABLETON_RECONSTRUCTION_OUTPUT"]), isDirectory: true).standardizedFileURL
        let sourcePath = sourceProjectURL.resolvingSymlinksInPath().path
        let outputPath = output.resolvingSymlinksInPath().path
        guard !FileManager.default.fileExists(atPath: output.path), outputPath != sourcePath,
              !outputPath.hasPrefix(sourcePath + "/") else {
            throw ProjectError("Use a fresh reconstruction output directory outside the original project.")
        }
        let values = try fixtureURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize,
              bytes > 0, bytes <= SongAttachmentLimits.maximumMetadataBytes else {
            throw ProjectError("Choose a bounded reconstruction JSON fixture.")
        }
        let measured = try JSONDecoder().decode(ReferenceReconstruction.self, from: Data(contentsOf: fixtureURL))
        try measured.validate()
        let store = try ProjectBlobStore()
        let original = try ProjectArchive.decodeFiles(FileWrapper(url: sourceProjectURL, options: .immediate), into: store)
        let candidates = (original.project.attachments ?? []).filter { $0.duration + 0.001 >= measured.sourceEndSeconds }
        var attachment: SongAttachment
        if let rawID = environment["UNABLETON_REFERENCE_ATTACHMENT_ID"] {
            attachment = try #require(candidates.first(where: { $0.id.uuidString.caseInsensitiveCompare(rawID) == .orderedSame }))
        } else {
            guard Set(candidates.map(\.sha256)).count == 1 else {
                throw ProjectError("Choose UNABLETON_REFERENCE_ATTACHMENT_ID when the project contains distinct candidate source songs.")
            }
            attachment = try #require(candidates.first)
        }
        try measured.validate(maximumDuration: attachment.duration)
        let sourceAudio = try #require(original.assets[attachment.id])
        #expect(try SongAttachmentLimits.sha256(file: sourceAudio) == attachment.sha256)
        let legacyMIDI = attachment.midi
        let previousSavedProfile = attachment.reconstruction?.profile
        attachment.reconstruction = measured

        var candidateIDs = Set(InstrumentCatalog.presets.filter { !$0.isSampler }.map(\.id))
        var installedBankIDs: [String] = []
        var resources = InstrumentResources.empty
        if environment["UNABLETON_USE_INSTALLED_LIBRARY"] == "1" {
            let library = SoundLibrary.shared
            let installed = await library.snapshot()
            installedBankIDs = installed.filter { $0.value.isInstalled }.map(\.key).sorted()
            candidateIDs = Set(InstrumentCatalog.presets.filter { preset in
                !preset.isSampler || preset.soundBankID.map { installed[$0]?.isInstalled == true } == true
            }.map(\.id))
            let lease = try await library.acquire(instrumentIDs: candidateIDs)
            resources = InstrumentResources(urls: lease.urls, owner: lease)
        }

        var song = Song()
        song.title = "Reference reconstruction"
        song.tempo = measured.tempo ?? original.project.song.tempo
        song.beatsPerBar = original.project.song.beatsPerBar
        song.key = original.project.song.key
        let sourceDuration = measured.sourceEndSeconds - measured.sourceStartSeconds
        song.lengthBars = max(1, Int(ceil(sourceDuration * song.tempo / 60 / Double(song.beatsPerBar))))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var fits: [String: ReferenceSoundFit] = [:]
        var fitGainShares: [String: Double] = [:]
        let reusedFits = try environment["UNABLETON_REFERENCE_REUSE_NONBASS_FITS"].map { path in
            try verifiedNonbassFits(directory: URL(fileURLWithPath: path, isDirectory: true),
                reconstruction: measured, sourceSHA256: attachment.sha256,
                candidateIDs: candidateIDs, installedBankIDs: installedBankIDs)
        } ?? [:]
        let fitDirectory = output.appendingPathComponent(".Sound fitting", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fitDirectory) }
        if let stemPath = environment["UNABLETON_REFERENCE_STEMS"] {
            for part in measured.parts {
                let stem = part.role == "accompaniment" ? "other" : part.role
                let source = URL(fileURLWithPath: stemPath, isDirectory: true).appendingPathComponent(stem + ".wav")
                let fit = try reusedFits[part.id] ?? ReferenceSoundMatcher.fit(part: part, sourceURL: source,
                    sourceStartSeconds: measured.sourceStartSeconds, sourceEndSeconds: measured.sourceEndSeconds,
                    directory: fitDirectory, resources: resources, candidateIDs: candidateIDs,
                    siblingParts: measured.parts)
                fits[part.id] = fit
                let shared = measured.parts.filter { $0.role == part.role }
                let relativeNorm = sqrt(shared.reduce(0) { $0 + $1.relativeGain * $1.relativeGain })
                let share = relativeNorm > 0 ? part.relativeGain / relativeNorm : 1 / sqrt(Double(shared.count))
                fitGainShares[part.id] = fit.gainBasis == nil ? share : 1
            }
        }
        let balancedVolumes = ReferenceSoundMatcher.balancedVolumes(parts: measured.parts, fits: fits)
        let selections = try measured.parts.map { part -> ReferenceReconstructionSelection in
            if let fit = fits[part.id] {
                return ReferenceReconstructionSelection(partID: part.id, instrumentID: fit.instrumentID,
                    parameters: fit.parameters, volume: try #require(balancedVolumes[part.id]), pan: 0)
            }
            let instrument = part.role == "drums" ? "drums.electronic" : part.role == "bass" ? "synth.bass" : "synth.pluck"
            let descriptors = InstrumentCatalog.parameters(for: instrument)
            let parameters = part.suggestedParameters.filter { key, value in
                descriptors.first(where: { $0.id == key })?.range.contains(value) == true
            }
            return ReferenceReconstructionSelection(partID: part.id, instrumentID: instrument,
                parameters: parameters, volume: 0.55 * part.relativeGain, pan: 0)
        }
        let selectionDetails = try selections.map { selection -> [String: Any] in
            var details: [String: Any] = ["partID": selection.partID, "instrumentID": selection.instrumentID,
                "parameters": selection.parameters, "volume": selection.volume, "pan": selection.pan]
            if let fit = fits[selection.partID] {
                details["soundFit"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fit))
            }
            return details
        }
        try JSONSerialization.data(withJSONObject: ["selections": selectionDetails,
            "candidateInstrumentIDs": candidateIDs.sorted(), "installedBankIDs": installedBankIDs], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("Selected sounds.json"), options: .atomic)
        let plan = try ReferenceReconstructionPlanner.plan(song: song, attachmentID: attachment.id,
            reconstruction: measured, startBeat: 0, selections: selections, replaceTrackIDs: [])
        try ProjectEditor.apply(plan.commands, to: &song)
        #expect(song.tracks.count == measured.parts.count)
        #expect(plan.noteCount == measured.parts.reduce(0) { $0 + $1.notes.count })
        for (track, part) in zip(song.tracks, measured.parts) {
            let clip = try #require(track.clips.first)
            #expect(clip.referenceReconstruction?.profile == ReferenceReconstruction.currentProfile)
            #expect(clip.notes.count == part.notes.count)
            for (note, event) in zip(clip.notes, part.notes) {
                #expect(note.pitch == event.pitch && note.velocity == event.velocity)
                #expect(abs(note.startBeat * 60 / song.tempo - (event.startSeconds - measured.sourceStartSeconds)) < 0.001)
                #expect(abs(note.duration * 60 / song.tempo - event.durationSeconds) < 0.001)
            }
        }

        var project = ProjectFile()
        project.song = song; project.attachments = [attachment]
        project.conversations[0].title = "Reference reconstruction"
        project.conversations[0].messages = [
            ChatMessage(role: "user", text: "Reconstruct the attached song with editable instruments.", attachmentIDs: [attachment.id]),
            ChatMessage(role: "assistant", text: "Created editable bass, accompaniment and drum parts from local source measurements. Instrument matches and note estimates can contain errors. Original vocals are excluded.")
        ]
        try ProjectArchive.validateMetadata(project)
        let packageURL = output.appendingPathComponent("Reference reconstruction.unableton", isDirectory: true)
        let package = try ProjectArchive.encode(project: project, blobURLs: [attachment.id: sourceAudio], lease: store.snapshot().lease)
        try package.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        let restored = try ProjectArchive.decode(FileWrapper(url: packageURL, options: .immediate))
        #expect(restored.project == project)
        #expect(restored.project.attachments?.first?.midi == legacyMIDI)
        #expect(restored.project.attachments?.first?.reconstruction == measured)
        #expect(SongAttachmentLimits.sha256(try #require(restored.assets[attachment.id])) == attachment.sha256)

        let audioURL = output.appendingPathComponent("Reference reconstruction.wav")
        let report = try OfflineRenderer.render(song: song, assets: [:], to: audioURL,
            lengthBeats: sourceDuration * song.tempo / 60, resources: resources)
        #expect(!report.silent)
        #expect(report.clippedSamples == 0)
        #expect(report.duration >= sourceDuration && report.duration <= sourceDuration + 10.001)
        let renderedFile = try AVAudioFile(forReading: audioURL)
        #expect(renderedFile.processingFormat.sampleRate == 48_000 && renderedFile.processingFormat.channelCount == 2)

        // Compare aligned instrumental excerpts independently of the chosen
        // sound score. These are acoustic measurements, not listening grades.
        var sourceRenderWindows: [[String: Any]] = []
        let baselineURL = environment["UNABLETON_REFERENCE_BASELINE_WAV"].map { URL(fileURLWithPath: $0) }
        if let baselineURL, baselineURL.resolvingSymlinksInPath() == audioURL.resolvingSymlinksInPath() {
            throw ProjectError("Choose an existing, separate baseline WAV for comparison.")
        }
        if let stemPath = environment["UNABLETON_REFERENCE_STEMS"] {
            let duration = min(4, sourceDuration)
            let relativeStarts = Set([0.0, max(0, (sourceDuration - duration) / 2), max(0, sourceDuration - duration)]).sorted()
            let stems = ["bass", "other", "drums"].map {
                URL(fileURLWithPath: stemPath, isDirectory: true).appendingPathComponent($0 + ".wav")
            }
            for relativeStart in relativeStarts {
                let sourceStart = measured.sourceStartSeconds + relativeStart
                let source = try windowEnvelope(stems, start: sourceStart, duration: duration)
                let rendered = try windowEnvelope([audioURL], start: relativeStart, duration: duration)
                let sourceLevel = rms(source), renderedLevel = rms(rendered)
                var comparison: [String: Any] = [
                    "sourceStartSeconds": sourceStart, "renderStartSeconds": relativeStart, "durationSeconds": duration,
                    "sourceInstrumentalRMS": sourceLevel, "renderRMS": renderedLevel,
                    "renderToSourceRMSRatio": sourceLevel > 1e-9 ? renderedLevel / sourceLevel as Any : NSNull(),
                    "levelEnvelopeCosine": cosine(source, rendered),
                    "onsetEnvelopeCosine": cosine(onsetEnvelope(source), onsetEnvelope(rendered)),
                    "measuredNoteOnsets": measured.parts.reduce(0) { count, part in
                        count + part.notes.filter { $0.startSeconds >= sourceStart && $0.startSeconds < sourceStart + duration }.count
                    }
                ]
                if let baselineURL {
                    let baseline = try windowEnvelope([baselineURL], start: relativeStart, duration: duration)
                    let baselineLevel = rms(baseline)
                    comparison["baselineRenderRMS"] = baselineLevel
                    comparison["baselineToSourceRMSRatio"] = sourceLevel > 1e-9 ? baselineLevel / sourceLevel as Any : NSNull()
                    comparison["baselineLevelEnvelopeCosine"] = cosine(source, baseline)
                    comparison["baselineOnsetEnvelopeCosine"] = cosine(onsetEnvelope(source), onsetEnvelope(baseline))
                }
                sourceRenderWindows.append(comparison)
            }
        }

        var partReports: [[String: Any]] = []
        for (part, track) in zip(measured.parts, song.tracks) {
            var item: [String: Any] = ["id": part.id, "role": part.role, "noteCount": part.notes.count,
                "instrumentID": track.instrumentID, "volume": track.volume, "relativeGain": part.relativeGain, "parameters": track.parameters,
                "firstNoteSourceSeconds": part.notes[0].startSeconds,
                "lastNoteEndSourceSeconds": part.notes.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0]
            if let fit = fits[part.id] {
                item["soundFit"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fit))
                item["sharedStemGainShare"] = fitGainShares[part.id]
                item["appliedVolume"] = track.volume
            }
            if part.role == "bass" {
                var isolated = song; isolated.tracks = [track]
                let firstDuration = min(10, sourceDuration)
                let bassURL = output.appendingPathComponent("Bass verification.wav")
                _ = try OfflineRenderer.render(song: isolated, assets: [:], to: bassURL,
                    lengthBeats: firstDuration * song.tempo / 60, resources: resources)
                let level = try firstSecondsRMS(bassURL, duration: firstDuration)
                let earlyNotes = part.notes.filter { $0.startSeconds < measured.sourceStartSeconds + firstDuration }
                item["firstWindowSeconds"] = firstDuration
                item["firstWindowNoteCount"] = earlyNotes.count
                item["firstWindowRenderedRMS"] = level
                if earlyNotes.isEmpty { #expect(level < 0.00001) }
            }
            partReports.append(item)
        }
        var details: [String: Any] = ["profile": measured.profile, "sourceSHA256": attachment.sha256,
            "previousSavedProfile": previousSavedProfile ?? "none",
            "sourceStartSeconds": measured.sourceStartSeconds, "sourceEndSeconds": measured.sourceEndSeconds,
            "tempo": song.tempo, "tempoQuality": measured.tempoQuality,
            "fittingMode": fits.isEmpty ? "Local feature estimates only" : "Rendered spectral and envelope comparison",
            "candidateInstrumentIDs": candidateIDs.sorted(), "installedBankIDs": installedBankIDs,
            "sampledCandidateCount": InstrumentCatalog.presets.filter { $0.isSampler && candidateIDs.contains($0.id) }.count,
            "balancedVolumes": balancedVolumes,
            "reusedNonbassFitPartIDs": reusedFits.keys.sorted(),
            "relativeGainBasis": "New fits use attributed part energy directly; legacy whole-stem fits use L2 amplitude shares.",
            "sourceRenderWindows": sourceRenderWindows,
            "noteCount": plan.noteCount, "parts": partReports,
            "renderDuration": report.duration, "renderPeak": report.peak, "renderRMS": report.rms,
            "clippedSamples": report.clippedSamples, "warnings": measured.warnings,
            "qualityLimit": "Rendering and measurement checks do not establish listening quality or exact reconstruction."]
        if let baselineURL {
            details["baselineFileName"] = baselineURL.lastPathComponent
            details["baselineSHA256"] = try SongAttachmentLimits.sha256(file: baselineURL)
        }
        try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("Local reconstruction acceptance outputs: \(output.path)")
    }

    /// Explicit acceptance-only reuse avoids repeating unchanged nonbass
    /// comparisons when a bass candidate is added. The prior editable package
    /// proves the exact source identity, profile, ranges and measured notes.
    private func verifiedNonbassFits(directory: URL, reconstruction: ReferenceReconstruction,
                                    sourceSHA256: String, candidateIDs: Set<String>,
                                    installedBankIDs: [String]) throws -> [String: ReferenceSoundFit] {
        struct CachedSelection: Decodable {
            let partID: String
            let instrumentID: String
            let parameters: [String: Double]
            let soundFit: ReferenceSoundFit
        }
        struct CachedSelections: Decodable {
            let selections: [CachedSelection]
            let candidateInstrumentIDs: [String]
            let installedBankIDs: [String]
        }
        let selectedURL = directory.appendingPathComponent("Selected sounds.json")
        let values = try selectedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= SongAttachmentLimits.maximumMetadataBytes else {
            throw ProjectError("Choose a bounded selected-sounds report from a previous acceptance run.")
        }
        let cached = try JSONDecoder().decode(CachedSelections.self, from: Data(contentsOf: selectedURL))
        let packageURL = directory.appendingPathComponent("Reference reconstruction.unableton", isDirectory: true)
        let previous = try ProjectArchive.decode(FileWrapper(url: packageURL, options: .immediate))
        guard previous.project.attachments?.count == 1, let attachment = previous.project.attachments?.first,
              attachment.sha256 == sourceSHA256, attachment.reconstruction == reconstruction,
              let source = previous.assets[attachment.id], SongAttachmentLimits.sha256(source) == sourceSHA256,
              Set(cached.candidateInstrumentIDs) == candidateIDs,
              cached.installedBankIDs.sorted() == installedBankIDs.sorted(),
              Set(cached.selections.map(\.partID)) == Set(reconstruction.parts.map(\.id)),
              cached.selections.count == reconstruction.parts.count else {
            throw ProjectError("Reused fits must match the source hash, exact reconstruction and installed candidate set.")
        }
        var result: [String: ReferenceSoundFit] = [:]
        for part in reconstruction.parts where part.role != "bass" {
            let selection = try #require(cached.selections.first { $0.partID == part.id })
            let tracks = previous.project.song.tracks.filter { track in
                track.clips.contains { $0.referenceReconstruction?.partID == part.id }
            }
            let fit = selection.soundFit
            guard tracks.count == 1, let track = tracks.first,
                  selection.instrumentID == fit.instrumentID, selection.parameters == fit.parameters,
                  track.instrumentID == fit.instrumentID, track.parameters == fit.parameters,
                  candidateIDs.contains(fit.instrumentID), fit.testedCandidates > 0,
                  [fit.sourceGain, fit.volume, fit.spectralDistance, fit.envelopeDistance].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw ProjectError("A reused sound fit does not match its saved editable track.")
            }
            result[part.id] = fit
        }
        return result
    }

    /// Sum aligned source stems in PCM before measuring energy. Averaging
    /// separate stem energies would not measure the same instrumental mix.
    private func windowEnvelope(_ urls: [URL], start: Double, duration: Double) throws -> [Double] {
        let files = try urls.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        let first = try #require(files.first), rate = first.processingFormat.sampleRate
        let channels = Int(first.processingFormat.channelCount)
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 4.001,
              (8_000...192_000).contains(rate), (1...2).contains(channels),
              files.allSatisfy({ $0.processingFormat.sampleRate == rate && $0.processingFormat.channelCount == first.processingFormat.channelCount
                  && start + duration <= Double($0.length) / rate + 0.002 }) else {
            throw ProjectError("Comparison needs aligned mono/stereo PCM excerpts of at most four seconds.")
        }
        let frames = Int((duration * rate).rounded())
        var mix = Array(repeating: Array(repeating: 0.0, count: frames), count: channels)
        for file in files {
            file.framePosition = AVAudioFramePosition((start * rate).rounded())
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            var read = 0
            while read < frames {
                try Task<Never, Never>.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, frames - read)))
                guard buffer.frameLength > 0, let source = buffer.floatChannelData else { break }
                for channel in 0..<channels {
                    for frame in 0..<Int(buffer.frameLength) {
                        let value = Double(source[channel][frame])
                        guard value.isFinite else { throw ProjectError("Invalid sample in the comparison excerpt.") }
                        mix[channel][read + frame] += value
                    }
                }
                read += Int(buffer.frameLength)
            }
        }
        let buckets = max(1, Int(ceil(duration / 0.02)))
        var energy = Array(repeating: 0.0, count: buckets), counts = Array(repeating: 0, count: buckets)
        for frame in 0..<frames {
            let bucket = min(buckets - 1, Int(Double(frame) / rate / 0.02))
            for channel in 0..<channels { energy[bucket] += mix[channel][frame] * mix[channel][frame] }
            counts[bucket] += channels
        }
        return zip(energy, counts).map { sqrt($0 / Double(max(1, $1))) }
    }

    private func rms(_ values: [Double]) -> Double {
        sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(max(1, values.count)))
    }

    private func onsetEnvelope(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        return values.indices.map { index in index == 0 ? 0 : max(0, values[index] - values[index - 1]) }
    }

    private func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let a = lhs.reduce(0) { $0 + $1 * $1 }, b = rhs.reduce(0) { $0 + $1 * $1 }
        if a < 1e-18 && b < 1e-18 { return 1 }
        guard a > 1e-18, b > 1e-18 else { return 0 }
        return min(1, max(0, zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 } / sqrt(a * b)))
    }

    private func firstSecondsRMS(_ url: URL, duration: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let target = min(file.length, AVAudioFramePosition((duration * file.processingFormat.sampleRate).rounded()))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var read: AVAudioFramePosition = 0, squares = 0.0, samples = 0
        while read < target {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, target - read)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw ProjectError("The verification render contains no readable samples.") }
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][frame]); squares += value * value; samples += 1
                }
            }
            read += AVAudioFramePosition(buffer.frameLength)
        }
        return sqrt(squares / Double(max(1, samples)))
    }
}
