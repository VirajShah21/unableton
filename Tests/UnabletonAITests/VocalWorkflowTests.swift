import Foundation
import AVFAudio
import Testing
import UnabletonCore
@testable import UnabletonAI

private actor SingingFixture: VocalGenerating {
    let providerID = "fixture"
    private var count = 0
    private let bytes: Data
    private let fails: Bool
    init(bytes: Data, fails: Bool = false) { self.bytes = bytes; self.fails = fails }
    func singers() async throws -> [VocalSinger] { [.init(name: "Test Singer", language: "english", style: "pop")] }
    func render(score: VocalScore, singerID: String, status: @escaping @Sendable (String) -> Void) async throws -> Data {
        count += 1
        if fails { throw VocalServiceError.transport("Unavailable") }
        return bytes
    }
    func calls() -> Int { count }
}
private actor VocalTransport: ResponsesTransport {
    private var responses: [JSONValue]
    private var bodies: [JSONValue] = []
    init(_ responses: [JSONValue]) { self.responses = responses }
    func send(body: JSONValue, apiKey: String, status: @escaping @Sendable (String) -> Void) async throws -> JSONValue {
        bodies.append(body)
        guard !responses.isEmpty else { throw AgentError.configuration("Unexpected request") }
        return responses.removeFirst()
    }
    func requests() -> [JSONValue] { bodies }
}
private func finished(_ output: [JSONValue]) -> JSONValue { .object(["status": .string("completed"), "output": .array(output)]) }
private func spoken() -> JSONValue { .object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string("Added the vocal.")])])]) }
private func vocalCall(_ clip: UUID, id: String = "sing") throws -> JSONValue {
    let args: JSONValue = .object(["melody_clip_id": .string(clip.uuidString), "singer_id": .string("Test Singer"), "lyrics": .array([.string("hel-"), .string("lo")]), "track_name": .string("Vocal"), "target_track_id": .null])
    return .object(["type": .string("function_call"), "name": .string("generate_vocals"), "call_id": .string(id), "arguments": .string(String(data: try JSONEncoder().encode(args), encoding: .utf8)!)])
}
private func vocalSong() -> Song {
    var song = Song(); song.tempo = 120
    song.tracks = [Track(clips: [Clip(startBeat: 8, lengthBeats: 4, notes: [NoteEvent(pitch: 60, duration: 2), NoteEvent(pitch: 64, startBeat: 2, duration: 2)])])]
    return song
}
private func vocalWAV(silent: Bool = false) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocal-test-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
    buffer.frameLength = buffer.frameCapacity
    for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = silent ? 0 : Float(sin(Double(i) * .pi * 440 / 24_000)) * 0.15 }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
    return try Data(contentsOf: url)
}

