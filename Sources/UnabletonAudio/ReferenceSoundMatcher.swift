import Foundation
@preconcurrency import AVFAudio
import UnabletonCore
import Accelerate

public struct ReferenceSoundExcerpt: Codable, Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let preRollSeconds: Double
    public let warmupTruncated: Bool
}

/// Distances compare measured bands and envelopes, not perceived sound quality.
public struct ReferenceSoundFit: Codable, Sendable, Equatable {
    public let instrumentID: String
    public let parameters: [String: Double]
    /// Uncapped amplitude gain. New measurements use this part's independent
    /// fundamental envelope (or drum-class bands), rather than a shared stem's
    /// total energy. Older saved fits retain their original whole-stem basis.
    public let sourceGain: Double
    public let volume: Double
    public let spectralDistance: Double
    public let envelopeDistance: Double
    public let testedCandidates: Int
    public let articulationDistance: Double?
    public let excerpts: [ReferenceSoundExcerpt]?
    /// Nil identifies legacy whole-stem gain, which still needs amplitude shares.
    public let gainBasis: String?

    public init(instrumentID: String, parameters: [String: Double], sourceGain: Double, volume: Double,
                spectralDistance: Double, envelopeDistance: Double, testedCandidates: Int,
                articulationDistance: Double? = nil, excerpts: [ReferenceSoundExcerpt]? = nil,
                gainBasis: String? = nil) {
        self.instrumentID = instrumentID; self.parameters = parameters; self.sourceGain = sourceGain
        self.volume = volume; self.spectralDistance = spectralDistance
        self.envelopeDistance = envelopeDistance; self.testedCandidates = testedCandidates
        self.articulationDistance = articulationDistance; self.excerpts = excerpts
        self.gainBasis = gainBasis
    }
}

/// Auditions real installed instruments locally. The caller still chooses which
/// recommendation to apply through the ordinary reconstruction command path.
public enum ReferenceSoundMatcher {
    private struct Candidate {
        let instrumentID: String
        let parameters: [String: Double]
    }
    private struct SamplerAuditionFailure: Error { let instrumentID: String }
    private struct Features {
        let spectrum: [Double]
        let harmonics: [Double]
        let envelope: [Double]
        let articulation: [Double]
        let rms: Double
    }
    private struct Excerpt {
        let start: Double
        let end: Double
        let renderStart: Double
        let truncated: Bool
        var duration: Double { end - start }
    }
    private struct Match {
        let candidate: Candidate
        let gain: Double
        let spectral: Double
        let envelope: Double
        let articulation: Double
        let score: Double
    }

