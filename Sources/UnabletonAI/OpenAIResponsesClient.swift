import Foundation
import UnabletonCore

/// Reads complete Responses events. Tool arguments are never executed from deltas.
public struct OpenAIResponsesClient: ResponsesTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func availableModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentError.configuration(value["error"]?["message"]?.stringValue ?? "Could not refresh available models.")
        }
        let accountIDs = Set(value["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? [])
        return ModelRouting.supportedModelIDs.filter { accountIDs.contains($0) }
    }

    public func send(body: JSONValue, apiKey: String, status: @escaping @Sendable (String) -> Void) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentError.transport("OpenAI returned an invalid response.") }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { if data.count < 16_384 { data.append(byte) } else { break } }
                let json = try? JSONDecoder().decode(JSONValue.self, from: data)
                throw AgentError.provider(status: http.statusCode, message: json?["error"]?["message"]?.stringValue ?? "OpenAI request failed (HTTP \(http.statusCode)).")
            }
            var decoder = ResponseEventDecoder()
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let event = try decoder.accept(line: line) {
                    if let completed = try Self.handle(event, status: status) { return completed }
                }
            }
            if let event = try decoder.finish(), let completed = try Self.handle(event, status: status) { return completed }
            throw AgentError.incomplete("The connection ended before generation finished. The project was not changed.")
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw AgentError.transport(error.localizedDescription)
        }
    }

    static func handle(_ event: JSONValue, status: @Sendable (String) -> Void) throws -> JSONValue? {
        switch event["type"]?.stringValue {
        case "response.created", "response.in_progress": status("Composing…")
        case "response.output_item.added":
            if let name = event["item"]?["name"]?.stringValue { status("Using \(name.replacingOccurrences(of: "_", with: " "))…") }
        case "response.completed":
            guard let response = event["response"], response["status"]?.stringValue == "completed" else {
                throw AgentError.incomplete("OpenAI did not finish the response. The project was not changed.")
            }
            return response
        case "response.incomplete":
            // Preserve usage from incomplete model output for routing accounting.
            // The harness rejects its output without executing any tool calls.
            if let response = event["response"] { return response }
            throw AgentError.incomplete("Generation reached an output limit. The project was not changed. Try a shorter section.")
        case "response.failed", "error":
            throw AgentError.provider(status: 400, message: event["response"]?["error"]?["message"]?.stringValue ?? event["error"]?["message"]?.stringValue ?? event["message"]?.stringValue ?? "OpenAI could not complete this request.")
        default: break
        }
        return nil
    }
}

struct ResponseEventDecoder {
    private var payload: [String] = []
    private var size = 0
    mutating func accept(line: String) throws -> JSONValue? {
        if line.isEmpty { return try finish() }
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        size += value.utf8.count
        guard size <= 8_388_608 else { throw AgentError.incomplete("OpenAI returned a response that was too large.") }
        payload.append(value)
        // AsyncBytes.lines omits empty lines. OpenAI sends one complete JSON object
        // per data line, so consume a complete object immediately rather than
        // relying on the SSE blank separator being delivered by that sequence.
        let text = payload.joined(separator: "\n")
        if text == "[DONE]" { payload = []; size = 0; return nil }
        if let event = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
            payload = []; size = 0
            return event
        }
        return nil
    }
    mutating func finish() throws -> JSONValue? {
        guard !payload.isEmpty else { return nil }
        let text = payload.joined(separator: "\n")
        payload = []; size = 0
        if text == "[DONE]" { return nil }
        do { return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        catch { throw AgentError.incomplete("OpenAI returned an unreadable stream event. The project was not changed.") }
    }
}
