import Foundation
import UnabletonCore

/// URLSession streams received chunks straight to a staging file. It does not
/// retain an archive-sized Data value or retry failed requests.
public struct HTTPBankDownloader: SoundBankDownloading {
    public init() {}
    public func download(_ bank: SoundBank, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard bank.url.scheme?.lowercased() == "https", bank.downloadBytes > 0 else {
            throw SoundLibraryError.validation("The catalog has an invalid download URL or size.")
        }
        let operation = DownloadOperation(bank: bank, destination: destination, progress: progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in operation.start(continuation) }
        } onCancel: { operation.cancel() }
    }
}

private final class DownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let bank: SoundBank
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var canceled = false
    // These are accessed only on the serial URLSession delegate queue.
    private var file: FileHandle?
    private var received: Int64 = 0
    private var lastProgress = ContinuousClock.now
    private var failure: (any Error)?

    init(bank: SoundBank, destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.bank = bank; self.destination = destination; self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<Void, any Error>) {
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw SoundLibraryError.validation("Unable to create the download staging file.")
            }
            file = try FileHandle(forWritingTo: destination)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 1800
            configuration.urlCache = nil
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            var request = URLRequest(url: bank.url)
            request.setValue("Unableton-SoundLibrary/1", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request)
            let shouldCancel = lock.withLock {
                self.continuation = continuation; self.session = session; self.task = task
                return canceled
            }
            if shouldCancel { task.cancel() }
            task.resume()
        } catch {
            try? file?.close(); file = nil
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        let task = lock.withLock { canceled = true; return self.task }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= bank.downloadBytes else {
            failure = SoundLibraryError.validation("The sound download returned an invalid response or exceeded its pinned size.")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= bank.downloadBytes - received else {
            failure = SoundLibraryError.validation("The sound download exceeded its pinned size.")
            dataTask.cancel(); return
        }
        do {
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            let now = ContinuousClock.now
            if received == bank.downloadBytes || lastProgress.duration(to: now) >= .milliseconds(100) {
                lastProgress = now; progress(received, bank.downloadBytes)
            }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        do { try file?.close() } catch { if failure == nil { failure = error } }
        file = nil
        let outcome: (CheckedContinuation<Void, any Error>?, Bool) = lock.withLock {
            let result = (continuation, canceled); continuation = nil; self.task = nil; self.session = nil
            return result
        }
        session.finishTasksAndInvalidate()
        guard let continuation = outcome.0 else { return }
        if outcome.1 { continuation.resume(throwing: CancellationError()) }
        else if let failure = failure ?? error { continuation.resume(throwing: failure) }
        else if received != bank.downloadBytes {
            continuation.resume(throwing: SoundLibraryError.validation("The sound download was incomplete."))
        } else { continuation.resume() }
    }
}
