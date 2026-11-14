import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private func jevResponse() -> JSONValue {
    let answers = Dictionary(uniqueKeysWithValues: JevDraftReviewer.questionIDs.map { question in
        (question, JSONValue.object(["type": .string("noul"), "noul": .number(question.hasSuffix("_issue") ? 0.1 : 0.95)]))
    })
    return .object(["model": .string(JevClient.model), "answers": .object(answers), "usage": .object(["input_tokens": .number(1200), "output_tokens": .number(80)])])
}

private actor StubJevTransport: JevTransport {
    var requests: [JSONValue] = []
    let response: JSONValue
    let delay: Duration?
    let failure: JevError?
    init(response: JSONValue = jevResponse(), delay: Duration? = nil, failure: JevError? = nil) {
        self.response = response; self.delay = delay; self.failure = failure
    }
    func send(body: JSONValue, apiKey: String) async throws -> JSONValue {
        requests.append(body)
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return response
    }
    func sent() -> [JSONValue] { requests }
}

private func analysisFixture() -> MusicalAnalysisReport {
    var before = Song()
    before.tracks = [Track(name: "/private/secret/recording.wav", clips: [Clip(notes: [NoteEvent()])])]
    var after = before; after.tracks[0].volume = 0.5
    return MusicalAnalyzer.analyze(before: before, after: after, selection: .init(trackID: before.tracks[0].id))
}