    public static func fit(part: ReferenceReconstructionPart, sourceURL: URL,
                           sourceStartSeconds: Double, sourceEndSeconds: Double,
                           directory: URL, resources: InstrumentResources = .empty,
                           candidateIDs: Set<String>? = nil,
                           siblingParts: [ReferenceReconstructionPart] = []) throws -> ReferenceSoundFit {
        let measurement = ReferenceReconstruction(sourceStartSeconds: sourceStartSeconds,
            sourceEndSeconds: sourceEndSeconds, parts: [part])
        try measurement.validate()
        let context = siblingParts.filter { $0.id != part.id && $0.role == part.role }
        try ReferenceReconstruction(sourceStartSeconds: sourceStartSeconds,
            sourceEndSeconds: sourceEndSeconds, parts: [part] + context).validate()
        try Task<Never, Never>.checkCancellation()
        let excerpts = representativeExcerpts(part: part, start: sourceStartSeconds, end: sourceEndSeconds)
        let candidates = try candidates(for: part, resources: resources, requested: candidateIDs)
        let targets = try excerpts.map { excerpt in
            try features(sourceURL, start: excerpt.start, duration: excerpt.duration,
                part: part, eventOffset: excerpt.start, siblings: context)
        }
        guard targets.contains(where: { $0.rms > 0.00001 }) else {
            throw AudioError.render("The measured source range is too quiet to fit an instrument.")
        }
        let owned = directory.appendingPathComponent("SoundFit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: owned) }
        // Every patch first renders an attack-anchored excerpt. The shortlist
        // then has to generalize to the other source sections and releases.
        var coarse: [Match] = []
        let first = excerpts[0]
        let coarseExcerpt = Excerpt(start: first.start, end: min(first.end, first.start + 2),
            renderStart: first.renderStart, truncated: first.truncated)
        let coarseTarget = try features(sourceURL, start: coarseExcerpt.start, duration: coarseExcerpt.duration,
            part: part, eventOffset: coarseExcerpt.start, siblings: context)
        for (index, candidate) in candidates.enumerated() {
            try Task<Never, Never>.checkCancellation()
            if let match = try evaluate(candidate, part: part, excerpts: [coarseExcerpt], targets: [coarseTarget],
                resources: resources, siblings: context, directory: owned, identifier: "Coarse-\(index)") { coarse.append(match) }
        }
        guard !coarse.isEmpty else {
            throw AudioError.render("None of the supplied compatible sounds could be rendered for this source part. Check their installation or choose another explicit candidate.")
        }
        coarse.sort { $0.score < $1.score }
        var finalists: [Match] = []
        var counts: [String: Int] = [:]
        // Do not let near-identical variants of one sample crowd out every
        // other instrument before the sustained/release excerpts are measured.
        for match in coarse where counts[match.candidate.instrumentID, default: 0] < 2 {
            guard finalists.count < 4 else { break }
            finalists.append(match); counts[match.candidate.instrumentID, default: 0] += 1
        }
        if finalists.count < min(4, coarse.count) {
            let keys = Set(finalists.map { candidateKey($0.candidate) })
            finalists += coarse.filter { !keys.contains(candidateKey($0.candidate)) }.prefix(4 - finalists.count)
        }
        var best: Match?
        for (index, candidate) in finalists.enumerated() {
            if let match = try evaluate(candidate.candidate, part: part, excerpts: excerpts, targets: targets,
                resources: resources, siblings: context, directory: owned, identifier: "Final-\(index)"),
               best == nil || match.score < best!.score { best = match }
        }
        guard let best else { throw AudioError.render("The shortlisted sounds could not be compared across the source passages.") }
        var chosen = best
        var tested = coarse.count
        if best.score > 0.015, candidates.count < 36 {
            let used = Set(coarse.map { candidateKey($0.candidate) })
            let variations = refinements(best.candidate).filter { !used.contains(candidateKey($0)) }.prefix(36 - candidates.count)
            var refined: [Match] = []
            for (index, candidate) in variations.enumerated() {
                if let match = try evaluate(candidate, part: part, excerpts: [coarseExcerpt], targets: [coarseTarget],
                    resources: resources, siblings: context, directory: owned, identifier: "Refine-\(index)") {
                    refined.append(match); tested += 1
                }
            }
            // Only the two most promising local controls receive the complete
            // multi-passage comparison. A better attack alone cannot win.
            for (index, candidate) in refined.sorted(by: { $0.score < $1.score }).prefix(2).enumerated() {
                if let match = try evaluate(candidate.candidate, part: part, excerpts: excerpts, targets: targets,
                    resources: resources, siblings: context, directory: owned, identifier: "Refined-final-\(index)"), match.score < chosen.score {
                    chosen = match
                }
            }
        }
        return ReferenceSoundFit(instrumentID: chosen.candidate.instrumentID, parameters: chosen.candidate.parameters,
            sourceGain: chosen.gain, volume: min(1.5, chosen.gain), spectralDistance: chosen.spectral,
            envelopeDistance: chosen.envelope, testedCandidates: tested,
            articulationDistance: chosen.articulation,
            excerpts: excerpts.map { .init(startSeconds: $0.start, endSeconds: $0.end,
                preRollSeconds: $0.start - $0.renderStart, warmupTruncated: $0.truncated) },
            gainBasis: "part-envelope-v1")
    }

    private static func evaluate(_ candidate: Candidate, part: ReferenceReconstructionPart,
                                 excerpts: [Excerpt], targets: [Features], resources: InstrumentResources,
                                 siblings: [ReferenceReconstructionPart], directory: URL, identifier: String) throws -> Match? {
        var spectral = 0.0, envelope = 0.0, articulation = 0.0, gains: [Double] = []
        for (index, excerpt) in excerpts.enumerated() {
            try Task<Never, Never>.checkCancellation()
            let url = directory.appendingPathComponent("\(identifier)-\(index).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let rendered = try autoreleasepool { () throws -> Features? in
                    let song = previewSong(part: part, candidate: candidate, start: excerpt.renderStart, end: excerpt.end)
                    let report: RenderReport
                    do {
                        report = try OfflineRenderer.render(song: song, assets: [:], to: url,
                            lengthBeats: (excerpt.end - excerpt.renderStart) * 2, resources: resources)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if InstrumentCatalog.preset(id: candidate.instrumentID)?.isSampler == true {
                            throw SamplerAuditionFailure(instrumentID: candidate.instrumentID)
                        }
                        throw error
                    }
                    guard !report.silent, report.clippedSamples == 0 else { return nil }
                    return try features(url, start: excerpt.start - excerpt.renderStart,
                        duration: excerpt.duration, part: part, eventOffset: excerpt.start, siblings: siblings)
                }
                guard let rendered, rendered.rms > 0.000001 else { return nil }
                let target = targets[index]
                spectral += part.role == "drums" ? distance(target.spectrum, rendered.spectrum)
                    : 0.65 * distance(target.spectrum, rendered.spectrum)
                        + 0.35 * distance(target.harmonics, rendered.harmonics)
                envelope += distance(target.envelope, rendered.envelope)
                articulation += distance(target.articulation, rendered.articulation)
                // Both sides use the same measured pitches, times and masks.
                // Whole-stem RMS would promote every sibling's energy into this
                // voice, then force unrelated tracks down at normalization.
                var targetEnergy = target.envelope.reduce(0, +)
                var renderedEnergy = rendered.envelope.reduce(0, +)
                // Valid measured notes can have a genuinely missing fundamental.
                // Use the same strongest independent source partials on BOTH
                // sides rather than silencing such a voice or letting each
                // candidate choose whichever band makes its gain look best.
                if part.role != "drums", target.harmonics[0] < target.harmonics.reduce(0, +) * 0.01 {
                    let strongest = target.harmonics.indices.dropFirst()
                        .sorted { target.harmonics[$0] > target.harmonics[$1] }.prefix(2)
                    targetEnergy = strongest.reduce(0) { $0 + target.harmonics[$1] }
                    renderedEnergy = strongest.reduce(0) { $0 + rendered.harmonics[$1] }
                }
                let gain = 0.4 * sqrt(targetEnergy / max(1e-15, renderedEnergy))
                guard gain.isFinite, gain > 0 else { return nil }
                gains.append(gain)
            } catch is CancellationError { throw CancellationError() }
            catch let failure as SamplerAuditionFailure {
                let name = InstrumentCatalog.preset(id: failure.instrumentID)?.name ?? failure.instrumentID
                throw AudioError.render("The installed \(name) sound could not be auditioned. Check its installation in Sound Library.")
            } catch { return nil }
        }
        let count = Double(excerpts.count)
        spectral /= count; envelope /= count; articulation /= count
        let sustained = part.notes.filter { $0.durationSeconds >= 1 }.count * 3 >= part.notes.count
        let score = sustained ? 0.3 * spectral + 0.3 * envelope + 0.4 * articulation
            : part.role == "drums" ? 0.45 * spectral + 0.3 * envelope + 0.25 * articulation
            : 0.45 * spectral + 0.3 * envelope + 0.25 * articulation
        gains.sort()
        return Match(candidate: candidate, gain: gains[gains.count / 2], spectral: spectral,
            envelope: envelope, articulation: articulation, score: score)
    }

