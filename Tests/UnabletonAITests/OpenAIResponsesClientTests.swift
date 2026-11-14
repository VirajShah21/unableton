import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI

private final class StubStreamProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = """
        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","delta":"partial arguments"}

        event: response.completed
        data: {"type":"response.completed","response":{"status":"completed","model":"test-model","output":[]}}


        """
        client?.urlProtocol(self, didLoad: Data(events.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct OpenAIResponsesClientTests {
    @Test func nativeURLSessionReadsCompleteSSEEvents() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubStreamProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let response = try await OpenAIResponsesClient(session: session).send(body: .object([:]), apiKey: "test", status: { _ in })
        #expect(response["status"]?.stringValue == "completed")
        #expect(response["model"]?.stringValue == "test-model")
    }
}