struct VocalWorkflowTests {
    @Test func toolStagesRealAudioPreservesMelodyAndPreviewCanResolveIt() async throws {
        let song = vocalSong(), clip = song.tracks[0].clips[0]
        let data = try vocalWAV(), provider = SingingFixture(bytes: data)
        let vocals = VocalSession(provider: provider)
        let previewArgs = "{\"start_beat\":8,\"length_beats\":4}"
        let preview: JSONValue = .object(["type": .string("function_call"), "name": .string("render_preview"), "call_id": .string("preview"), "arguments": .string(previewArgs)])
        let transport = VocalTransport([finished([try vocalCall(clip.id)]), finished([preview]), finished([spoken()])])
        var chat = Conversation(); chat.messages = [.init(role: "user", text: "Sing hello on the melody")]
        let result = try await MusicAgent(transport: transport).generate(song: song, conversation: chat, selection: .init(), configuration: .init(model: "test", apiKey: "fixture"), vocals: vocals, preview: { draft, _, _ in
            let assets = await vocals.assets(for: draft)
            #expect(assets.values.first == data)
            return PreviewReport(duration: 2)
        })
        #expect(result.song.tracks[0] == song.tracks[0])
        let audio = try #require(result.song.tracks.last?.clips.first)
        #expect(audio.kind == .audio && audio.startBeat == 8 && audio.lengthBeats == 4)
        #expect(result.generatedAssets[audio.assetID!] == data)
        let take = try #require(result.song.assets.first?.vocalTake)
        #expect(take.score.lyrics == ["hel-", "lo"] && take.sourceClipID == clip.id)
        #expect(await provider.calls() == 1)
    }
    @Test func identicalScoreWithNewNoteIDsReusesCompletedRender() async throws {
        let provider = SingingFixture(bytes: try vocalWAV()), vocals = VocalSession(provider: provider)
        let song = vocalSong(); var clip = song.tracks[0].clips[0]
        let score = try VocalScore.make(clip: clip, tempo: song.tempo, beatsPerBar: 4, lyrics: ["hel-", "lo"])
        let first = try await vocals.render(score: score, singerID: "Test Singer", sourceClipID: clip.id, status: { _ in })
        clip.id = UUID(); clip.notes = clip.notes.map { var note = $0; note.id = UUID(); return note }
        let secondScore = try VocalScore.make(clip: clip, tempo: song.tempo, beatsPerBar: 4, lyrics: score.lyrics)
        let second = try await vocals.render(score: secondScore, singerID: "Test Singer", sourceClipID: clip.id, status: { _ in })
        #expect(first.asset.id == second.asset.id)
        #expect(second.asset.vocalTake?.sourceClipID == clip.id)
        #expect(await provider.calls() == 1)
    }
    @Test func changedVelocityRequiresANewTake() async throws {
        let provider = SingingFixture(bytes: try vocalWAV()), vocals = VocalSession(provider: provider)
        let song = vocalSong(); var clip = song.tracks[0].clips[0]
        let score = try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: ["hel-", "lo"])
        _ = try await vocals.render(score: score, singerID: "Test Singer", sourceClipID: clip.id, status: { _ in })
        clip.notes[0].velocity = 60
        let changed = try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: score.lyrics)
        _ = try await vocals.render(score: changed, singerID: "Test Singer", sourceClipID: clip.id, status: { _ in })
        #expect(await provider.calls() == 2)
    }
    @Test func invalidMelodyAndFullArrangementNeverSubmitSynthesis() async throws {
        for fullArrangement in [false, true] {
            var song = vocalSong()
            if fullArrangement { song.tracks += (1..<64).map { _ in Track() } }
            else { song.tracks[0].clips[0].notes[1].startBeat = 1 }
            let provider = SingingFixture(bytes: try vocalWAV()), vocals = VocalSession(provider: provider)
            let transport = VocalTransport([finished([try vocalCall(song.tracks[0].clips[0].id)]), finished([spoken()])])
            var chat = Conversation(); chat.messages = [.init(role: "user", text: "Sing this")]
            let result = try await MusicAgent(transport: transport).generate(song: song, conversation: chat, selection: .init(), configuration: .init(model: "test", apiKey: "fixture"), vocals: vocals)
            #expect(result.song == song && result.generatedAssets.isEmpty)
            #expect(await provider.calls() == 0)
        }
    }
    @Test func providerFailureDoesNotUpgradeOrRetryPaidSynthesis() async throws {
        let song = vocalSong(), provider = SingingFixture(bytes: Data(), fails: true), vocals = VocalSession(provider: provider)
        let transport = VocalTransport([finished([try vocalCall(song.tracks[0].clips[0].id)])])
        var chat = Conversation(); chat.messages = [.init(role: "user", text: "Add vocals")]
        await #expect(throws: VocalRenderFailure.self) {
            try await MusicAgent(transport: transport).generate(song: song, conversation: chat, selection: .init(), configuration: .init(apiKey: "fixture"), vocals: vocals)
        }
        #expect(await provider.calls() == 1)
        #expect(await transport.requests().count == 1)
        #expect(await vocals.assets(for: song).isEmpty)
    }
    @Test func silentAndMalformedAudioNeverBecomeAssets() async throws {
        let song = vocalSong(), clip = song.tracks[0].clips[0]
        let score = try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: ["hel-", "lo"])
        for data in [try vocalWAV(silent: true), Data("not audio".utf8)] {
            let provider = SingingFixture(bytes: data), vocals = VocalSession(provider: provider)
            await #expect(throws: VocalRenderFailure.self) { try await vocals.render(score: score, singerID: "Test Singer", sourceClipID: clip.id, status: { _ in }) }
            #expect(await vocals.assets(for: song).isEmpty)
        }
    }
    @Test func disabledVocalToolsAreNotAdvertised() async throws {
        let transport = VocalTransport([finished([spoken()])])
        var chat = Conversation(); chat.messages = [.init(role: "user", text: "What can you do?")]
        _ = try await MusicAgent(transport: transport).generate(song: Song(), conversation: chat, selection: .init(), configuration: .init(model: "test", apiKey: "fixture"))
        let request = try #require(await transport.requests().first)
        #expect(request["tools"]?.arrayValue?.contains { $0["name"]?.stringValue == "generate_vocals" } == false)
    }
}