    /// Current fits already measure part-specific energy. Legacy whole-stem
    /// fits still divide shared energy; one common scale preserves all ratios
    /// within the shared command layer's 0...1.5 range.
    /// Independent per-track caps would destroy the measured balance.
    public static func balancedVolumes(parts: [ReferenceReconstructionPart], fits: [String: ReferenceSoundFit]) -> [String: Double] {
        var raw: [String: Double] = [:]
        for part in parts {
            guard let fit = fits[part.id], fit.sourceGain.isFinite, fit.sourceGain > 0 else { continue }
            let siblings = parts.filter { $0.role == part.role && fits[$0.id] != nil }
            let total = sqrt(siblings.reduce(0) { $0 + pow(max(0, $1.relativeGain.isFinite ? $1.relativeGain : 0), 2) })
            let share = total > 0 ? max(0, part.relativeGain) / total : 1 / sqrt(Double(max(1, siblings.count)))
            let gain = fit.sourceGain * (fit.gainBasis == "part-envelope-v1" ? 1 : share)
            if gain.isFinite { raw[part.id] = gain }
        }
        let highest = raw.values.max() ?? 0
        let scale = highest > 1.5 ? 1.5 / highest : 1
        // Floating-point rounding can put the largest result one ULP above
        // 1.5, which the shared musical validator correctly rejects.
        return raw.mapValues { min(1.5, max(0, $0 * scale)) }
    }

