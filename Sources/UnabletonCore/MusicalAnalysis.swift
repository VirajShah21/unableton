import Foundation
import CryptoKit

/// Facts about stored musical events, not a listening assessment. Compute on a
/// worker executor after validating both songs, never in an audio callback.
public struct MusicalAnalysisReport: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var beforeRevision: Int
    public var afterRevision: Int
    public var selection: ProjectSelection
    public var before: MusicalSongFacts
    public var after: MusicalSongFacts
    public var changes: MusicalChangeSummary
    public var limitations: [String]
}

public struct MusicalSongFacts: Codable, Sendable, Equatable {
    public var tempo: Double
    public var key: String
    public var beatsPerBar: Int
    public var lengthBeats: Double
    public var trackCount: Int
    public var clipCount: Int
    public var noteCount: Int
    public var analyzedNoteCount: Int
    public var drumNoteCount: Int
    public var audibleTrackCount: Int
    public var activeBeats: Double
    public var generatedVocalBeats: Double
    public var tracks: [MusicalTrackFacts]
    public var windows: [MusicalWindowFacts]
    public var truncated: Bool
}

public struct MusicalTrackFacts: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var instrumentID: String
    public var instrumentCategory: String
    public var isDrums: Bool
    /// Mixer eligibility, not a claim that the rendered track makes sound.
    public var isAudible: Bool
    public var clipCount: Int
    public var noteCount: Int
    public var analyzedNoteCount: Int
    public var drumNoteCount: Int
    public var minimumPitch: Int?
    public var maximumPitch: Int?
    /// MIDI pitch classes C through B. Drum notes are excluded.
    public var pitchClassCounts: [Int]
    public var activeBeats: Double
    public var generatedVocalBeats: Double
    public var distinctNotePatterns: Int
    public var repeatedNoteClipCount: Int
    public var truncated: Bool
}

/// Uniform timeline windows, not inferred verses, builds or drops. Onsets count
/// events starting in the window; sustained activity can span several windows.
public struct MusicalWindowFacts: Codable, Sendable, Equatable {
    public var startBeat: Double
    public var lengthBeats: Double
    public var noteOnsets = 0
    public var audibleNoteOnsets = 0
    public var drumOnsets = 0
    public var audibleDrumOnsets = 0
    public var activeTrackCount = 0
    public var audibleActiveTrackCount = 0
    public var activeBeats = 0.0
    /// Occupied generated-audio time, including any silence in its recording.
    public var generatedVocalBeats = 0.0
    public var audibleGeneratedVocalBeats = 0.0
}

public struct MusicalEntityChanges: Codable, Sendable, Equatable {
    public var addedIDs: [UUID]
    public var deletedIDs: [UUID]
    public var changedIDs: [UUID]
    public var unchangedIDs: [UUID]
    public var addedCount: Int
    public var deletedCount: Int
    public var changedCount: Int
    public var unchangedCount: Int
    public var idsTruncated: Bool
}

public struct MusicalChangeSummary: Codable, Sendable, Equatable {
    public var tracks: MusicalEntityChanges
    public var clips: MusicalEntityChanges
    /// Exact note-array changes in clips that exist in both snapshots.
    public var noteChangedClipIDs: [UUID]
    public var noteChangedClipCount: Int
    /// Revision counters are excluded; these are actual project field changes.
    public var globalFields: [String]
    public var trackOrderChanged: Bool
    public var selectedTrackChanged: Bool?
    public var selectedClipChanged: Bool?
    public var idsTruncated: Bool
}

public enum MusicalAnalyzer {
    public static let maximumWindows = 32
    public static let maximumReportedIDs = 256
    public static let maximumAnalyzedNotes = 262_144

    public static func analyze(before: Song, after: Song, selection: ProjectSelection) -> MusicalAnalysisReport {
        MusicalAnalysisReport(beforeRevision: before.revision, afterRevision: after.revision, selection: selection,
            before: facts(before), after: facts(after), changes: changes(before: before, after: after, selection: selection),
            limitations: [
                "Symbolic event and mixer facts only; no audio was heard, rendered or uploaded. Timbre, lyric intelligibility, harmony and stylistic quality are not established.",
                "Windows are uniform timeline ranges, not inferred musical sections. Instrument categories come from the catalog, never arbitrary track names.",
                "Active beats are interval unions clipped to clip boundaries and available audio duration, excluding release/effect tails. Generated-vocal beats measure occupied audio clips, not detected singing or loudness.",
                "All entity comparisons and totals are exact. Each ID list is capped at 256. Details cover at most 64 tracks and 262144 notes per snapshot; if truncated, pitch, activity and pattern facts cover only analyzed events and must not be treated as complete.",
                "Repeated note patterns ignore identities and clip placement, compare stored pitch/timing/velocity and clip length, and do not establish perceived repetition. Selection describes focus, not an inferred editing permission."
            ])
    }

