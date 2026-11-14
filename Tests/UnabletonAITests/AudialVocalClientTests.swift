import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private final class AudialRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) {
        // URLSession may turn httpBody into a one-shot stream before handing
        // the request to URLProtocol. Capture it inside the stub while valid.
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
            while data.count <= 32 * 1_024 * 1_024 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = data
        }
        lock.withLock { values.append(recorded) }
    }
    func matching(_ key: String) -> [URLRequest] { lock.withLock { values.filter { $0.value(forHTTPHeaderField: "X-API-Key") == key } } }
    func downloads(_ filename: String) -> [URLRequest] { lock.withLock { values.filter { $0.url?.host == "files.example" && $0.url?.lastPathComponent == filename } } }
}

private final class AudialStub: URLProtocol, @unchecked Sendable {
    static let requests = AudialRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let key = request.value(forHTTPHeaderField: "X-API-Key") ?? ""
        let path = request.url!.path
        var status = 200, fields = ["Content-Type": "application/json"], data = Data()
        if path.hasSuffix(".wav") {
            fields = ["Content-Type": "audio/wav"]
            if path == "/oversized.wav" { fields["Content-Length"] = "40000000" }
            // The app's importer performs full decoding; this client verifies
            // the container before passing it on.
            data = Data("RIFF0000WAVE".utf8)
        } else if key == "denied" {
            status = 402; data = Data("{\"error\":\"do not expose secret-from-server\"}".utf8)
        } else if key == "ambiguous" {
            data = Data("{\"state\":\"processing\"}".utf8)
        } else if key == "badjob" {
            data = Data("{\"state\":\"processing\",\"exeId\":\"../../other-route\"}".utf8)
        } else if key == "invalidurl" {
            data = Data("{\"state\":\"completed\",\"generated\":{\"vocal\":{\"filename\":\"voice.wav\",\"url\":\"http://files.example/voice.wav\"}}}".utf8)
        } else if key == "poll" && path.hasSuffix("/text2vox") {
            data = Data("{\"state\":\"processing\",\"exeId\":\"actual-job\"}".utf8)
        } else {
            let filename = key == "oversized" ? "oversized.wav" : key == "headercheck" ? "headercheck.wav" : "voice.wav"
            data = Data("{\"state\":\"completed\",\"exeId\":\"actual-job\",\"generated\":{\"vocal\":{\"filename\":\"\(filename)\",\"url\":\"https://files.example/\(filename)\"}}}".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct AudialVocalClientTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudialStub.self]
        return URLSession(configuration: config)
    }
    private func score(lyrics: [String] = ["hel-", "lo", "world"]) throws -> VocalScore {
        let clip = Clip(lengthBeats: 4, notes: [
            NoteEvent(pitch: 60, startBeat: 0.5, duration: 1),
            NoteEvent(pitch: 62, startBeat: 1.5, duration: 0.5),
            NoteEvent(pitch: 64, startBeat: 3, duration: 0.5)
        ])
        return try VocalScore.make(clip: clip, tempo: 120, beatsPerBar: 4, lyrics: lyrics)
    }
    private func client(_ key: String, session: URLSession) -> AudialVocalClient {
        AudialVocalClient(apiKey: key, userID: "user-123", referenceAudio: Data("reference".utf8), referenceFileName: "my voice.wav", session: session)
    }

