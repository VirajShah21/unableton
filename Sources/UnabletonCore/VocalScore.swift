import Foundation

/// The exact monophonic source for a generated vocal take. Lyrics follow notes
/// in chronological order; "-" sustains the preceding syllable on another note.
public struct VocalScore: Codable, Sendable, Equatable {
    public let notes: [NoteEvent]
    public let lyrics: [String]
    public let tempo: Double
    public let beatsPerBar: Int
    public let lengthBeats: Double
    public var durationSeconds: Double { lengthBeats * 60 / tempo }
    private static let divisions = 960

    public static func make(clip: Clip, tempo: Double, beatsPerBar: Int, lyrics: [String]) throws -> VocalScore {
        guard clip.kind == .notes else { throw ProjectError("Choose a note clip for the vocal melody.") }
        let score = VocalScore(
            notes: clip.notes.sorted { $0.startBeat == $1.startBeat ? $0.id.uuidString < $1.id.uuidString : $0.startBeat < $1.startBeat },
            lyrics: lyrics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            tempo: tempo, beatsPerBar: beatsPerBar, lengthBeats: clip.lengthBeats)
        try score.validate()
        return score
    }

    public func validate() throws {
        guard tempo.isFinite, (30...300).contains(tempo), (1...12).contains(beatsPerBar),
              lengthBeats.isFinite, lengthBeats > 0, durationSeconds <= 60 else {
            throw ProjectError("A vocal phrase must use 30–300 BPM and last at most 60 seconds.")
        }
        let end = try Self.ticks(lengthBeats)
        guard end > 0, (1...256).contains(notes.count), lyrics.count == notes.count else {
            throw ProjectError("Provide 1–256 melody notes and exactly one lyric syllable per note; use '-' to continue a syllable.")
        }
        var previousEnd = 0, ids = Set<UUID>(), lyricBytes = 0
        for (index, note) in notes.enumerated() {
            guard note.startBeat.isFinite, note.duration.isFinite, note.startBeat >= 0, note.duration > 0,
                  (36...96).contains(note.pitch), (1...127).contains(note.velocity), ids.insert(note.id).inserted else {
                throw ProjectError("Vocal notes need unique IDs, valid durations and velocities, and MIDI pitches 36–96.")
            }
            let start = try Self.ticks(note.startBeat), duration = try Self.ticks(note.duration)
            guard duration > 0, start >= previousEnd, start <= end, duration <= end - start else {
                throw ProjectError("Vocal melodies must be monophonic, with every note contained in the source clip.")
            }
            let lyric = lyrics[index]
            guard !lyric.isEmpty, lyric == lyric.trimmingCharacters(in: .whitespacesAndNewlines),
                  lyric.utf8.count <= 512, lyric.unicodeScalars.allSatisfy(Self.validXMLScalar),
                  !lyric.contains(where: \.isWhitespace), lyric != "--" else {
                throw ProjectError("Each vocal note needs one nonempty lyric syllable without spaces or control characters.")
            }
            if lyric == "-", index == 0 || start != previousEnd {
                throw ProjectError("A continued syllable ('-') must follow a sung note without a rest.")
            }
            lyricBytes += lyric.utf8.count
            previousEnd = start + duration
        }
        guard lyricBytes <= 16_384 else { throw ProjectError("The vocal lyrics are too long for one phrase.") }
    }

