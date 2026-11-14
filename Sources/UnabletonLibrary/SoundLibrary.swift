import Foundation
import UnabletonCore

/// Installation state is global to the app, independent of any song or window.
public actor SoundLibrary {
    public static let shared = SoundLibrary()
    public nonisolated let root: URL
    private let banks: [String: SoundBank]
    private let presets: [String: InstrumentPreset]
    private let downloader: any SoundBankDownloading
    private let extractor: any SoundBankExtracting
    private let fileCheck: @Sendable (LibraryFileOperation) throws -> Void
    private var preparation: Task<[String: BankFileStamp], any Error>?
    private var verifiedFiles: [String: BankFileStamp] = [:]
    private var prepared = false
    private var installed = Set<String>()
    private var completedAt: [String: Date] = [:]
    private var states: [String: SoundBankState] = [:]
    private var leases: [UUID: Set<String>] = [:]
    private var observers: [UUID: AsyncStream<[String: SoundBankState]>.Continuation] = [:]
    private var activityObservers: [UUID: AsyncStream<[String: SoundBankActivity]>.Continuation] = [:]
    private struct Job {
        let token = UUID()
        var manualOwner = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var task: Task<Void, Never>?
    }
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var active = Set<String>()

    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Unableton/SoundLibrary", isDirectory: true),
        banks: [SoundBank] = SoundBankCatalog.banks,
        presets: [InstrumentPreset] = InstrumentCatalog.presets,
        downloader: any SoundBankDownloading = HTTPBankDownloader(),
        extractor: any SoundBankExtracting = TarBankExtractor(),
        fileCheck: @escaping @Sendable (LibraryFileOperation) throws -> Void = { _ in }) {
        self.root = root
        self.banks = Dictionary(uniqueKeysWithValues: banks.map { ($0.id, $0) })
        self.presets = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        self.downloader = downloader; self.extractor = extractor; self.fileCheck = fileCheck
        states = Dictionary(uniqueKeysWithValues: banks.map { ($0.id, .notInstalled) })
    }

    public func snapshot() async -> [String: SoundBankState] {
        do { try await prepare() }
        catch { for id in banks.keys where !installed.contains(id) { states[id] = .failed(error.localizedDescription) } }
        return currentStates()
    }

    public func updates() async -> AsyncStream<[String: SoundBankState]> {
        _ = await snapshot()
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(currentStates())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    public func activitySnapshot() async -> [String: SoundBankActivity] {
        _ = await snapshot()
        return currentActivities()
    }

    public func activityUpdates() async -> AsyncStream<[String: SoundBankActivity]> {
        _ = await snapshot()
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            activityObservers[id] = continuation
            continuation.yield(currentActivities())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeActivityObserver(id) } }
        }
    }

    /// Start a download owned by the Library window, without awaiting completion.
    public func requestDownload(bankID: String) async throws {
        try await prepare(); try Task.checkCancellation()
        guard banks[bankID] != nil else { throw SoundLibraryError.unknownBank(bankID) }
        if installed.contains(bankID) { return }
        if let task = jobs[bankID]?.task, task.isCancelled { await task.value; try Task.checkCancellation() }
        if jobs[bankID] == nil { jobs[bankID] = Job(); queue.append(bankID); states[bankID] = .queued }
        jobs[bankID]?.manualOwner = true
        publish(); pump()
    }

    /// Cancel only the Library window's ownership; other windows' waits survive.
    public func cancelDownload(bankID: String) {
        jobs[bankID]?.manualOwner = false
        cancelIfUnowned(bankID)
        publish()
    }

    public func ensureInstalled(bankIDs: Set<String>) async throws {
        try await prepare(); try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in bankIDs { group.addTask { try await self.ensureBank(id) } }
            try await group.waitForAll()
        }
    }

    /// Explicit UI actions name catalog instruments, never paths or download
    /// URLs. Validate the complete set before starting any installation.
    public func ensureInstalled(instrumentIDs: Set<String>) async throws {
        var required = Set<String>()
        for id in instrumentIDs {
            guard let preset = presets[id] else { throw SoundLibraryError.unknownInstrument(id) }
            if let bankID = preset.soundBankID {
                guard banks[bankID] != nil else { throw SoundLibraryError.unknownBank(bankID) }
                required.insert(bankID)
            }
        }
        try await ensureInstalled(bankIDs: required)
    }

    public func acquire(instrumentIDs: Set<String>) async throws -> SoundLibraryLease {
        try await prepare(); try Task.checkCancellation()
        var urls: [String: URL] = [:], required = Set<String>()
        for id in instrumentIDs {
            guard let preset = presets[id] else { throw SoundLibraryError.unknownInstrument(id) }
            if let bankID = preset.soundBankID {
                guard let bank = banks[bankID] else { throw SoundLibraryError.unknownBank(bankID) }
                required.insert(bankID); urls[id] = fileURL(bank)
            }
        }
        var missing = required.subtracting(installed)
        guard missing.isEmpty else { throw SoundLibraryError.missingBanks(missing.sorted()) }
        let token = UUID(); leases[token] = required; publish()
        do {
            for id in required {
                guard let bank = banks[id] else { continue }
                let url = fileURL(bank), cached = verifiedFiles[id]
                do {
                    let stamp = try await Self.runIO {
                        let current = try BankFileStamp(url: url)
                        if current == cached { return current }
                        return try BankFileValidation.verifiedStamp(url, bytes: bank.installedBytes, hash: bank.sha256)
                    }
                    verifiedFiles[id] = stamp
                } catch is CancellationError { throw CancellationError()
                } catch {
                    installed.remove(id); verifiedFiles.removeValue(forKey: id)
                    states[id] = .notInstalled; missing.insert(id)
                }
            }
            try Task.checkCancellation()
            guard missing.isEmpty else { throw SoundLibraryError.missingBanks(missing.sorted()) }
            return SoundLibraryLease(urls: urls) { [weak self] in await self?.release(token) }
        } catch { release(token); throw error }
    }

    public func remove(bankID: String) async throws {
        try await prepare()
        guard let bank = banks[bankID] else { throw SoundLibraryError.unknownBank(bankID) }
        guard !leases.values.contains(where: { $0.contains(bankID) }), jobs[bankID] == nil else {
            throw SoundLibraryError.busy(bankID)
        }
        let directory = fileURL(bank).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        installed.remove(bankID); verifiedFiles.removeValue(forKey: bankID); completedAt.removeValue(forKey: bankID)
        states[bankID] = .notInstalled; publish()
    }

    /// Import exact known SF2 files only. Originals remain untouched.
    @discardableResult public func importExisting(urls: [URL]) async throws -> [String] {
        try await prepare()
        var results: [String] = []
        for url in urls {
            try Task.checkCancellation()
            results.append(try await importFile(url))
        }
        return results
    }

    /// Report every selected file without discarding earlier successful
    /// imports. Cancellation stops the caller and keeps completed banks.
    public func importExistingReporting(urls: [URL]) async throws -> SoundImportReport {
        try await prepare()
        var imported: [String] = [], failures: [SoundImportFailure] = []
        for url in urls {
            try Task.checkCancellation()
            do {
                let id = try await importFile(url)
                if !imported.contains(id) { imported.append(id) }
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append(.init(fileName: url.lastPathComponent, message: error.localizedDescription)) }
        }
        return SoundImportReport(importedBankIDs: imported, failures: failures)
    }

    private func importFile(_ url: URL) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let allBanks = Array(banks.values)
        let match = try await Self.runIO {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            for bank in allBanks where size == bank.installedBytes {
                if try BankFileValidation.hash(url, expectedBytes: bank.installedBytes) == bank.sha256.lowercased() { return bank }
            }
            throw SoundLibraryError.validation("The selected file does not match a supported sound bank.")
        }
        try Task.checkCancellation()
        guard jobs[match.id] == nil else { throw SoundLibraryError.busy(match.id) }
        if installed.contains(match.id) { return match.id }
        let stage = root.appendingPathComponent(".staging/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        do {
            try fileCheck(.prepareStaging)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let target = stage.appendingPathComponent(match.fileName)
            try fileCheck(.copyImport)
            try FileManager.default.copyItem(at: url, to: target)
            try BankFileValidation.verify(target, bytes: match.installedBytes, hash: match.sha256)
            try Task.checkCancellation()
            try install(match, from: target)
            return match.id
        } catch { states[match.id] = .failed(error.localizedDescription); publish(); throw error }
    }

    private func ensureBank(_ id: String) async throws {
        guard banks[id] != nil else { throw SoundLibraryError.unknownBank(id) }
        try Task.checkCancellation()
        if installed.contains(id) { return }
        if let task = jobs[id]?.task, task.isCancelled { await task.value; try Task.checkCancellation() }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if jobs[id] == nil { jobs[id] = Job(); queue.append(id); states[id] = .queued }
                jobs[id]?.waiters[waiter] = continuation
                publish(); pump()
            }
        } onCancel: { Task { await self.cancelWaiter(bankID: id, token: waiter) } }
    }

    private func cancelWaiter(bankID: String, token: UUID) {
        if let waiter = jobs[bankID]?.waiters.removeValue(forKey: token) { waiter.resume(throwing: CancellationError()) }
        cancelIfUnowned(bankID)
        publish()
    }
    private func cancelIfUnowned(_ id: String) {
        guard let job = jobs[id], !job.manualOwner, job.waiters.isEmpty else { return }
        if let task = job.task { task.cancel() }
        else { jobs.removeValue(forKey: id); queue.removeAll { $0 == id }; states[id] = .notInstalled; publish() }
    }

    private func pump() {
        while active.count < 2, let id = queue.first {
            queue.removeFirst()
            guard var job = jobs[id], let bank = banks[id] else { continue }
            active.insert(id)
            let stage = root.appendingPathComponent(".staging/\(UUID().uuidString)", isDirectory: true)
            let downloader = downloader, extractor = extractor, fileCheck = fileCheck, jobToken = job.token
            job.task = Task { [self] in
                do {
                    try await Self.prepareBank(bank, stage: stage, downloader: downloader, extractor: extractor, fileCheck: fileCheck,
                        phase: { phase in await self.setState(id, phase, token: jobToken) })
                    try Task.checkCancellation()
                    self.complete(id, token: jobToken, staged: stage.appendingPathComponent(bank.fileName), failure: nil)
                } catch { self.complete(id, token: jobToken, staged: nil, failure: error) }
                try? FileManager.default.removeItem(at: stage)
            }
            jobs[id] = job
        }
    }

    private nonisolated static func prepareBank(_ bank: SoundBank, stage: URL,
        downloader: any SoundBankDownloading, extractor: any SoundBankExtracting,
        fileCheck: @escaping @Sendable (LibraryFileOperation) throws -> Void,
        phase: @escaping @Sendable (SoundBankState) async -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try BankFileValidation.validate(bank)
                try fileCheck(.prepareStaging)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let archive = stage.appendingPathComponent("archive"), output = stage.appendingPathComponent(bank.fileName)
                await phase(.downloading(received: 0, total: bank.downloadBytes))
                try await downloader.download(bank, to: archive) { received, total in
                    Task { await phase(.downloading(received: received, total: total)) }
                }
                try Task.checkCancellation()
                await phase(.verifying)
                try BankFileValidation.verify(archive, bytes: bank.downloadBytes, hash: bank.archiveSHA256)
                await phase(.installing)
                try await extractor.extract(bank, archive: archive, to: output)
                try Task.checkCancellation()
                try BankFileValidation.verify(output, bytes: bank.installedBytes, hash: bank.sha256)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(1800))
                throw SoundLibraryError.validation("The sound installation took too long. Retry it from Sound Library.")
            }
            defer { group.cancelAll() }
            try await group.next(); group.cancelAll()
        }
    }

    private func complete(_ id: String, token: UUID, staged: URL?, failure: (any Error)?) {
        guard let job = jobs[id], job.token == token else { return }
        jobs.removeValue(forKey: id)
        active.remove(id)
        var error = failure
        if let staged, let bank = banks[id], error == nil {
            do { try install(bank, from: staged) } catch let installError { error = installError }
        }
        if let error {
            states[id] = error is CancellationError ? .notInstalled : .failed(error.localizedDescription)
            for waiter in job.waiters.values { waiter.resume(throwing: error) }
        } else { for waiter in job.waiters.values { waiter.resume() } }
        publish(); pump()
    }

    private func install(_ bank: SoundBank, from staged: URL) throws {
        try fileCheck(.install)
        let target = fileURL(bank), directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: target) }
        let stamp = try BankFileStamp(url: target)
        installed.insert(bank.id); verifiedFiles[bank.id] = stamp; completedAt[bank.id] = Date()
        states[bank.id] = .installed(bytes: bank.installedBytes, inUse: false); publish()
    }

    private func prepare() async throws {
        if prepared { return }
        let task: Task<[String: BankFileStamp], any Error>
        if let preparation { task = preparation }
        else {
            let root = root, banks = Array(banks.values)
            task = Task.detached(priority: .utility) {
                let staging = root.appendingPathComponent(".staging", isDirectory: true)
                // A new actor instance models an app restart; no jobs own these files.
                if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var installed: [String: BankFileStamp] = [:]
                for bank in banks {
                    try BankFileValidation.validate(bank)
                    let url = root.appendingPathComponent("banks/\(bank.id)/\(bank.version)/\(bank.fileName)")
                    if let stamp = try? BankFileValidation.verifiedStamp(url, bytes: bank.installedBytes, hash: bank.sha256) { installed[bank.id] = stamp }
                }
                return installed
            }
            preparation = task
        }
        do {
            let found = try await task.value
            if !prepared {
                installed = Set(found.keys); verifiedFiles = found
                for id in found.keys { states[id] = .installed(bytes: banks[id]?.installedBytes ?? 0, inUse: false) }
                prepared = true; preparation = nil; publish()
            }
        } catch { preparation = nil; throw error }
    }

    private nonisolated static func runIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func fileURL(_ bank: SoundBank) -> URL {
        root.appendingPathComponent("banks/\(bank.id)/\(bank.version)/\(bank.fileName)")
    }
    private func setState(_ id: String, _ state: SoundBankState, token: UUID) {
        guard jobs[id]?.token == token else { return }
        // Progress callbacks may be delivered after verification has begun.
        if case .downloading = state {
            switch states[id] { case .queued?, .downloading?: break; default: return }
        }
        states[id] = state; publish()
    }
    private func release(_ id: UUID) { leases.removeValue(forKey: id); publish() }
    private func currentStates() -> [String: SoundBankState] {
        var snapshot = states
        let inUse = leases.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for id in installed { snapshot[id] = .installed(bytes: banks[id]?.installedBytes ?? 0, inUse: inUse.contains(id)) }
        return snapshot
    }
    private func currentActivities() -> [String: SoundBankActivity] {
        Dictionary(uniqueKeysWithValues: currentStates().map { id, state in
            (id, SoundBankActivity(bankID: id, state: state, libraryRequested: jobs[id]?.manualOwner ?? false,
                                   requiredByOtherOperations: !(jobs[id]?.waiters.isEmpty ?? true), completedAt: completedAt[id]))
        })
    }
    private func publish() {
        let state = currentStates()
        for observer in observers.values { observer.yield(state) }
        let activities = currentActivities()
        for observer in activityObservers.values { observer.yield(activities) }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func removeActivityObserver(_ id: UUID) { activityObservers.removeValue(forKey: id) }
}
