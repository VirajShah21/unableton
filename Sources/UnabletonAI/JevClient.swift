import Foundation
import UnabletonCore

/// Jev has a different wire format from the composer's Responses API.
public protocol JevTransport: Sendable {
    func send(body: JSONValue, apiKey: String) async throws -> JSONValue
}

public enum JevError: LocalizedError, Sendable, Equatable {
    case configuration, transport, provider(Int), malformedResponse, responseTooLarge, payloadTooLarge, timedOut

    public var errorDescription: String? {
        switch self {
        case .configuration: "Save a Jev API key to enable draft observations."
        case .transport: "Could not connect to Jev. The music was not changed by the reviewer."
        case .provider(let status): "Jev returned HTTP \(status). The reviewer did not retry."
        case .malformedResponse: "Jev returned an invalid observation."
        case .responseTooLarge: "Jev's response exceeded the observation size limit."
        case .payloadTooLarge: "The draft observation exceeded its size limit."
        case .timedOut: "Jev's observation timed out."
        }
    }
}

/// No retries: this optional observer must not become an additional agent loop.
public struct JevClient: JevTransport {
    public static let model = "jev-1.14.0"
    private let session: URLSession
    private static let maximumResponseBytes = 2 * 1024 * 1024

    public init(session: URLSession = .shared) { self.session = session }

    public func send(body: JSONValue, apiKey: String) async throws -> JSONValue {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 1024, !key.contains(where: { $0.isNewline }) else { throw JevError.configuration }
        let data = try JSONEncoder().encode(body)
        guard data.count <= JevDraftReviewer.maximumRequestBytes else { throw JevError.payloadTooLarge }
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw JevError.transport }
            guard (200..<300).contains(http.statusCode) else { throw JevError.provider(http.statusCode) }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw JevError.responseTooLarge }
            var responseData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard responseData.count < Self.maximumResponseBytes else { throw JevError.responseTooLarge }
                responseData.append(byte)
            }
            do { return try JSONDecoder().decode(JSONValue.self, from: responseData) }
            catch { throw JevError.malformedResponse }
        } catch is CancellationError { throw CancellationError() }
        catch let error as JevError { throw error }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw JevError.timedOut }
            throw JevError.transport
        } catch { throw JevError.transport }
    }

    public func testConnection(apiKey: String) async throws {
        let body: JSONValue = .object([
            "model": .string(Self.model), "state": .object(["connected": .bool(true)]),
            "questions": .object(["connection": .object(["type": .string("noul"), "instructions": .string("Is connected true in the supplied state?")])])
        ])
        let response = try await withJevDeadline(seconds: 8) { try await send(body: body, apiKey: apiKey) }
        let decoded = try JevResponse.decode(response, questions: ["connection"])
        guard decoded.probabilities["connection", default: 0] >= 0.7 else { throw JevError.malformedResponse }
    }
}

func withJevDeadline<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds.isFinite, seconds > 0 else { throw JevError.timedOut }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(min(8, seconds)))
            throw JevError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
}

struct JevResponse {
    var model: String
    var probabilities: [String: Double]
    var inputTokens: Int
    var outputTokens: Int

    static func decode(_ response: JSONValue, questions: [String]) throws -> JevResponse {
        guard let model = response["model"]?.stringValue, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 128,
              case .object(let answers) = response["answers"], Set(answers.keys) == Set(questions),
              let input = tokenCount(response["usage"]?["input_tokens"]), let output = tokenCount(response["usage"]?["output_tokens"]) else {
            throw JevError.malformedResponse
        }
        var probabilities: [String: Double] = [:]
        for question in questions {
            guard answers[question]?["type"]?.stringValue == "noul", let value = answers[question]?["noul"]?.doubleValue,
                  value.isFinite, (0...1).contains(value) else { throw JevError.malformedResponse }
            probabilities[question] = value
        }
        return JevResponse(model: model, probabilities: probabilities, inputTokens: input, outputTokens: output)
    }

    private static func tokenCount(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number.isFinite, number >= 0, number <= 10_000_000, number.rounded() == number else { return nil }
        return Int(number)
    }
}
