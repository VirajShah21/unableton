import Foundation
import Testing
@testable import UnabletonCore

private final class ScoreXMLReader: NSObject, XMLParserDelegate {
    var measureDurations: [Int] = []
    var lyrics: [String] = []
    var ties: [String] = []
    var extensions: [String] = []
    var syllabics: [String] = []
    var tempo: String?
    private var element = "", characters = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        element = name; characters = ""
        if name == "measure" { measureDurations.append(0) }
        if name == "tie", let type = attributes["type"] { ties.append(type) }
        if name == "extend", let type = attributes["type"] { extensions.append(type) }
        if name == "sound" { tempo = attributes["tempo"] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { characters += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "duration", let ticks = Int(characters), !measureDurations.isEmpty { measureDurations[measureDurations.count - 1] += ticks }
        if name == "text" { lyrics.append(characters) }
        if name == "syllabic" { syllabics.append(characters) }
        characters = ""
    }
}

struct VocalScoreTests {
    private func parse(_ xml: String) throws -> ScoreXMLReader {
        let reader = ScoreXMLReader(), parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        #expect(parser.parse(), "\(String(describing: parser.parserError))")
        return reader
    }
    @Test func scorePreservesInitialRestsBarTiesAndExactDuration() throws {
        let clip = Clip(lengthBeats: 9, notes: [NoteEvent(pitch: 61, startBeat: 3, duration: 3), NoteEvent(pitch: 62, startBeat: 7, duration: 0.5)])
        let score = try VocalScore.make(clip: clip, tempo: 123.5, beatsPerBar: 4, lyrics: ["Hey", "you"])
        let xml = try score.musicXML(), parsed = try parse(xml)
        #expect(score.notes == clip.notes)
        #expect(parsed.measureDurations == [3840, 3840, 960])
        #expect(parsed.ties == ["start", "stop"])
        #expect(parsed.lyrics == ["Hey", "you"])
        #expect(parsed.extensions == ["start", "stop"])
        #expect(parsed.tempo == "123.5")
        #expect(xml.contains("<rest/><duration>2880</duration>"))
        #expect(xml.contains("<step>C</step><alter>1</alter><octave>4</octave>"))
        #expect(xml.contains("<measure number=\"3\" implicit=\"yes\">"))
    }
    @Test func lyricsEscapeMarkupAndPreserveUnicode() throws {
        let text = "é&<\"'歌"
        let score = try VocalScore.make(clip: Clip(lengthBeats: 1, notes: [NoteEvent()]), tempo: 120, beatsPerBar: 4, lyrics: [text])
        let xml = try score.musicXML(), parsed = try parse(xml)
        #expect(parsed.lyrics == [text])
        #expect(xml.contains("é&amp;&lt;&quot;&apos;歌"))
        #expect(!xml.contains("<!DOCTYPE"))
    }
    @Test func melismaAndSyllableJoinsDoNotResingHeldText() throws {
        let notes = (0..<5).map { NoteEvent(pitch: 60 + $0, startBeat: Double($0), duration: 1) }
        let score = try VocalScore.make(clip: Clip(lengthBeats: 5, notes: notes), tempo: 120, beatsPerBar: 4, lyrics: ["Twin-", "kle", "-", "-", "star"])
        let parsed = try parse(score.musicXML())
        #expect(parsed.lyrics == ["Twin", "kle", "star"])
        #expect(parsed.syllabics == ["begin", "end", "single"])
        #expect(parsed.extensions == ["start", "continue", "stop"])
    }
    @Test func chronologicalNotesKeepOriginalIDsAndTiming() throws {
        let early = NoteEvent(startBeat: 0, duration: 1), late = NoteEvent(startBeat: 2, duration: 1)
        let score = try VocalScore.make(clip: Clip(lengthBeats: 4, notes: [late, early]), tempo: 120, beatsPerBar: 4, lyrics: ["One", "two"])
        #expect(score.notes == [early, late])
        #expect(score.lyrics == ["One", "two"])
        #expect(score.durationSeconds == 2)
    }
    @Test func invalidScoresAreRejectedBeforeRendering() throws {
        let valid = Clip(lengthBeats: 4, notes: [NoteEvent()])
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: valid, tempo: 0, beatsPerBar: 4, lyrics: ["Hey"]) }
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: valid, tempo: .nan, beatsPerBar: 4, lyrics: ["Hey"]) }
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: valid, tempo: 120, beatsPerBar: 0, lyrics: ["Hey"]) }
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: valid, tempo: 120, beatsPerBar: 4, lyrics: []) }
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: valid, tempo: 120, beatsPerBar: 4, lyrics: ["-"]) }
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: valid, tempo: 120, beatsPerBar: 4, lyrics: ["two words"]) }
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: valid, tempo: 120, beatsPerBar: 4, lyrics: ["bad\u{1}"]) }
        var altered = valid; altered.kind = .audio
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: altered, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"]) }
        altered = valid; altered.notes[0].duration = 5
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: altered, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"]) }
        altered = valid; altered.notes[0].pitch = 97
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: altered, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"]) }
        altered = valid; altered.notes.append(NoteEvent(startBeat: 0.5))
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: altered, tempo: 120, beatsPerBar: 4, lyrics: ["Hey", "you"]) }
        altered = valid; altered.notes.append(NoteEvent(startBeat: 2))
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: altered, tempo: 120, beatsPerBar: 4, lyrics: ["Hey", "-"]) }
        altered = valid; altered.lengthBeats = 121
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: altered, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"]) }
    }
    @Test func gridValidationNeverSilentlyRetimesNotes() throws {
        var clip = Clip(lengthBeats: 4, notes: [NoteEvent(startBeat: 1.13)])
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"]) }
        clip.notes[0].startBeat = 1.0 / 3.0
        let score = try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"])
        #expect(score.notes == clip.notes)
        #expect(try score.musicXML().contains("<rest/><duration>320</duration>"))
        clip.notes[0].duration = 0.00001
        #expect(throws: ProjectError.self) { try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"]) }
    }
    @Test func provenanceAndLegacyAudioAssetsRoundTrip() throws {
        let clip = Clip(lengthBeats: 4, notes: [NoteEvent()])
        let score = try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: ["Hey"])
        let take = VocalTake(provider: "rinoa", singerID: "singer-1", sourceClipID: clip.id, score: score, generatedAt: Date(timeIntervalSince1970: 1234))
        let asset = AudioAsset(fileName: "Vocals.wav", duration: 2, sampleRate: 48000, channels: 1, vocalTake: take)
        #expect(try JSONDecoder().decode(AudioAsset.self, from: JSONEncoder().encode(asset)) == asset)
        let legacy = """
        {"id":"\(UUID().uuidString)","fileName":"recording.wav","duration":2,"sampleRate":48000,"channels":1}
        """
        #expect(try JSONDecoder().decode(AudioAsset.self, from: Data(legacy.utf8)).vocalTake == nil)
        var project = ProjectFile(); project.song.assets = [asset]
        project.song.tracks = [Track(kind: .audio, clips: [Clip(kind: .audio, lengthBeats: 4, assetID: asset.id)])]
        let archive = try ProjectArchive.encode(project: project, assets: [asset.id: Data([1, 2, 3])])
        let decoded = try ProjectArchive.decode(archive)
        #expect(decoded.project.song.assets[0].vocalTake == take)
        #expect(decoded.assets[asset.id] == Data([1, 2, 3]))
    }
}