    private static func candidates(for part: ReferenceReconstructionPart, resources: InstrumentResources,
                                   requested: Set<String>?) throws -> [Candidate] {
        guard ["bass", "accompaniment", "drums"].contains(part.role) else {
            throw AudioError.render("Choose a measured bass, accompaniment or drum part.")
        }
        if let requested {
            guard !requested.isEmpty, requested.count <= 256,
                  requested.allSatisfy({ InstrumentCatalog.preset(id: $0) != nil }) else {
                throw AudioError.render("Choose existing catalog instrument IDs for sound fitting.")
            }
            let missing = requested.filter { InstrumentCatalog.preset(id: $0)?.isSampler == true && resources.urls[$0] == nil }
            if !missing.isEmpty { throw MissingInstruments(Set(missing)) }
        }
        let builtins = Set(InstrumentCatalog.presets.filter { !$0.isSampler }.map(\.id))
        let allowed = requested ?? builtins.union(resources.urls.keys)
        let pitches = Set(part.notes.map(\.pitch))
        let compatible = InstrumentCatalog.presets.filter { preset in
            guard allowed.contains(preset.id), !preset.isSampler || resources.urls[preset.id] != nil,
                  (part.role == "drums") == preset.roles.contains("drums"),
                  part.role != "bass" || preset.roles.contains("bass") || family(preset) == "bass",
                  part.role != "accompaniment" || !Set(preset.roles).intersection(["melody", "harmony", "accompaniment", "texture", "countermelody", "percussion"]).isEmpty,
                  pitches.allSatisfy({ (preset.minimumPitch...preset.maximumPitch).contains($0)
                      && preset.supportedPitches?.contains($0) != false
                      && preset.unrenderablePitches?.contains($0) != true }) else { return false }
            return part.role != "drums" || preset.id == "drums.electronic"
                || (preset.pitchMap != nil && pitches.allSatisfy { preset.pitchMap?[$0] != nil })
        }
        let ranked = compatible.sorted { left, right in
            let a = familyRank(left, part: part), b = familyRank(right, part: part)
            return a == b ? left.id < right.id : a < b
        }
        // Reserve space for procedural variations and keep a varied sample
        // search rather than filling the shortlist with one bank's piano layers.
        var selected: [InstrumentPreset] = [], families: [String: Int] = [:]
        let samplers = ranked.filter(\.isSampler)
        for preset in samplers where families[family(preset), default: 0] < 2 {
            guard selected.count < 14 else { break }
            selected.append(preset); families[family(preset), default: 0] += 1
        }
        if selected.count < 14 {
            let used = Set(selected.map(\.id))
            selected += samplers.filter { !used.contains($0.id) }.prefix(14 - selected.count)
        }
        selected += ranked.filter { !$0.isSampler }
        for preset in selected where preset.isSampler {
            guard let url = resources.urls[preset.id],
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw MissingInstruments([preset.id])
            }
        }
        var result: [Candidate] = []
        for preset in selected {
            let id = preset.id
            let supported = Set(InstrumentCatalog.parameters(for: id).map(\.id))
            var neutral = InstrumentCatalog.defaults(for: id).filter { supported.contains($0.key) }
            // Retain the preset's oscillator and envelope. A pad and pluck must
            // remain different actual patches, rather than different labels on
            // one wholesale source-parameter override.
            for key in ["reverb", "delay", "drive", "lfoDepth"] where supported.contains(key) { neutral[key] = 0 }
            if part.role == "drums", !preset.isSampler {
                neutral.merge(["attack": 0.001, "decay": 0.03, "sustain": 1,
                    "release": 0.08, "cutoff": 20_000, "detune": 0]) { _, new in new }
            }
            result.append(Candidate(instrumentID: id, parameters: neutral))
            var fitted = neutral
            for (key, value) in part.suggestedParameters where supported.contains(key) { fitted[key] = value }
            // Auditions use a neutral clock. Do not introduce tempo-dependent
            // effects whose timing would differ when the plan is inserted.
            if supported.contains("delay") { fitted["delay"] = 0 }
            if supported.contains("lfoDepth") { fitted["lfoDepth"] = 0 }
            result.append(Candidate(instrumentID: id, parameters: fitted))
            if !preset.isSampler {
                // Detector ends are acoustic releases, not measured MIDI
                // key-offs. A second long release can otherwise add a tail
                // which the source did not contain.
                for release in [0.01, 0.03] {
                    var shortRelease = fitted
                    shortRelease["release"] = release
                    result.append(Candidate(instrumentID: id, parameters: shortRelease))
                }
            }
            if !preset.isSampler, part.role == "bass" {
                for oscillator in [0.0, 3.0, 1.0] {
                    for cutoff in [max(80, fitted["cutoff", default: 450] * 0.6), min(8_000, fitted["cutoff", default: 450] * 1.7)] {
                        var variation = fitted
                        variation["oscillator"] = oscillator; variation["cutoff"] = cutoff
                        result.append(Candidate(instrumentID: id, parameters: variation))
                    }
                }
            } else if !preset.isSampler, part.role == "drums" {
                let pitches = Set(part.notes.map(\.pitch))
                let cutoffs: [Double] = pitches.allSatisfy({ [35, 36].contains($0) }) ? [350, 1_200, 4_000]
                    : pitches.allSatisfy({ [42, 44, 46].contains($0) }) ? [8_000, 14_000, 20_000]
                    : [4_000, 10_000, 20_000]
                for cutoff in cutoffs {
                    var variation = neutral
                    variation["cutoff"] = cutoff
                    result.append(Candidate(instrumentID: id, parameters: variation))
                }
            } else if !preset.isSampler {
                // Two deliberate source-fitted tonal alternatives leave each
                // neutral preset envelope intact in the search.
                var variation = fitted
                variation["oscillator"] = 3
                variation["cutoff"] = min(12_000, fitted["cutoff", default: 4_000] * 1.8)
                result.append(Candidate(instrumentID: id, parameters: variation))
            }
        }
        var seen = Set<String>()
        result = result.filter { seen.insert(candidateKey($0)).inserted }
        guard !result.isEmpty else { throw AudioError.render("No supplied sounds support this measured role and every pitch. No notes were transposed or dropped.") }
        return Array(result.prefix(36))
    }

    private static func candidateKey(_ candidate: Candidate) -> String {
        let preset = InstrumentCatalog.preset(id: candidate.instrumentID)
        // Built-in melodic instruments share one synthesis implementation. If
        // their full controls agree, audition that actual patch only once.
        let identity = preset?.isSampler == true ? candidate.instrumentID
            : candidate.instrumentID == "drums.electronic" ? "drums" : "synth"
        return identity + candidate.parameters.keys.sorted().map { "|\($0)=\(candidate.parameters[$0]!)" }.joined()
    }

    private static func refinements(_ candidate: Candidate) -> [Candidate] {
        let descriptors = InstrumentCatalog.parameters(for: candidate.instrumentID)
        var changes: [(String, Double)] = []
        for factor in [0.65, 1.5] { changes.append(("cutoff", candidate.parameters["cutoff", default: 6_000] * factor)) }
        changes.append(("drive", min(0.6, candidate.parameters["drive", default: 0] + 0.2)))
        changes.append(("reverb", min(0.5, candidate.parameters["reverb", default: 0] + 0.15)))
        if InstrumentCatalog.preset(id: candidate.instrumentID)?.isSampler != true {
            for factor in [0.5, 1.8] {
                changes.append(("attack", candidate.parameters["attack", default: 0.01] * factor))
                changes.append(("decay", candidate.parameters["decay", default: 0.2] * factor))
                changes.append(("release", candidate.parameters["release", default: 0.3] * factor))
            }
            changes.append(("sustain", candidate.parameters["sustain", default: 0.65] - 0.2))
            changes.append(("sustain", candidate.parameters["sustain", default: 0.65] + 0.2))
        }
        var seen = Set<String>()
        return changes.compactMap { key, value in
            guard let descriptor = descriptors.first(where: { $0.id == key }) else { return nil }
            var values = candidate.parameters
            values[key] = min(descriptor.maximum, max(descriptor.minimum, value))
            let result = Candidate(instrumentID: candidate.instrumentID, parameters: values)
            return seen.insert(candidateKey(result)).inserted ? result : nil
        }
    }

    private static func family(_ preset: InstrumentPreset) -> String {
        let text = (preset.name + " " + preset.description).lowercased()
        for (name, words) in [("bass", ["bass"]), ("piano", ["piano", "keyboard"]),
                              ("bell", ["bell", "mallet", "xylophone", "crystal"]),
                              ("guitar", ["guitar", "ukulele", "harp"]), ("organ", ["organ"]),
                              ("strings", ["string", "bowed"]), ("pad", ["pad", "soundtrack", "goblin", "sci-fi"]),
                              ("wind", ["flute", "clarinet", "sax", "ocarina", "brass"]) ] {
            if words.contains(where: text.contains) { return name }
        }
        return "other"
    }

    private static func familyRank(_ preset: InstrumentPreset, part: ReferenceReconstructionPart) -> Int {
        let durations = part.notes.map(\.durationSeconds).sorted()
        let median = durations[durations.count / 2]
        let order = median < 0.35 ? ["bell", "piano", "guitar", "wind", "organ", "strings", "pad", "other"]
            : ["pad", "strings", "organ", "wind", "piano", "guitar", "bell", "other"]
        if part.role == "bass" { return family(preset) == "bass" ? 0 : 1 }
        return order.firstIndex(of: family(preset)) ?? order.count
    }

    private static func representativeExcerpts(part: ReferenceReconstructionPart, start: Double, end: Double) -> [Excerpt] {
        func excerpt(_ anchor: Double) -> Excerpt {
            let left = max(start, min(anchor, end - min(4, end - start)))
            let right = min(end, left + 4)
            let held = part.notes.filter { $0.startSeconds < left && $0.startSeconds + $0.durationSeconds + 0.8 > left }
            let required = held.map(\.startSeconds).min() ?? left
            let renderStart = max(start, left - 12, required)
            return Excerpt(start: left, end: right, renderStart: renderStart,
                truncated: required < renderStart - 0.001)
        }
        guard end - start > 4 else { return [excerpt(start)] }
        let first = part.notes.first!
        let lastEnd = part.notes.map { $0.startSeconds + $0.durationSeconds }.max() ?? end
        let middleTime = (first.startSeconds + lastEnd) / 2
        let middle = part.notes.min { abs($0.startSeconds - middleTime) < abs($1.startSeconds - middleTime) } ?? first
        // The first onset, a middle passage and the final measured release are
        // different evidence. Never select all three from one dense outro.
        let anchors = [max(start, first.startSeconds - 0.08), max(start, middle.startSeconds - 0.08),
                       min(end - 4, max(start, lastEnd - 2.7))]
        var result: [Excerpt] = []
        for anchor in anchors {
            let candidate = excerpt(anchor)
            if result.allSatisfy({ abs($0.start - candidate.start) >= min(1, (end - start) / 4) }) { result.append(candidate) }
        }
        if result.count < 3, end - start >= 8 {
            for anchor in [start + (end - start - 4) * 0.5, end - 4] {
                let candidate = excerpt(anchor)
                if activity(part.notes, start: candidate.start, end: candidate.end) > 0,
                   result.allSatisfy({ abs($0.start - candidate.start) >= 1 }) { result.append(candidate) }
                if result.count == 3 { break }
            }
        }
        return Array(result.prefix(3))
    }

    private static func activity(_ notes: [MIDITimedNote], start: Double, end: Double) -> Double {
        notes.reduce(0) { value, note in
            value + max(0, min(end, note.startSeconds + note.durationSeconds) - max(start, note.startSeconds)) * Double(note.velocity * note.velocity)
        }
    }

    private static func previewSong(part: ReferenceReconstructionPart, candidate: Candidate, start: Double, end: Double) -> Song {
        var song = Song(); song.tempo = 120; song.lengthBars = 1
        let notes = part.notes.compactMap { event -> NoteEvent? in
            let left = max(start, event.startSeconds), right = min(end, event.startSeconds + event.durationSeconds)
            guard right > left else { return nil }
            return NoteEvent(pitch: event.pitch, startBeat: (left - start) * 2, duration: (right - left) * 2, velocity: event.velocity)
        }
        song.tracks = [Track(name: "Sound comparison", instrumentID: candidate.instrumentID, volume: 0.4,
            parameters: candidate.parameters, clips: [Clip(lengthBeats: (end - start) * 2, notes: notes)])]
        return song
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        let count = max(a.count, b.count)
        guard count > 0 else { return 1 }
        let totalA = max(1e-15, a.reduce(0, +)), totalB = max(1e-15, b.reduce(0, +))
        var squares = 0.0
        for i in 0..<count {
            let delta = sqrt((i < a.count ? a[i] : 0) / totalA) - sqrt((i < b.count ? b[i] : 0) / totalB)
            squares += delta * delta
        }
        return min(1, max(0, sqrt(squares / 2)))
    }

    private static func features(_ url: URL, start: Double, duration: Double,
                                 part: ReferenceReconstructionPart, eventOffset: Double,
                                 siblings: [ReferenceReconstructionPart]) throws -> Features {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 4.001,
              (8_000...192_000).contains(rate), (1...2).contains(channels),
              start + duration <= Double(file.length) / rate + 0.002 else {
            throw AudioError.render("Sound comparison needs a valid mono/stereo source range of at most four seconds.")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        let frames = Int((duration * rate).rounded())
        var samples = Array(repeating: Array(repeating: Float(0), count: frames), count: channels)
        var total = 0.0, read = 0
        file.framePosition = AVAudioFramePosition((start * rate).rounded())
        while read < frames {
            try Task<Never, Never>.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, frames - read)))
            guard buffer.frameLength > 0, let values = buffer.floatChannelData else { throw AudioError.render("The sound comparison source ended early.") }
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channels {
                    let sample = Double(values[channel][frame])
                    guard sample.isFinite else { throw AudioError.render("The sound comparison contains invalid samples.") }
                    samples[channel][read + frame] = Float(sample)
                    total += sample * sample / Double(channels)
                }
            }
            read += Int(buffer.frameLength)
        }
        // Compare only frequencies supported by this voice during measured note
        // activity. A sibling's independently measured fundamental cannot serve
        // as this voice's upper harmonic. Apply identical masks to the rendered
        // candidate so removing ambiguous evidence cannot reward a missing band.
        let size = 4096
        guard let transform = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), vDSP_DFT_Direction.FORWARD) else {
            throw AudioError.render("The sound comparison transform could not be prepared.")
        }
        defer { vDSP_DFT_DestroySetup(transform) }
        let window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size - 1))) }
        let windowEnergy = window.reduce(0.0) { $0 + Double($1 * $1) } / Double(size)
        let hop = max(1, Int((rate * 0.02).rounded()))
        let binWidth = rate / Double(size)
        let factor = 2 / (Double(size * size) * windowEnergy * Double(channels))
        var input = Array(repeating: Float(0), count: size), imaginary = input
        var realOutput = input, imaginaryOutput = input
        var spectrum = Array(repeating: 0.0, count: 40), harmonics = Array(repeating: 0.0, count: 12), envelope: [Double] = []
        let relevant = part.notes.filter { $0.startSeconds - 0.025 < eventOffset + duration
            && $0.startSeconds + $0.durationSeconds + 0.6 >= eventOffset }
        let competingNotes = siblings.flatMap(\.notes).filter {
            $0.startSeconds - 0.025 < eventOffset + duration
                && $0.startSeconds + $0.durationSeconds + 0.6 >= eventOffset
        }
        for center in Swift.stride(from: 0, to: frames, by: hop) {
            try Task<Never, Never>.checkCancellation()
            let absoluteTime = eventOffset + Double(center) / rate
            let active = relevant.filter {
                $0.startSeconds - 0.025 <= absoluteTime && $0.startSeconds + $0.durationSeconds + 0.6 >= absoluteTime
            }
            guard !active.isEmpty else { envelope.append(0); continue }
            let fundamentals = Set(active.map(\.pitch)).map { 440 * pow(2, Double($0 - 69) / 12) }
            let competing = competingNotes.filter {
                $0.startSeconds - 0.025 <= absoluteTime && $0.startSeconds + $0.durationSeconds + 0.6 >= absoluteTime
            }
            let competingFundamentals = Set(competing.map(\.pitch)).map { 440 * pow(2, Double($0 - 69) / 12) }
            // Another voice's attack is broadband even when its steady pitch
            // sits well above this one. Its transient cannot identify the
            // oscillator, envelope or amplitude of an already-held note.
            let ownAttack = active.contains { abs(absoluteTime - $0.startSeconds) < 0.12 }
            let competingAttack = competing.contains {
                let elapsed = absoluteTime - $0.startSeconds
                return elapsed >= -0.06 && elapsed < 0.12
            }
            if part.role != "drums", !ownAttack, competingAttack { envelope.append(0); continue }
            let floor = (fundamentals.min() ?? 40) * 0.75
            var weights = Array(repeating: 0.0, count: size / 2)
            var harmonicIndices = Array(repeating: -1, count: size / 2)
            for bin in 1..<size / 2 {
                let frequency = Double(bin) * binWidth
                if part.role == "drums" {
                    // GM keys are drum classes, not pitched fundamentals.
                    for pitch in Set(active.map(\.pitch)) {
                        let weight: Double
                        switch pitch {
                        case 35, 36: weight = (25...350).contains(frequency) ? 1 : (350...2_000).contains(frequency) ? 0.12 : 0
                        case 38, 39, 40: weight = (350...12_000).contains(frequency) ? 1 : (150...350).contains(frequency) ? 0.15 : 0
                        default: weight = frequency >= 3_000 ? 1 : frequency >= 1_500 ? 0.1 : 0
                        }
                        weights[bin] = max(weights[bin], weight)
                    }
                    continue
                }
                guard frequency >= floor else { continue }
                for fundamental in fundamentals {
                    let harmonic = (frequency / fundamental).rounded()
                    guard (1...12).contains(harmonic),
                          abs(frequency - harmonic * fundamental) <= max(binWidth * 1.25, fundamental * harmonic * 0.035) else { continue }
                    // A separate upper note's attack and brightness are not
                    // evidence for the lower note's oscillator or filter. Keep
                    // its independent fundamental and all unshared partials.
                    if harmonic > 1, competingFundamentals.contains(where: { other in
                        let partial = (frequency / other).rounded()
                        return (1...12).contains(partial) && partial < harmonic
                            && abs(frequency - partial * other) <= max(binWidth * 1.25, partial * other * 0.035)
                    }) { continue }
                    let weight = 1 / pow(harmonic, 0.35)
                    if weight > weights[bin] {
                        weights[bin] = weight; harmonicIndices[bin] = Int(harmonic) - 1
                    }
                }
            }
            var energy = 0.0, fundamentalEnergy = 0.0
            for channel in 0..<channels {
                for offset in 0..<size {
                    let at = center + offset - size / 2
                    input[offset] = at >= 0 && at < frames ? samples[channel][at] * window[offset] : 0
                }
                vDSP_DFT_Execute(transform, input, imaginary, &realOutput, &imaginaryOutput)
                for bin in 1..<size / 2 where weights[bin] > 0 {
                    let real = Double(realOutput[bin]), imag = Double(imaginaryOutput[bin])
                    let power = (real * real + imag * imag) * factor * weights[bin]
                    let band = min(39, max(0, Int(log2(max(25, Double(bin) * binWidth) / 25) * 4)))
                    spectrum[band] += power; energy += power
                    if harmonicIndices[bin] >= 0 {
                        harmonics[harmonicIndices[bin]] += power
                        if harmonicIndices[bin] == 0 { fundamentalEnergy += power }
                    }
                }
            }
            // Independent fundamentals keep a neighboring upper part's
            // attack from determining this voice's articulation. Unpitched
            // drums use their measured class bands instead.
            envelope.append(part.role == "drums" ? energy : fundamentalEnergy)
        }
        guard spectrum.reduce(0, +) > 1e-12 else {
            throw AudioError.render("There is insufficient source energy at this part's measured pitches to fit a sound.")
        }
        return Features(spectrum: spectrum, harmonics: harmonics, envelope: envelope,
            articulation: articulation(envelope, part: part, offset: eventOffset, step: Double(hop) / rate),
            rms: sqrt(total / Double(max(1, frames))))
    }
    private static func articulation(_ energy: [Double], part: ReferenceReconstructionPart,
                                     offset: Double, step: Double) -> [Double] {
        var totals = Array(repeating: 0.0, count: 8), counts = Array(repeating: 0, count: 8)
        let end = offset + Double(energy.count) * step
        for note in part.notes where note.startSeconds < end && note.startSeconds + note.durationSeconds + 0.6 > offset {
            var sums = Array(repeating: 0.0, count: 8), frames = Array(repeating: 0, count: 8)
            for (index, value) in energy.enumerated() {
                let elapsed = offset + Double(index) * step - note.startSeconds
                guard elapsed >= 0, elapsed < note.durationSeconds + 0.6 else { continue }
                let bin: Int
                if elapsed < note.durationSeconds {
                    if elapsed < 0.03 { bin = 0 }
                    else if elapsed < 0.1 { bin = 1 }
                    else if elapsed < 0.25 { bin = 2 }
                    else if elapsed < note.durationSeconds * 0.7 { bin = 3 }
                    else { bin = 4 }
                } else {
                    let released = elapsed - note.durationSeconds
                    bin = released < 0.08 ? 5 : released < 0.24 ? 6 : 7
                }
                sums[bin] += sqrt(max(0, value)); frames[bin] += 1
            }
            let means = zip(sums, frames).map { $1 > 0 ? $0 / Double($1) : 0 }
            let level = means.max() ?? 0
            guard level > 1e-10 else { continue }
            for bin in 0..<8 where frames[bin] > 0 {
                totals[bin] += means[bin] / level; counts[bin] += 1
            }
        }
        return zip(totals, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
    }

}