    private struct Interval { var start: Double; var end: Double }
    private struct ClipLocation { var trackID: UUID; var clip: Clip }

    private static func facts(_ song: Song) -> MusicalSongFacts {
        let length = song.lengthBeats.isFinite ? max(0, song.lengthBeats) : 0
        let baseWindow = Double(max(1, song.beatsPerBar)) * 4
        let windowLength = max(baseWindow, ceil(length / Double(maximumWindows) / baseWindow) * baseWindow)
        let count = length > 0 ? min(maximumWindows, Int(ceil(length / windowLength))) : 0
        var windows = (0..<count).map { index in
            MusicalWindowFacts(startBeat: Double(index) * windowLength,
                               lengthBeats: min(windowLength, length - Double(index) * windowLength))
        }
        let assets = Dictionary(song.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let solo = song.tracks.contains(where: \.isSolo)
        var budget = maximumAnalyzedNotes, tracks: [MusicalTrackFacts] = []
        var allActivity: [Interval] = [], allVocals: [Interval] = [], audibleVocals: [Interval] = []
        var totalNotes = 0, totalDrums = 0, totalClips = 0, analyzed = 0
        for (index, track) in song.tracks.enumerated() {
            let drums = track.kind == .instrument && InstrumentCatalog.preset(id: track.instrumentID)?.category == "Drums"
            totalClips += track.clips.count
            let noteCount = track.clips.reduce(0) { $0 + ($1.kind == .notes ? $1.notes.count : 0) }
            totalNotes += noteCount
            if drums { totalDrums += noteCount }
            guard index < 64 else { continue }
            let audible = !track.isMuted && (!solo || track.isSolo) && track.volume > 0
            var activity: [Interval] = [], vocals: [Interval] = [], pitchClasses = Array(repeating: 0, count: 12)
            var minimum: Int?, maximum: Int?, analyzedTrack = 0
            var patterns = Set<Data>(), patternClipCount = 0
            for clip in track.clips {
                let end = min(length, clip.startBeat + clip.lengthBeats)
                guard clip.startBeat.isFinite, end.isFinite, end > max(0, clip.startBeat) else { continue }
                if clip.kind == .audio {
                    guard let id = clip.assetID, let asset = assets[id], song.tempo.isFinite, song.tempo > 0 else { continue }
                    let available = max(0, asset.duration - clip.sourceOffsetSeconds) * song.tempo / 60
                    let audioEnd = min(end, clip.startBeat + available)
                    guard audioEnd > clip.startBeat else { continue }
                    let interval = Interval(start: max(0, clip.startBeat), end: audioEnd)
                    activity.append(interval)
                    if asset.vocalTake != nil { vocals.append(interval) }
                    continue
                }
                let examined = min(budget, clip.notes.count)
                budget -= examined; analyzedTrack += examined
                for note in clip.notes.prefix(examined) {
                    let start = max(0, clip.startBeat + note.startBeat)
                    let noteEnd = min(end, clip.startBeat + note.startBeat + note.duration)
                    guard start.isFinite, noteEnd.isFinite, noteEnd > start, (0...127).contains(note.pitch) else { continue }
                    activity.append(Interval(start: start, end: noteEnd))
                    minimum = min(minimum ?? note.pitch, note.pitch); maximum = max(maximum ?? note.pitch, note.pitch)
                    if !drums { pitchClasses[note.pitch % 12] += 1 }
                    if !windows.isEmpty {
                        let wi = min(windows.count - 1, Int(start / windowLength))
                        if drums {
                            windows[wi].drumOnsets += 1
                            if audible { windows[wi].audibleDrumOnsets += 1 }
                        } else {
                            windows[wi].noteOnsets += 1
                            if audible { windows[wi].audibleNoteOnsets += 1 }
                        }
                    }
                }
                if examined == clip.notes.count, !clip.notes.isEmpty {
                    patterns.insert(pattern(clip)); patternClipCount += 1
                }
            }
            analyzed += analyzedTrack
            let mergedActivity = union(activity), mergedVocals = union(vocals)
            var activeWindows = Set<Int>()
            visit(mergedActivity, windows: windows, windowLength: windowLength) { wi, _ in activeWindows.insert(wi) }
            for wi in activeWindows {
                windows[wi].activeTrackCount += 1
                if audible { windows[wi].audibleActiveTrackCount += 1 }
            }
            allActivity.append(contentsOf: mergedActivity); allVocals.append(contentsOf: mergedVocals)
            if audible { audibleVocals.append(contentsOf: mergedVocals) }
            tracks.append(MusicalTrackFacts(id: track.id, name: String(track.name.prefix(80)), kind: track.kind,
                instrumentID: String(track.instrumentID.prefix(120)), instrumentCategory: track.kind == .audio ? "Audio" : InstrumentCatalog.preset(id: track.instrumentID)?.category ?? "Unknown",
                isDrums: drums, isAudible: audible, clipCount: track.clips.count, noteCount: noteCount,
                analyzedNoteCount: analyzedTrack, drumNoteCount: drums ? noteCount : 0,
                minimumPitch: minimum, maximumPitch: maximum, pitchClassCounts: pitchClasses,
                activeBeats: duration(mergedActivity), generatedVocalBeats: duration(mergedVocals),
                distinctNotePatterns: patterns.count, repeatedNoteClipCount: max(0, patternClipCount - patterns.count),
                truncated: analyzedTrack < noteCount || track.name.count > 80 || track.instrumentID.count > 120))
        }
        let mergedActivity = union(allActivity), mergedVocals = union(allVocals), mergedAudibleVocals = union(audibleVocals)
        // A merged stream visits each window boundary at most once, avoiding a
        // full scan of every note for every window.
        var activeByWindow = Array(repeating: 0.0, count: windows.count)
        var vocalsByWindow = activeByWindow, audibleVocalsByWindow = activeByWindow
        visit(mergedActivity, windows: windows, windowLength: windowLength) { activeByWindow[$0] += $1 }
        visit(mergedVocals, windows: windows, windowLength: windowLength) { vocalsByWindow[$0] += $1 }
        visit(mergedAudibleVocals, windows: windows, windowLength: windowLength) { audibleVocalsByWindow[$0] += $1 }
        for wi in windows.indices {
            windows[wi].activeBeats = activeByWindow[wi]
            windows[wi].generatedVocalBeats = vocalsByWindow[wi]
            windows[wi].audibleGeneratedVocalBeats = audibleVocalsByWindow[wi]
        }
        return MusicalSongFacts(tempo: song.tempo, key: String(song.key.prefix(120)), beatsPerBar: song.beatsPerBar, lengthBeats: length,
            trackCount: song.tracks.count, clipCount: totalClips, noteCount: totalNotes, analyzedNoteCount: analyzed,
            drumNoteCount: totalDrums, audibleTrackCount: tracks.filter(\.isAudible).count,
            activeBeats: duration(mergedActivity), generatedVocalBeats: duration(mergedVocals), tracks: tracks,
            windows: windows, truncated: song.tracks.count > tracks.count || tracks.contains(where: \.truncated) || song.key.count > 120)
    }

    private static func union(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var merged: [Interval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end { merged[merged.count - 1].end = max(last.end, interval.end) }
            else { merged.append(interval) }
        }
        return merged
    }
    private static func duration(_ intervals: [Interval]) -> Double { intervals.reduce(0) { $0 + $1.end - $1.start } }
    private static func visit(_ intervals: [Interval], windows: [MusicalWindowFacts], windowLength: Double,
                              body: (Int, Double) -> Void) {
        guard !windows.isEmpty else { return }
        for interval in intervals {
            var wi = max(0, Int(interval.start / windowLength))
            while wi < windows.count, windows[wi].startBeat < interval.end {
                let overlap = min(interval.end, windows[wi].startBeat + windows[wi].lengthBeats) - max(interval.start, windows[wi].startBeat)
                if overlap > 0 { body(wi, overlap) }
                wi += 1
            }
        }
    }

    /// Stable cross-process digest, independent of UUIDs, placement, names and
    /// note-array order. It intentionally retains exact floating-point timing.
    private static func pattern(_ clip: Clip) -> Data {
        var hash = SHA256()
        func add(_ value: UInt64) { var little = value.littleEndian; withUnsafeBytes(of: &little) { hash.update(bufferPointer: $0) } }
        add(clip.lengthBeats.bitPattern)
        let sorted = clip.notes.sorted {
            if $0.startBeat != $1.startBeat { return $0.startBeat < $1.startBeat }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            if $0.duration != $1.duration { return $0.duration < $1.duration }
            return $0.velocity < $1.velocity
        }
        for note in sorted { add(UInt64(clamping: note.pitch)); add(note.startBeat.bitPattern); add(note.duration.bitPattern); add(UInt64(clamping: note.velocity)) }
        return Data(hash.finalize())
    }

    private static func changes(before: Song, after: Song, selection: ProjectSelection) -> MusicalChangeSummary {
        let oldTracks = Dictionary(before.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newTracks = Dictionary(after.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldClips = clipLocations(before), newClips = clipLocations(after)
        let trackChanges = compare(oldIDs: before.tracks.map(\.id), newIDs: after.tracks.map(\.id)) { oldTracks[$0] == newTracks[$0] }
        let clipChanges = compare(oldIDs: before.tracks.flatMap { $0.clips.map(\.id) }, newIDs: after.tracks.flatMap { $0.clips.map(\.id) }) {
            oldClips[$0]?.trackID == newClips[$0]?.trackID && oldClips[$0]?.clip == newClips[$0]?.clip
        }
        var noteChangedIDs: [UUID] = [], noteChangedCount = 0
        for track in after.tracks {
            for clip in track.clips {
                if let previous = oldClips[clip.id], previous.clip.notes != clip.notes {
                    noteChangedCount += 1
                    if noteChangedIDs.count < maximumReportedIDs { noteChangedIDs.append(clip.id) }
                }
            }
        }
        var global: [String] = []
        if before.id != after.id { global.append("id") }
        if before.title != after.title { global.append("title") }
        if before.tempo != after.tempo { global.append("tempo") }
        if before.key != after.key { global.append("key") }
        if before.beatsPerBar != after.beatsPerBar { global.append("beatsPerBar") }
        if before.lengthBars != after.lengthBars { global.append("lengthBars") }
        if before.loopEnabled != after.loopEnabled { global.append("loopEnabled") }
        if before.loopStart != after.loopStart { global.append("loopStart") }
        if before.loopEnd != after.loopEnd { global.append("loopEnd") }
        if before.metronomeEnabled != after.metronomeEnabled { global.append("metronomeEnabled") }
        if before.assets != after.assets { global.append("assets") }
        return MusicalChangeSummary(tracks: trackChanges, clips: clipChanges, noteChangedClipIDs: noteChangedIDs,
            noteChangedClipCount: noteChangedCount, globalFields: global,
            trackOrderChanged: before.tracks.map(\.id) != after.tracks.map(\.id),
            selectedTrackChanged: selection.trackID.map { oldTracks[$0] != newTracks[$0] },
            selectedClipChanged: selection.clipID.map { oldClips[$0]?.trackID != newClips[$0]?.trackID || oldClips[$0]?.clip != newClips[$0]?.clip },
            idsTruncated: trackChanges.idsTruncated || clipChanges.idsTruncated || noteChangedCount > noteChangedIDs.count)
    }
    private static func clipLocations(_ song: Song) -> [UUID: ClipLocation] {
        var result: [UUID: ClipLocation] = [:]
        for track in song.tracks { for clip in track.clips { result[clip.id] = ClipLocation(trackID: track.id, clip: clip) } }
        return result
    }
    private static func compare(oldIDs: [UUID], newIDs: [UUID], equal: (UUID) -> Bool) -> MusicalEntityChanges {
        let old = Set(oldIDs), new = Set(newIDs)
        var added: [UUID] = [], deleted: [UUID] = [], changed: [UUID] = [], unchanged: [UUID] = []
        var addedCount = 0, deletedCount = 0, changedCount = 0, unchangedCount = 0
        for id in oldIDs where !new.contains(id) { deletedCount += 1; if deleted.count < maximumReportedIDs { deleted.append(id) } }
        for id in newIDs {
            if !old.contains(id) { addedCount += 1; if added.count < maximumReportedIDs { added.append(id) } }
            else if equal(id) { unchangedCount += 1; if unchanged.count < maximumReportedIDs { unchanged.append(id) } }
            else { changedCount += 1; if changed.count < maximumReportedIDs { changed.append(id) } }
        }
        return MusicalEntityChanges(addedIDs: added, deletedIDs: deleted, changedIDs: changed, unchangedIDs: unchanged,
            addedCount: addedCount, deletedCount: deletedCount, changedCount: changedCount, unchangedCount: unchangedCount,
            idsTruncated: addedCount > added.count || deletedCount > deleted.count || changedCount > changed.count || unchangedCount > unchanged.count)
    }
}
