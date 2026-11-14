import Foundation
import UnabletonCore

/// Native client for Audial's documented text2vox API. The reference is supplied
/// by the user; it is never selected or cloned by the language model.
public struct AudialVocalClient: VocalGenerating {
    public let providerID = "audial"
    private let apiKey: String
    private let userID: String
    private let referenceAudio: Data
    private let referenceFileName: String
    private let session: URLSession
    private static let api = URL(string: "https://api.audialmusic.ai/api")!
    private static let maximumBytes = 32 * 1_024 * 1_024

    public init(apiKey: String, userID: String, referenceAudio: Data, referenceFileName: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.userID = userID; self.referenceAudio = referenceAudio
        self.referenceFileName = referenceFileName; self.session = session
    }

    public func singers() async throws -> [VocalSinger] {
        try checkConfiguration()
        return [VocalSinger(name: "Reference voice", language: "english", style: "User-provided reference")]
    }

    public func render(score: VocalScore, singerID: String, status: @escaping @Sendable (String) -> Void) async throws -> Data {
        try Task.checkCancellation()
        try checkConfiguration()
        try score.validate()
        guard singerID == "Reference voice" else { throw VocalServiceError.configuration("Choose Reference voice for Audial vocals.") }
        guard !referenceAudio.isEmpty, referenceAudio.count <= Self.maximumBytes else {
            throw VocalServiceError.configuration("Choose a 5–10 second reference voice recording smaller than 32 MiB in Settings.")
        }
        // A pipe is Audial's token delimiter, and '+' is another hold marker.
        // Reject them here so one model-authored syllable stays one MIDI note.
        guard score.lyrics.allSatisfy({ !$0.contains("|") && $0 != "+" }) else {
            throw VocalServiceError.configuration("Vocal syllables cannot contain '|' or '+'. Use '-' to hold the previous syllable.")
        }
        let boundary = "Unableton-\(UUID().uuidString)"
        var body = Data()
        func text(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        func file(_ name: String, _ filename: String, _ mime: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            body.append(data); body.append(Data("\r\n".utf8))
        }
        text("userId", userID)
        text("text2vox.lyricsMode", "per_note")
        text("text2vox.lyrics", score.lyrics.map { $0 != "-" && $0.hasSuffix("-") ? String($0.dropLast()) : $0 }.joined(separator: "|"))
        file("original", Self.safeFileName(referenceFileName), Self.mimeType(referenceFileName), referenceAudio)
        file("text2vox.midi", "vocal-melody.mid", "audio/midi", try Self.midiData(score))
        body.append(Data("--\(boundary)--\r\n".utf8))
        guard body.count <= Self.maximumBytes else { throw VocalServiceError.limit("The vocal upload exceeds 32 MiB.") }
        var request = authenticated(Self.api.appendingPathComponent("functions/run/text2vox"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        status("Uploading lyrics, melody, and reference voice to Audial…")
        // Never retry this POST: a missing response can still mean a paid job
        // was accepted. A user retry must be an explicit new generation.
        var execution = try await json(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while execution["state"] as? String != "completed" {
            try Task.checkCancellation()
            let state = execution["state"] as? String ?? ""
            if state == "failed" || state == "cancelled" {
                throw VocalServiceError.provider(status: 422, message: "Audial could not render this vocal. Check the melody, lyrics, and account in Audial before retrying.")
            }
            guard let executionID = (execution["exeId"] ?? execution["exe_id"]) as? String,
                  Self.validIdentifier(executionID) else {
                throw VocalServiceError.invalidResponse("Audial did not return a vocal job ID. Check your Audial jobs before retrying; the request may have been accepted.")
            }
            guard ContinuousClock.now < deadline else {
                throw VocalServiceError.limit("Audial's vocal job is still running. Check the job in Audial before starting another render.")
            }
            status("Generating singing in Audial…")
            try await Task.sleep(for: .seconds(2))
            let url = Self.api.appendingPathComponent("db").appendingPathComponent(userID).appendingPathComponent("execution").appendingPathComponent(executionID)
            execution = try await json(authenticated(url))
        }
        guard let generated = execution["generated"] as? [String: Any] else {
            throw VocalServiceError.invalidResponse("Audial finished without a vocal audio file.")
        }
        let candidates = generated.values.compactMap { $0 as? [String: Any] }.filter { item in
            let filename = (item["filename"] as? String ?? "").lowercased()
            let path = URL(string: item["url"] as? String ?? "")?.path.lowercased() ?? ""
            return filename.hasSuffix(".wav") || path.hasSuffix(".wav")
        }
        guard candidates.count == 1, let rawURL = candidates[0]["url"] as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw VocalServiceError.invalidResponse("Audial did not return one secure WAV vocal download.")
        }
        status("Downloading the generated vocal…")
        // Signed output URLs receive no API key or user ID headers.
        let configuration = session.configuration
        configuration.httpAdditionalHeaders = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let downloadSession = URLSession(configuration: configuration)
        defer { downloadSession.invalidateAndCancel() }
        let data = try await boundedData(URLRequest(url: url, timeoutInterval: 60), maximum: Self.maximumBytes, authenticated: false, using: downloadSession)
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw VocalServiceError.invalidResponse("Audial's vocal download was not a WAV file.")
        }
        return data
    }

    private func checkConfiguration() throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.validIdentifier(userID) else {
            throw VocalServiceError.configuration("Add an Audial API key and user ID in Settings.")
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !value.isEmpty && value.utf8.count <= 200 && value.allSatisfy { allowed.contains($0) }
    }

    private func authenticated(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await boundedData(request, maximum: 1_024 * 1_024, authenticated: true)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VocalServiceError.invalidResponse("Audial returned an unreadable response.")
        }
        return object
    }

    private func boundedData(_ request: URLRequest, maximum: Int, authenticated: Bool, using overrideSession: URLSession? = nil) async throws -> Data {
        do {
            let delegate = AudialRedirectPolicy(allowedHost: authenticated ? Self.api.host : nil)
            let (bytes, response) = try await (overrideSession ?? session).bytes(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse else { throw VocalServiceError.invalidResponse("Audial returned an invalid HTTP response.") }
            guard (200...299).contains(response.statusCode) else {
                let message: String
                switch response.statusCode {
                case 401, 403: message = "Audial rejected the API key or user ID. Check vocal settings."
                case 402: message = "Audial requires an active subscription or available trial runs for vocal generation."
                case 400: message = "Audial rejected this vocal score. Check the monophonic melody and one syllable per note."
                case 429: message = "Audial is busy or rate limited. Try again later."
                default: message = "Audial could not complete the request (HTTP \(response.statusCode))."
                }
                throw VocalServiceError.provider(status: response.statusCode, message: message)
            }
            guard response.expectedContentLength <= maximum else { throw VocalServiceError.limit("Audial's response exceeds the allowed file size.") }
            var data = Data()
            data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 4096)
            for try await byte in bytes {
                guard data.count < maximum else { throw VocalServiceError.limit("Audial's response exceeds the allowed file size.") }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as VocalServiceError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // Transport descriptions can contain signed URLs or server bodies.
            throw VocalServiceError.transport("Unable to reach Audial. Check the connection and your Audial jobs before retrying.")
        }
    }

    private static func safeFileName(_ filename: String) -> String {
        let value = (filename as NSString).lastPathComponent
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let result = String(value.map { allowed.contains($0) ? $0 : "_" }.prefix(120))
        return result.isEmpty ? "reference.wav" : result
    }
    private static func mimeType(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "m4a": "audio/mp4"
        case "aif", "aiff": "audio/aiff"
        default: "audio/wav"
        }
    }

    /// Standard MIDI type 1, with exact beat timing and lyric meta events.
    /// Audial also receives per-note lyrics explicitly, including hold markers.
    static func midiData(_ score: VocalScore) throws -> Data {
        try score.validate()
        func be(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        func vlq(_ value: Int) -> [UInt8] {
            var value = value, bytes = [UInt8(value & 127)]; value >>= 7
            while value > 0 { bytes.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
            return bytes
        }
        struct Event { let tick: Int; let priority: Int; let bytes: [UInt8] }
        func track(_ events: [Event], end: Int) -> [UInt8] {
            var data: [UInt8] = [], cursor = 0
            for event in events.sorted(by: { $0.tick == $1.tick ? $0.priority < $1.priority : $0.tick < $1.tick }) {
                data += vlq(event.tick - cursor) + event.bytes; cursor = event.tick
            }
            data += vlq(max(0, end - cursor)) + [0xFF, 0x2F, 0]
            return Array("MTrk".utf8) + be(data.count, 4) + data
        }
        let ppq = 960, end = Int((score.lengthBeats * 960).rounded())
        let tempo = Int((60_000_000 / score.tempo).rounded())
        var data = Array("MThd".utf8) + be(6, 4) + be(1, 2) + be(2, 2) + be(ppq, 2)
        data += track([Event(tick: 0, priority: 0, bytes: [0xFF, 0x51, 3] + be(tempo, 3)), Event(tick: 0, priority: 0, bytes: [0xFF, 0x58, 4, UInt8(score.beatsPerBar), 2, 24, 8])], end: end)
        var events: [Event] = []
        for (note, lyric) in zip(score.notes, score.lyrics) {
            let tick = Int((note.startBeat * 960).rounded())
            if lyric != "-" { let text = Array(lyric.utf8); events.append(Event(tick: tick, priority: 1, bytes: [0xFF, 0x05] + vlq(text.count) + text)) }
            events.append(Event(tick: tick, priority: 2, bytes: [0x90, UInt8(note.pitch), UInt8(note.velocity)]))
            events.append(Event(tick: Int(((note.startBeat + note.duration) * 960).rounded()), priority: 0, bytes: [0x80, UInt8(note.pitch), 0]))
        }
        data += track(events, end: end)
        return Data(data)
    }
}

private final class AudialRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowedHost: String?
    init(allowedHost: String?) { self.allowedHost = allowedHost }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              allowedHost == nil || url.host == allowedHost else { completionHandler(nil); return }
        var redirect = request
        if allowedHost == nil {
            for header in ["X-API-Key", "X-User-ID", "Authorization", "Cookie", "Proxy-Authorization"] {
                redirect.setValue(nil, forHTTPHeaderField: header)
            }
        }
        completionHandler(redirect)
    }
}
