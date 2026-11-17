import Foundation

public protocol ReferenceHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws
}

enum ReferenceHTTPValidation {
    static func isPublicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard
              !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.contains(":"),
              host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return true
    }
}

/// Serial delegate callbacks bound both unknown-length responses and downloads.
/// Downloads never become a file-sized Data allocation.
public struct URLSessionReferenceHTTPTransport: ReferenceHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        let operation = ReferenceHTTPOperation(request: request, maximumBytes: Int64(maximumBytes), destination: nil)
        return try await operation.execute()
    }
    public func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        var request = URLRequest(url: url); request.timeoutInterval = 120
        request.setValue("Unableton-ReferenceProcessing/1", forHTTPHeaderField: "User-Agent")
        let operation = ReferenceHTTPOperation(request: request, maximumBytes: maximumBytes, destination: destination)
        _ = try await operation.execute()
    }
}

private final class ReferenceHTTPOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let maximumBytes: Int64
    private let destination: URL?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var canceled = false
    // Mutable transfer state belongs to the serial delegate queue.
    private var file: FileHandle?
    private var data = Data()
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var failure: (any Error)?

    init(request: URLRequest, maximumBytes: Int64, destination: URL?) {
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        self.request = request; self.maximumBytes = maximumBytes; self.destination = destination
    }
    func execute() async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { start($0) }
        } onCancel: { self.cancel() }
    }
    private func start(_ continuation: CheckedContinuation<Data, any Error>) {
        do {
            guard maximumBytes > 0, let url = request.url, ReferenceHTTPValidation.isPublicHTTPS(url) else {
                throw ReferenceProcessingFailure("Song processing returned an unsupported URL or exceeded its storage allowance.")
            }
            if let destination {
                guard !FileManager.default.fileExists(atPath: destination.path),
                      FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw ReferenceProcessingFailure("Could not create the reference download file.")
                }
                file = try FileHandle(forWritingTo: destination)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = 900
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)
            let shouldCancel = lock.withLock {
                self.continuation = continuation; self.session = session; self.task = task
                return canceled
            }
            if shouldCancel { task.cancel() }
            task.resume()
        } catch {
            try? file?.close(); file = nil
            if let destination { try? FileManager.default.removeItem(at: destination) }
            continuation.resume(throwing: error)
        }
    }
    private func cancel() { lock.withLock { canceled = true; task?.cancel() } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest next: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let credentialed = request.value(forHTTPHeaderField: "Authorization") != nil
        let valid = next.url.map(ReferenceHTTPValidation.isPublicHTTPS) == true
            && (!credentialed || next.url?.host == request.url?.host)
        completionHandler(valid ? next : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = ReferenceProcessingFailure("Song processing returned HTTP \(status). The request was not retried.")
            completionHandler(.cancel); return
        }
        expected = response.expectedContentLength
        guard expected <= maximumBytes else {
            failure = ReferenceProcessingFailure("A song-processing response exceeded its size limit.")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard Int64(chunk.count) <= maximumBytes - received else {
            failure = ReferenceProcessingFailure("A song-processing response exceeded its size limit.")
            dataTask.cancel(); return
        }
        do {
            if let file { try file.write(contentsOf: chunk) } else { data.append(chunk) }
            received += Int64(chunk.count)
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        do { try file?.close() } catch { if failure == nil { failure = error } }; file = nil
        let outcome = lock.withLock {
            let result = (continuation, canceled); continuation = nil; self.task = nil; self.session = nil
            return result
        }
        session.finishTasksAndInvalidate()
        guard let continuation = outcome.0 else { return }
        let incomplete = expected >= 0 && received != expected
        if outcome.1 || failure != nil || error != nil || incomplete || received == 0 {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            if outcome.1 { continuation.resume(throwing: CancellationError()) }
            else { continuation.resume(throwing: failure ?? error ?? ReferenceProcessingFailure("The song-processing response was incomplete.")) }
        } else { continuation.resume(returning: data) }
    }
}