private final class JevHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(auth.hasPrefix("Bearer "))
        var status = 200, headers = ["Content-Type": "application/json"]
        var data = Data("{\"model\":\"jev-1.14.0\",\"answers\":{\"connection\":{\"type\":\"noul\",\"noul\":0.99}},\"usage\":{\"input_tokens\":20,\"output_tokens\":5}}".utf8)
        if auth.contains("failure-secret") { status = 401; data = Data("failure-secret".utf8) }
        if auth.contains("oversized") { headers["Content-Length"] = "2097153" }
        if auth.contains("invalid-json") { data = Data("invalid-json".utf8) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct JevReviewerTests {
    @Test func observerBatchesApplicableChecksAndOmitsPrivateNames() async throws {
        let stub = StubJevTransport(), reviewer = JevDraftReviewer(transport: stub)
        let analysis = analysisFixture()
        let observation = try await reviewer.review(prompt: "Lower the selected track.", summary: "Lowered its volume.", analysis: analysis, apiKey: "secret-key")
        let request = try #require(await stub.sent().first)
        #expect(request["model"]?.stringValue == "jev-1.14.0")
        #expect(request["tools"] == nil)
        if case .object(let questions) = request["questions"] { #expect(questions.count == 18) }
        else { Issue.record("Expected batched Noul questions") }
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("secret-key"))
        #expect(!encoded.contains("/private/secret"))
        #expect(!encoded.contains("recording.wav"))
        #expect(observation.mode == "observation" && observation.evidenceSource == "symbolic")
        #expect(observation.checks.count == 6 && observation.flaggedCount == 0)
        #expect(observation.inputTokens == 1200 && observation.outputTokens == 80)
        #expect(observation.checks.allSatisfy { $0.status == .noConcern })
        #expect(observation.durationSeconds >= 0)
        #expect(try JSONDecoder().decode(DraftReviewObservation.self, from: JSONEncoder().encode(observation)) == observation)
    }

    @Test func inapplicableOrUnmeasuredRequirementsAreNotReportedAsFailures() {
        let no = DraftReviewCheck(criterion: .vocalUse, applicabilityProbability: 0.1, issueProbability: 0.99, evidenceProbability: 0.99)
        #expect(no.status == .notApplicable)
        let missing = DraftReviewCheck(criterion: .melodyPreservation, applicabilityProbability: 0.99, issueProbability: 0.99, evidenceProbability: 0.2)
        #expect(missing.status == .insufficientEvidence)
        let unsure = DraftReviewCheck(criterion: .editScope, applicabilityProbability: 0.99, issueProbability: 0.5, evidenceProbability: 0.99)
        #expect(unsure.status == .uncertain)
        let flagged = DraftReviewCheck(criterion: .requestedParts, applicabilityProbability: 0.99, issueProbability: 0.95, evidenceProbability: 0.99)
        #expect(flagged.status == .flagged)
    }

    @Test func unicodePromptsAndLargeReportsFitTheBoundWithoutBrokenJSON() throws {
        var before = Song(), after = Song()
        before.lengthBars = 256; after.lengthBars = 256
        before.tracks = (0..<64).map { index in
            Track(name: String(repeating: "private track", count: 30), clips: (0..<20).map { clip in
                Clip(startBeat: Double(clip * 16), notes: [NoteEvent(pitch: 40 + index % 40)])
            })
        }
        after.tracks = before.tracks.map { track in var value = track; value.clips[0].notes[0].pitch += 1; return value }
        let analysis = MusicalAnalyzer.analyze(before: before, after: after, selection: .init())
        let request = try JevDraftReviewer.request(prompt: String(repeating: "🎶", count: 10000), summary: String(repeating: "Voice 🎤 ", count: 1000), analysis: analysis)
        let bytes = try JSONEncoder().encode(request.body)
        #expect(bytes.count <= JevDraftReviewer.maximumRequestBytes)
        #expect(request.promptTruncated && request.summaryTruncated && request.analysisTruncated)
        #expect(try JSONDecoder().decode(JSONValue.self, from: bytes) == request.body)
        #expect(request.body["state"]?["request"]?.stringValue?.contains("�") == false)
        #expect(request.body["state"]?["analysis"]?["after"]?["trackCount"]?.doubleValue == 64)
    }

    @Test func malformedResponsesNeverBecomeObservationsOrRetry() async throws {
        var responses: [JSONValue] = []
        var base = try #require(jevResponse().objectValueForTest)
        base["model"] = .string(""); responses.append(.object(base))
        base = try #require(jevResponse().objectValueForTest); base["usage"] = .object(["input_tokens": .number(0.5), "output_tokens": .number(1)]); responses.append(.object(base))
        for value in [JSONValue.number(-0.1), .number(1.1), .number(.nan), .string("0.9")] {
            base = try #require(jevResponse().objectValueForTest)
            var answers = try #require(base["answers"]?.objectValueForTest)
            answers["editScope_issue"] = .object(["type": .string("noul"), "noul": value]); base["answers"] = .object(answers)
            responses.append(.object(base))
        }
        base = try #require(jevResponse().objectValueForTest)
        var answers = try #require(base["answers"]?.objectValueForTest)
        answers.removeValue(forKey: "vocalUse_evidence"); base["answers"] = .object(answers); responses.append(.object(base))
        for response in responses {
            let stub = StubJevTransport(response: response)
            await #expect(throws: JevError.malformedResponse) {
                try await JevDraftReviewer(transport: stub).review(prompt: "Make music", summary: "Made music", analysis: analysisFixture(), apiKey: "test")
            }
            #expect(await stub.sent().count == 1)
        }
    }

    @Test func observerTimeoutAndCancellationPropagateWithoutRetries() async throws {
        let slow = StubJevTransport(delay: .seconds(30))
        await #expect(throws: JevError.timedOut) {
            try await JevDraftReviewer(transport: slow, timeout: 0.01).review(prompt: "Compose", summary: "Composed", analysis: analysisFixture(), apiKey: "test")
        }
        #expect(await slow.sent().count == 1)
        let cancel = StubJevTransport(delay: .seconds(30))
        let task = Task { try await JevDraftReviewer(transport: cancel).review(prompt: "Compose", summary: "Composed", analysis: analysisFixture(), apiKey: "test") }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cancel.sent().count == 1)
    }

    @Test func providerFailuresDoNotRetry() async {
        let stub = StubJevTransport(failure: .provider(429))
        await #expect(throws: JevError.provider(429)) {
            try await JevDraftReviewer(transport: stub).review(prompt: "Compose", summary: "Composed", analysis: analysisFixture(), apiKey: "test")
        }
        #expect(await stub.sent().count == 1)
    }

    @Test func nativeClientUsesOfficialEndpointAndSanitizesFailures() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [JevHTTPProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = JevClient(session: session)
        try await client.testConnection(apiKey: "test-key")
        do {
            try await client.testConnection(apiKey: "failure-secret")
            Issue.record("Expected provider error")
        } catch {
            #expect(error as? JevError == .provider(401))
            #expect(!error.localizedDescription.contains("failure-secret"))
        }
        await #expect(throws: JevError.responseTooLarge) { try await client.testConnection(apiKey: "oversized") }
        await #expect(throws: JevError.malformedResponse) { try await client.testConnection(apiKey: "invalid-json") }
    }
}

private extension JSONValue {
    var objectValueForTest: [String: JSONValue]? { if case .object(let object) = self { return object }; return nil }
}
