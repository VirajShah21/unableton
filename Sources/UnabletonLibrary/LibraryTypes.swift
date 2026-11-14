import Foundation
import UnabletonCore

public enum SoundBankState: Sendable, Equatable {
    case notInstalled
    case queued
    case downloading(received: Int64, total: Int64)
    case verifying
    case installing
    case installed(bytes: Int64, inUse: Bool)
    case failed(String)

    public var isInstalled: Bool { if case .installed = self { true } else { false } }
    public var isBusy: Bool {
        switch self { case .queued, .downloading, .verifying, .installing: true; default: false }
    }
}

/// Progress and cancellation ownership from one consistent actor snapshot.
public struct SoundBankActivity: Sendable, Equatable, Identifiable {
    public let bankID: String
    public let state: SoundBankState
    public let libraryRequested: Bool
    public let requiredByOtherOperations: Bool
    public let completedAt: Date?
    public var id: String { bankID }
    public init(bankID: String, state: SoundBankState, libraryRequested: Bool = false,
                requiredByOtherOperations: Bool = false, completedAt: Date? = nil) {
        self.bankID = bankID; self.state = state; self.libraryRequested = libraryRequested
        self.requiredByOtherOperations = requiredByOtherOperations
        self.completedAt = completedAt
    }
}

public struct SoundImportFailure: Sendable, Equatable {
    public let fileName: String
    public let message: String
    public init(fileName: String, message: String) { self.fileName = fileName; self.message = message }
}

public struct SoundImportReport: Sendable, Equatable {
    /// Includes exact matching files that were already installed. Each bank is
    /// listed once even if selected more than once. Originals stay unchanged.
    public let importedBankIDs: [String]
    public let failures: [SoundImportFailure]
    public init(importedBankIDs: [String], failures: [SoundImportFailure]) {
        self.importedBankIDs = importedBankIDs; self.failures = failures
    }
}

public enum SoundLibraryError: LocalizedError, Sendable, Equatable {
    case unknownBank(String), unknownInstrument(String), missingBanks([String]), busy(String), validation(String)
    public var errorDescription: String? {
        switch self {
        case .unknownBank(let id): "Unknown sound bank: \(id)."
        case .unknownInstrument(let id): "Unknown instrument: \(id)."
        case .missingBanks: "Download the required sounds in Sound Library before playing or rendering."
        case .busy: "This sound is in use. Stop playback and wait for rendering or generation before removing it."
        case .validation(let message): message
        }
    }
}

public protocol SoundBankDownloading: Sendable {
    func download(_ bank: SoundBank, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

public protocol SoundBankExtracting: Sendable {
    func extract(_ bank: SoundBank, archive: URL, to destination: URL) async throws
}

/// Test injection points for filesystem failures such as disk exhaustion.
public enum LibraryFileOperation: Sendable { case prepareStaging, copyImport, install }

/// Immutable file handles for a prepared graph or draft. Keep this object alive
/// for the entire operation; removal is unavailable until its final release.
public final class SoundLibraryLease: @unchecked Sendable {
    public let urls: [String: URL]
    private let lock = NSLock()
    private var releaser: (@Sendable () async -> Void)?

    init(urls: [String: URL], releaser: @escaping @Sendable () async -> Void) {
        self.urls = urls; self.releaser = releaser
    }
    public func release() async {
        let action = lock.withLock { let action = releaser; releaser = nil; return action }
        await action?()
    }
    deinit {
        let action = lock.withLock { let action = releaser; releaser = nil; return action }
        if let action { Task { await action() } }
    }
}