    /// MusicXML is generated locally from validated musical values. No provider
    /// path, XML fragment, or model-authored markup is inserted into the score.
    public func musicXML() throws -> String {
        try validate()
        let barTicks = beatsPerBar * Self.divisions, end = try Self.ticks(lengthBeats)
        let starts = try notes.map { try Self.ticks($0.startBeat) }
        let ends = try notes.map { try Self.ticks($0.startBeat) + Self.ticks($0.duration) }
        var measures: [String] = [], noteIndex = 0
        for measureStart in stride(from: 0, to: end, by: barTicks) {
            let measureEnd = min(end, measureStart + barTicks)
            let partial = measureEnd - measureStart != barTicks ? " implicit=\"yes\"" : ""
            var xml = "<measure number=\"\(measureStart / barTicks + 1)\"\(partial)>"
            if measureStart == 0 {
                xml += "<attributes><divisions>\(Self.divisions)</divisions><time><beats>\(beatsPerBar)</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>"
                xml += "<direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>\(tempo)</per-minute></metronome></direction-type><sound tempo=\"\(tempo)\"/></direction>"
            }
            var cursor = measureStart
            while cursor < measureEnd {
                if noteIndex >= notes.count || starts[noteIndex] > cursor {
                    let next = noteIndex < notes.count ? min(measureEnd, starts[noteIndex]) : measureEnd
                    xml += "<note><rest/><duration>\(next - cursor)</duration><voice>1</voice></note>"
                    cursor = next
                    continue
                }
                let segmentEnd = min(measureEnd, ends[noteIndex])
                let continuesFromBar = cursor > starts[noteIndex], continuesToBar = segmentEnd < ends[noteIndex]
                let hasNextMelisma = noteIndex + 1 < notes.count && lyrics[noteIndex + 1] == "-"
                let isMelisma = lyrics[noteIndex] == "-"
                xml += "<note>\(Self.pitchXML(notes[noteIndex].pitch))<duration>\(segmentEnd - cursor)</duration>"
                if continuesFromBar { xml += "<tie type=\"stop\"/>" }
                if continuesToBar { xml += "<tie type=\"start\"/>" }
                xml += "<voice>1</voice>"
                if continuesFromBar || continuesToBar {
                    xml += "<notations>"
                    if continuesFromBar { xml += "<tied type=\"stop\"/>" }
                    if continuesToBar { xml += "<tied type=\"start\"/>" }
                    xml += "</notations>"
                }
                xml += "<lyric number=\"1\">"
                if !continuesFromBar && !isMelisma {
                    let syllable = syllabic(at: noteIndex)
                    let text = lyrics[noteIndex].hasSuffix("-") ? String(lyrics[noteIndex].dropLast()) : lyrics[noteIndex]
                    xml += "<syllabic>\(syllable)</syllabic><text>\(Self.escape(text))</text>"
                }
                if continuesFromBar || continuesToBar || isMelisma || hasNextMelisma {
                    let extend = continuesToBar || hasNextMelisma ? (continuesFromBar || isMelisma ? "continue" : "start") : "stop"
                    xml += "<extend type=\"\(extend)\"/>"
                }
                xml += "</lyric></note>"
                cursor = segmentEnd
                if cursor == ends[noteIndex] { noteIndex += 1 }
            }
            measures.append(xml + "</measure>")
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<score-partwise version=\"3.1\"><part-list><score-part id=\"P1\"><part-name>Vocals</part-name></score-part></part-list><part id=\"P1\">" + measures.joined() + "</part></score-partwise>"
    }

    private func syllabic(at index: Int) -> String {
        // A trailing hyphen joins syllables in a word; a standalone hyphen is
        // reserved for melisma and never appears as sung text.
        let prior = lyrics[..<index].last { $0 != "-" }
        let fromWord = prior?.hasSuffix("-") == true
        let toWord = lyrics[index].hasSuffix("-")
        return fromWord ? (toWord ? "middle" : "end") : (toWord ? "begin" : "single")
    }
    private static func ticks(_ beats: Double) throws -> Int {
        let value = beats * Double(divisions)
        guard value.isFinite, value >= 0, value <= 300_000,
              abs(value - value.rounded()) < 0.000_001 else {
            throw ProjectError("Vocal note timing must fit a 1/960-beat grid. Quantize the source melody before generating; its timing was kept unchanged.")
        }
        return Int(value.rounded())
    }
    private static func validXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private static func pitchXML(_ pitch: Int) -> String {
        let steps = ["C", "C", "D", "D", "E", "F", "F", "G", "G", "A", "A", "B"]
        let sharp = [1, 3, 6, 8, 10].contains(pitch % 12) ? "<alter>1</alter>" : ""
        return "<pitch><step>\(steps[pitch % 12])</step>\(sharp)<octave>\(pitch / 12 - 1)</octave></pitch>"
    }
}

public struct VocalTake: Codable, Sendable, Equatable {
    public var provider: String
    public var singerID: String
    public var sourceClipID: UUID
    public var score: VocalScore
    public var generatedAt: Date
    public init(provider: String, singerID: String, sourceClipID: UUID, score: VocalScore, generatedAt: Date = Date()) {
        self.provider = provider; self.singerID = singerID; self.sourceClipID = sourceClipID
        self.score = score; self.generatedAt = generatedAt
    }
}
