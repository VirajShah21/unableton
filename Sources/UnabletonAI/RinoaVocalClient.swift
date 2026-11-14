import Foundation
import UnabletonCore

/// Renders an explicit melody and its aligned lyrics. POST /sing is never retried:
/// a canceled or failed connection may already have consumed provider credits.
public struct RinoaVocalClient: VocalGenerating {
    public var providerID: String { "rinoa" }
    private let apiKey: String
    private let session: URLSession
    private static let maximumDownloadBytes = 32 * 1024 * 1024
    private static let maximumLineBytes = 64 * 1024
    private static let maximumStreamBytes = 4 * 1024 * 1024
    private static let maximumEvents = 2048

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func singers() async throws -> [VocalSinger] {
        do {
            let request = try authorizedRequest(path: "list-singers")
            let (bytes, response) = try await session.bytes(for: request, delegate: VocalRedirectPolicy(allowAssetRedirects: false))
            let data = try await read(bytes, response: response, maximum: 512 * 1024)
            try checkHTTP(response, data: data)
            let result = try JSONDecoder().decode([VocalSinger].self, from: data)
            guard result.count <= 512, result.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 512 }) else {
                throw VocalServiceError.invalidResponse("Rinoa returned an invalid singer list.")
            }
            return result
        } catch { throw normalized(error) }
    }

    public func render(score: VocalScore, singerID: String, status: @escaping @Sendable (String) -> Void) async throws -> Data {
        try score.validate()
        guard score.durationSeconds <= 60 else { throw VocalServiceError.limit("Render a vocal phrase of 60 seconds or less.") }
        guard !singerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, singerID.utf8.count <= 512 else {
            throw VocalServiceError.configuration("Choose a singer before generating vocals.")
        }
        let xml = try score.musicXML()
        guard xml.utf8.count <= 1024 * 1024 else { throw VocalServiceError.limit("The vocal score is too large. Use a shorter phrase.") }
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await renderOnce(xml: xml, singerID: singerID, status: status) }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw VocalServiceError.limit("Rinoa took too long. Check the provider before retrying; the request may already have used credits.")
                }
                defer { group.cancelAll() }
                guard let data = try await group.next() else { throw CancellationError() }
                return data
            }
        } catch { throw normalized(error) }
    }

    private func renderOnce(xml: String, singerID: String, status: @escaping @Sendable (String) -> Void) async throws -> Data {
        var request = try authorizedRequest(path: "sing")
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(SingRequest(scoreContent: xml, singerID: singerID, sessionID: UUID().uuidString))
        status("Sending the vocal score to Rinoa…")
        let (bytes, response) = try await session.bytes(for: request, delegate: VocalRedirectPolicy(allowAssetRedirects: false))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = try await read(bytes, response: response, maximum: 64 * 1024)
            try checkHTTP(response, data: body)
            throw VocalServiceError.invalidResponse("Rinoa returned an invalid response.")
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw VocalServiceError.invalidResponse("Rinoa did not return a vocal generation stream.")
        }
        var line = Data(), byteCount = 0, lineCount = 0, eventCount = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            byteCount += 1
            guard byteCount <= Self.maximumStreamBytes else { throw VocalServiceError.limit("Rinoa returned too much progress data.") }
            if byte == 10 {
                lineCount += 1
                guard lineCount <= 8192 else { throw VocalServiceError.limit("Rinoa returned too many progress lines.") }
                if let url = try consume(line: line, eventCount: &eventCount, status: status) {
                    status("Downloading the vocal recording…")
                    return try await download(url)
                }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < Self.maximumLineBytes else { throw VocalServiceError.limit("Rinoa returned a progress event that was too large.") }
                line.append(byte)
            }
        }
        try Task.checkCancellation()
        if !line.isEmpty, let url = try consume(line: line, eventCount: &eventCount, status: status) {
            status("Downloading the vocal recording…")
            return try await download(url)
        }
        throw VocalServiceError.invalidResponse("Rinoa disconnected before the vocal recording was complete. Check the provider before retrying; credits may already have been used.")
    }

    private func consume(line bytes: Data, eventCount: inout Int, status: @Sendable (String) -> Void) throws -> URL? {
        guard let line = String(data: bytes, encoding: .utf8) else { throw VocalServiceError.invalidResponse("Rinoa returned invalid text in its progress stream.") }
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return nil }
        eventCount += 1
        guard eventCount <= Self.maximumEvents else { throw VocalServiceError.limit("Rinoa returned too many progress events.") }
        let event: SingEvent
        do { event = try JSONDecoder().decode(SingEvent.self, from: Data(payload.utf8)) }
        catch { throw VocalServiceError.invalidResponse("Rinoa returned an unreadable progress event.") }
        switch event.status {
        case "heartbeat": return nil
        case "processing":
            if let completed = event.batchProgress, let total = event.totalBatches,
               completed.isFinite, total.isFinite, total > 0, total <= 100_000, completed >= 0, completed <= total {
                status("Rendering vocals (\(Int(completed))/\(Int(total)))…")
            } else { status("Rendering vocals…") }
            return nil
        case "error": throw VocalServiceError.provider(status: 200, message: String((event.message ?? "Rinoa could not render this vocal phrase.").prefix(1024)))
        case "completed":
            guard let outputs = event.outputs, !outputs.audioFiles.isEmpty else { throw VocalServiceError.invalidResponse("Rinoa completed without a vocal recording.") }
            guard outputs.audioFiles.count == 1 else {
                throw VocalServiceError.invalidResponse("Rinoa returned several vocal files without timing information. Render a smaller phrase so it produces a single file.")
            }
            // The provider's web clients do not rely on audio_format. Some
            // responses use MIME labels rather than file extensions. Verify the
            // downloaded container, then the workflow fully decodes the WAV.
            guard let url = URL(string: outputs.audioFiles[0]), Self.isSafeAssetURL(url) else {
                throw VocalServiceError.invalidResponse("Rinoa returned an invalid recording URL. Only HTTPS URLs without embedded credentials are accepted.")
            }
            return url
        default: throw VocalServiceError.invalidResponse("Rinoa returned an unsupported vocal generation status.")
        }
    }

    private func download(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        // Keep the caller's protocol configuration for tests/network setup, but
        // never inherit Authorization, cookies, or stored HTTP credentials.
        let configuration = session.configuration
        configuration.httpAdditionalHeaders = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let downloader = URLSession(configuration: configuration)
        defer { downloader.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await downloader.bytes(for: request, delegate: VocalRedirectPolicy(allowAssetRedirects: true))
        guard let finalURL = response.url, Self.isSafeAssetURL(finalURL) else { throw VocalServiceError.invalidResponse("The recording download redirected to an invalid URL.") }
        let data = try await read(bytes, response: response, maximum: Self.maximumDownloadBytes)
        try checkHTTP(response, data: data)
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw VocalServiceError.invalidResponse("Rinoa did not provide a WAV recording. Check that your plan includes downloadable WAV/API output; its Free plan excludes downloads. No vocal audio was imported.")
        }
        return data
    }

    private func authorizedRequest(path: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw VocalServiceError.configuration("Add a Rinoa API key in Settings to generate singing.") }
        var request = URLRequest(url: URL(string: "https://api.rinoa.ai/\(path)")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
    private func read(_ bytes: URLSession.AsyncBytes, response: URLResponse, maximum: Int) async throws -> Data {
        guard response.expectedContentLength <= Int64(maximum) else { throw VocalServiceError.limit("The vocal service response exceeds the allowed download size.") }
        var data = Data(); data.reserveCapacity(min(maximum, 64 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximum else { throw VocalServiceError.limit("The vocal recording exceeds the 32 MiB download limit.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
    private func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw VocalServiceError.invalidResponse("The vocal service returned an invalid HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { var message: String?; var detail: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw VocalServiceError.provider(status: http.statusCode, message: String((failure?.message ?? failure?.detail ?? "Rinoa request failed (HTTP \(http.statusCode)).").prefix(1024)))
        }
    }
    private func normalized(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? VocalServiceError { return error }
        return VocalServiceError.transport(error.localizedDescription)
    }
    fileprivate static func isSafeAssetURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.absoluteString.utf8.count <= 8192
    }
}

private struct SingRequest: Encodable {
    let scoreContent: String
    let scoreFormat = "musicxml"
    let singerID: String
    let sessionID: String
    enum CodingKeys: String, CodingKey { case scoreContent = "score_content", scoreFormat = "score_format", singerID = "singer_id", sessionID = "session_id" }
}
private struct SingEvent: Decodable {
    let status: String
    let message: String?
    let batchProgress: Double?
    let totalBatches: Double?
    let outputs: SingOutputs?
    enum CodingKeys: String, CodingKey { case status, message, batchProgress = "batch_progress", totalBatches = "total_batches", outputs }
}
private struct SingOutputs: Decodable {
    let audioFiles: [String]
    let audioFormat: String?
    enum CodingKeys: String, CodingKey { case audioFiles = "audio_files", audioFormat = "audio_format" }
}
private final class VocalRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowAssetRedirects: Bool
    init(allowAssetRedirects: Bool) { self.allowAssetRedirects = allowAssetRedirects }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard allowAssetRedirects, let url = request.url, RinoaVocalClient.isSafeAssetURL(url) else { completionHandler(nil); return }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitized.httpShouldHandleCookies = false
        completionHandler(sanitized)
    }
}
