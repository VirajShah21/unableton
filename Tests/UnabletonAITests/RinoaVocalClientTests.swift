import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private struct VocalStubResponse: Sendable {
    var code = 200
    var headers: [String: String] = [:]
    var body = Data()
    var holdOpen = false
}
private struct VocalCapturedRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}
private final class VocalFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (VocalCapturedRequest) -> VocalStubResponse)?
    private var requests: [VocalCapturedRequest] = []
    private var stops = 0
    func configure(_ handler: @escaping @Sendable (VocalCapturedRequest) -> VocalStubResponse) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = []; stops = 0
    }
    func respond(_ request: URLRequest) -> VocalStubResponse {
        let body: Data
        if let bytes = request.httpBody { body = bytes }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }; collected.append(contentsOf: buffer.prefix(read))
            }
            body = collected
        } else { body = Data() }
        let captured = VocalCapturedRequest(url: request.url!, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: body)
        lock.lock(); requests.append(captured); let current = handler; lock.unlock()
        return current?(captured) ?? VocalStubResponse(code: 500)
    }
    func captured() -> [VocalCapturedRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func didStop() { lock.lock(); stops += 1; lock.unlock() }
}
private final class RinoaStubProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = VocalFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.fixture.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.code, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        if !stub.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.fixture.didStop() }
}
private final class VocalStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite(.serialized)
struct RinoaVocalClientTests {
    private func session(inheritedAuthorization: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RinoaStubProtocol.self]
        if inheritedAuthorization { configuration.httpAdditionalHeaders = ["Authorization": "Bearer inherited-credential", "Cookie": "private=session"] }
        return URLSession(configuration: configuration)
    }
    private func score() throws -> VocalScore {
        try VocalScore.make(clip: Clip(lengthBeats: 4, notes: [NoteEvent(pitch: 60, startBeat: 0, duration: 1)]), tempo: 120, beatsPerBar: 4, lyrics: ["la"])
    }
    private func completed(_ urls: [String] = ["https://assets.example.test/vocal.wav"], format: String = ".wav") throws -> Data {
        let event: [String: Any] = ["status": "completed", "outputs": ["audio_files": urls, "audio_format": format, "sample_rate": 44100, "num_samples": [44100]]]
        let json = try JSONSerialization.data(withJSONObject: event)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
    private func stream(_ body: Data, holdOpen: Bool = false) -> VocalStubResponse {
        VocalStubResponse(headers: ["Content-Type": "text/event-stream"], body: body, holdOpen: holdOpen)
    }

    @Test func singerNamesAreStableIDsAndUseBearerAuthentication() async throws {
        RinoaStubProtocol.fixture.configure { _ in
            VocalStubResponse(headers: ["Content-Type": "application/json"], body: Data("[{\"name\":\"English: Female Jazz\",\"language\":\"english\",\"singer\":\"internal-voice\",\"style\":\"Control\",\"metadata\":{\"initial\":\"J\"}}]".utf8))
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let singers = try await RinoaVocalClient(apiKey: "fixture-key", session: session).singers()
        #expect(singers == [VocalSinger(name: "English: Female Jazz", language: "english", style: "Control")])
        #expect(singers[0].id == "English: Female Jazz")
        let request = try #require(RinoaStubProtocol.fixture.captured().first)
        #expect(request.url.absoluteString == "https://api.rinoa.ai/list-singers")
        #expect(request.method == "GET")
        #expect(request.header("Authorization") == "Bearer fixture-key")
    }

    @Test func musicXMLRequestAndCompletedSSEProduceAnUnauthenticatedDownload() async throws {
        let completion = try completed()
        let wav = Data("RIFF0000WAVE".utf8)
        let progress = Data("event: progress\r\ndata: {\"status\":\"heartbeat\",\"timestamp\":1}\r\n\r\ndata: {\"status\":\"processing\",\"batch_progress\":1,\"total_batches\":2}\n\n".utf8)
        RinoaStubProtocol.fixture.configure { request in
            if request.url.path == "/sing" { return stream(progress + completion) }
            return VocalStubResponse(headers: ["Content-Type": "audio/wav"], body: wav)
        }
        let session = session(inheritedAuthorization: true); defer { session.invalidateAndCancel() }
        let statuses = VocalStatuses(), score = try score()
        let data = try await RinoaVocalClient(apiKey: "fixture-key", session: session).render(score: score, singerID: "English: Female Jazz", status: { statuses.append($0) })
        #expect(data == wav)
        let requests = RinoaStubProtocol.fixture.captured()
        #expect(requests.count == 2)
        let post = try #require(requests.first)
        #expect(post.method == "POST")
        #expect(post.header("Authorization") == "Bearer fixture-key")
        #expect(post.header("Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: post.body) as? [String: String]
        #expect(body?["score_format"] == "musicxml")
        let expectedXML = try score.musicXML()
        #expect(body?["score_content"] == expectedXML)
        #expect(body?["singer_id"] == "English: Female Jazz")
        #expect(UUID(uuidString: body?["session_id"] ?? "") != nil)
        #expect(Set(body?.keys.map { $0 } ?? []) == ["score_content", "score_format", "singer_id", "session_id"])
        let download = requests[1]
        #expect(download.header("Authorization") == nil)
        #expect(download.header("Cookie") == nil)
        #expect(statuses.snapshot().contains { $0.contains("1/2") })
    }

    @Test func completedEventAtEOFNeedsNoTrailingBlankSeparator() async throws {
        let completion = try completed().dropLast(2)
        let eofCompletion = Data(completion)
        RinoaStubProtocol.fixture.configure { request in
            request.url.path == "/sing" ? stream(eofCompletion) : VocalStubResponse(body: Data("RIFF0000WAVE".utf8))
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let data = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
        #expect(data == Data("RIFF0000WAVE".utf8))
    }

    @Test func containerValidationAcceptsMIMELabelsButRejectsNonWAVAudio() async throws {
        let completion = try completed(format: "audio/wav")
        let wav = Data("RIFF0000WAVE".utf8)
        RinoaStubProtocol.fixture.configure { request in request.url.path == "/sing" ? stream(completion) : VocalStubResponse(body: wav) }
        let session = session(); defer { session.invalidateAndCancel() }
        let result = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
        #expect(result == wav)
        let mp3 = try completed(format: ".mp3")
        RinoaStubProtocol.fixture.configure { request in request.url.path == "/sing" ? stream(mp3) : VocalStubResponse(body: Data("ID3-fake-mp3".utf8)) }
        do {
            _ = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
            Issue.record("Expected a WAV format error")
        } catch let error as VocalServiceError { #expect(error.localizedDescription.contains("Free plan excludes downloads")) }
        #expect(RinoaStubProtocol.fixture.captured().filter { $0.method == "POST" }.count == 1)
    }
    @Test func providerErrorsAreSurfacedWithoutRetryingTheBilledPOST() async throws {
        RinoaStubProtocol.fixture.configure { _ in
            VocalStubResponse(code: 401, headers: ["Content-Type": "application/json"], body: Data("{\"detail\":\"Not enough credits\"}".utf8))
        }
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            _ = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
            Issue.record("Expected a provider error")
        } catch let error as VocalServiceError {
            #expect(error == .provider(status: 401, message: "Not enough credits"))
        }
        #expect(RinoaStubProtocol.fixture.captured().count == 1)
    }

    @Test func streamErrorAndPrematureEOFDoNotDownloadOrRetry() async throws {
        for payload in ["data: {\"status\":\"error\",\"message\":\"Unsupported score\"}\n\n", "data: {\"status\":\"processing\"}\n\n"] {
            RinoaStubProtocol.fixture.configure { _ in stream(Data(payload.utf8)) }
            let session = session(); defer { session.invalidateAndCancel() }
            await #expect(throws: VocalServiceError.self) {
                _ = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
            }
            #expect(RinoaStubProtocol.fixture.captured().count == 1)
        }
    }

    @Test func unsafeAndAmbiguousOutputURLsAreRejectedBeforeDownload() async throws {
        let cases = [["http://assets.example.test/vocal.wav"], ["https://user:secret@assets.example.test/vocal.wav"], ["https://assets.example.test/a.wav", "https://assets.example.test/b.wav"], []]
        for urls in cases {
            let completion = try completed(urls)
            RinoaStubProtocol.fixture.configure { _ in stream(completion) }
            let session = session(); defer { session.invalidateAndCancel() }
            await #expect(throws: VocalServiceError.self) {
                _ = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
            }
            #expect(RinoaStubProtocol.fixture.captured().count == 1)
        }
    }

    @Test func oversizedDownloadHeadersAndProgressLinesAreBounded() async throws {
        let completion = try completed()
        RinoaStubProtocol.fixture.configure { request in
            request.url.path == "/sing" ? stream(completion) : VocalStubResponse(headers: ["Content-Length": "\(32 * 1024 * 1024 + 1)"], body: Data([1]))
        }
        let session = session(); defer { session.invalidateAndCancel() }
        await #expect(throws: VocalServiceError.self) {
            _ = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
        }
        let hugeLine = Data(("data: " + String(repeating: "x", count: 64 * 1024) + "\n").utf8)
        RinoaStubProtocol.fixture.configure { _ in stream(hugeLine) }
        await #expect(throws: VocalServiceError.self) {
            _ = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
        }
        #expect(RinoaStubProtocol.fixture.captured().count == 1)
    }

    @Test func excessiveHeartbeatEventsCannotKeepARequestOpenIndefinitely() async throws {
        let body = Data(String(repeating: "data: {\"status\":\"heartbeat\"}\n\n", count: 2049).utf8)
        RinoaStubProtocol.fixture.configure { _ in stream(body) }
        let session = session(); defer { session.invalidateAndCancel() }
        await #expect(throws: VocalServiceError.self) {
            _ = try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score(), singerID: "Singer", status: { _ in })
        }
        #expect(RinoaStubProtocol.fixture.captured().count == 1)
    }

    @Test func cancellationStopsTheStreamWithoutASecondRequest() async throws {
        RinoaStubProtocol.fixture.configure { _ in
            stream(Data("data: {\"status\":\"heartbeat\"}\n\n".utf8), holdOpen: true)
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let score = try score()
        let task = Task { try await RinoaVocalClient(apiKey: "fixture", session: session).render(score: score, singerID: "Singer", status: { _ in }) }
        let deadline = ContinuousClock.now + .seconds(3)
        while RinoaStubProtocol.fixture.captured().isEmpty {
            guard ContinuousClock.now < deadline else { task.cancel(); Issue.record("The fixture did not receive a request"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        #expect(RinoaStubProtocol.fixture.captured().count == 1)
    }

    @Test func missingCredentialsAndSingerFailBeforeNetwork() async throws {
        RinoaStubProtocol.fixture.configure { _ in VocalStubResponse(code: 500) }
        let session = session(); defer { session.invalidateAndCancel() }
        for (key, singer) in [("", "Singer"), ("fixture", " ")] {
            await #expect(throws: VocalServiceError.self) {
                _ = try await RinoaVocalClient(apiKey: key, session: session).render(score: score(), singerID: singer, status: { _ in })
            }
        }
        #expect(RinoaStubProtocol.fixture.captured().isEmpty)
    }
}