    @Test func submitsExactScoreAndDownloadsWithoutCredentials() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = client("complete", session: session)
        #expect(try await client.singers().map(\.name) == ["Reference voice"])
        let result = try await client.render(score: score(), singerID: "Reference voice", status: { _ in })
        #expect(result == Data("RIFF0000WAVE".utf8))
        let requests = AudialStub.requests.matching("complete")
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/functions/run/text2vox")
        #expect(request.value(forHTTPHeaderField: "X-User-ID") == "user-123")
        let body = try #require(request.httpBody)
        #expect(body.range(of: Data("name=\"text2vox.lyricsMode\"\r\n\r\nper_note".utf8)) != nil)
        #expect(body.range(of: Data("hel|lo|world".utf8)) != nil)
        #expect(body.range(of: Data("filename=\"my_voice.wav\"".utf8)) != nil)
        #expect(body.range(of: Data("MThd".utf8)) != nil)
        // Output requests would also match if the API key had leaked.
        #expect(requests.allSatisfy { $0.url?.host == "api.audialmusic.ai" })
    }

    @Test func pollsReturnedJobRatherThanStartingAnotherGeneration() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        _ = try await client("poll", session: session).render(score: score(), singerID: "Reference voice", status: { _ in })
        let requests = AudialStub.requests.matching("poll")
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(requests.last?.url?.path == "/api/db/user-123/execution/actual-job")
    }

    @Test func configuredSessionHeadersNeverReachDownload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudialStub.self]
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer configured-secret", "Cookie": "private-cookie", "X-User-ID": "configured-user", "X-API-Key": "configured-key"]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        _ = try await client("headercheck", session: session).render(score: score(), singerID: "Reference voice", status: { _ in })
        let request = try #require(AudialStub.requests.downloads("headercheck.wav").first)
        for field in ["X-API-Key", "X-User-ID", "Authorization", "Cookie"] {
            #expect(request.value(forHTTPHeaderField: field) == nil)
        }
    }

    @Test func errorsAreSanitizedAndJobPostIsNotRetried() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            _ = try await client("denied", session: session).render(score: score(), singerID: "Reference voice", status: { _ in })
            Issue.record("Expected subscription error")
        } catch let error as VocalServiceError {
            if case .provider(let status, let message) = error {
                #expect(status == 402)
                #expect(!message.contains("secret-from-server"))
            } else { Issue.record("Expected provider error") }
        }
        #expect(AudialStub.requests.matching("denied").count == 1)
    }

    @Test func rejectsMissingJobIDAndInsecureOrOversizedDownloads() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        for key in ["ambiguous", "badjob", "invalidurl", "oversized"] {
            await #expect(throws: VocalServiceError.self) {
                _ = try await client(key, session: session).render(score: score(), singerID: "Reference voice", status: { _ in })
            }
            #expect(AudialStub.requests.matching(key).filter { $0.httpMethod == "POST" }.count == 1)
        }
    }

    @Test func cancellationDoesNotStartAJob() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let score = try score(), client = client("cancelled", session: session)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.render(score: score, singerID: "Reference voice", status: { _ in })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(AudialStub.requests.matching("cancelled").isEmpty)
    }

    @Test func rejectsDelimiterInjectionBeforeUploading() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        await #expect(throws: VocalServiceError.self) {
            _ = try await client("delimiter", session: session).render(score: score(lyrics: ["hel|other", "lo", "world"]), singerID: "Reference voice", status: { _ in })
        }
        #expect(AudialStub.requests.matching("delimiter").isEmpty)
    }

    @Test func midiRetainsRestsTempoAndSyllableTiming() throws {
        let bytes = Array(try AudialVocalClient.midiData(score()))
        #expect(Array(bytes[0..<4]) == Array("MThd".utf8))
        #expect(Array(bytes[8..<14]) == [0, 1, 0, 2, 3, 192]) // type1,2tracks,960PPQ
        var cursor = 14
        var notes: [(Int, Int)] = [], lyrics: [(Int, String)] = [], tempi: [[UInt8]] = []
        func vlq() -> Int {
            var value = 0
            while true { let b = bytes[cursor]; cursor += 1; value = value * 128 + Int(b & 127); if b < 128 { return value } }
        }
        for _ in 0..<2 {
            #expect(Array(bytes[cursor..<(cursor + 4)]) == Array("MTrk".utf8))
            cursor += 4
            let size = bytes[cursor..<(cursor + 4)].reduce(0) { $0 * 256 + Int($1) }; cursor += 4
            let end = cursor + size; var tick = 0
            while cursor < end {
                tick += vlq(); let status = bytes[cursor]; cursor += 1
                if status == 0xFF {
                    let type = bytes[cursor]; cursor += 1
                    let count = vlq(), value = Array(bytes[cursor..<(cursor + count)]); cursor += count
                    if type == 0x05 { lyrics.append((tick, String(decoding: value, as: UTF8.self))) }
                    if type == 0x51 { tempi.append(value) }
                } else {
                    let pitch = bytes[cursor]; cursor += 2
                    if status == 0x90 { notes.append((tick, Int(pitch))) }
                }
            }
        }
        #expect(tempi == [[7, 161, 32]]) //120BPM
        #expect(notes.map(\.0) == [480, 1440, 2880])
        #expect(notes.map(\.1) == [60, 62, 64])
        #expect(lyrics.map(\.0) == [480, 1440, 2880])
        #expect(lyrics.map(\.1) == ["hel-", "lo", "world"])
    }
}
