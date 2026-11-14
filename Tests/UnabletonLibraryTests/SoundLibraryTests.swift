import CryptoKit
import Foundation
import Testing
import UnabletonCore
@testable import UnabletonLibrary

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private actor FixtureDownloader: SoundBankDownloading {
    let data: Data
    let delay: Duration
    private(set) var calls = 0
    private var active = 0
    private(set) var peak = 0
    init(data: Data, delay: Duration = .zero) { self.data = data; self.delay = delay }
    func download(_ bank: SoundBank, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        calls += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        try data.write(to: destination)
        progress(Int64(data.count), bank.downloadBytes)
    }
}
private struct FixtureExtractor: SoundBankExtracting {
    let data: Data
    func extract(_ bank: SoundBank, archive: URL, to destination: URL) async throws { try data.write(to: destination) }
}

struct SoundLibraryTests {
    private let archive = Data("fixture archive bytes".utf8)
    private let sound = Data("fixture sf2 bytes".utf8)

    private func bank(_ id: String = "fixture", member: String = "sounds/example.sf2",
                      archiveHash: String? = nil, soundHash: String? = nil,
                      installedBytes: Int64? = nil) -> SoundBank {
        SoundBank(id: id, sourceID: "fixture", version: "1", url: URL(string: "https://example.test/fixture.tar")!,
            archiveSHA256: archiveHash ?? digest(archive), member: member, fileName: "example.sf2",
            sha256: soundHash ?? digest(sound), downloadBytes: Int64(archive.count), installedBytes: installedBytes ?? Int64(sound.count),
            license: "CC0-1.0", licenseURL: URL(string: "https://example.test/license")!, attribution: "Fixture author",
            sourceURL: URL(string: "https://example.test/")!)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonLibraryTest-\(UUID())") }
    private func preset(_ bankID: String = "fixture") -> InstrumentPreset {
        InstrumentPreset("fixture.instrument", "Fixture", "Tests", "waveform", soundFont: "example.sf2", soundBankID: bankID)
    }
    private func service(_ root: URL, banks: [SoundBank]? = nil, downloader: FixtureDownloader? = nil,
                         extractor: (any SoundBankExtracting)? = nil,
                         fileCheck: @escaping @Sendable (LibraryFileOperation) throws -> Void = { _ in }) -> SoundLibrary {
        SoundLibrary(root: root, banks: banks ?? [bank()], presets: [preset()],
            downloader: downloader ?? FixtureDownloader(data: archive), extractor: extractor ?? FixtureExtractor(data: sound), fileCheck: fileCheck)
    }
    private func waitForCalls(_ downloader: FixtureDownloader, _ count: Int) async throws {
        for _ in 0..<1000 {
            if await downloader.calls >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Fixture downloader did not start")
    }

    @Test func cleanLibraryDoesNotDownloadAndBuiltinNeedsNoResources() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: archive)
        let synth = InstrumentPreset("synth.fixture", "Synth", "Tests", "waveform")
        let library = SoundLibrary(root: root, banks: [bank()], presets: [synth], downloader: downloader, extractor: FixtureExtractor(data: sound))
        #expect(await library.snapshot()["fixture"] == .notInstalled)
        #expect(await downloader.calls == 0)
        let lease = try await library.acquire(instrumentIDs: [synth.id])
        #expect(lease.urls.isEmpty)
        await lease.release()
        do { _ = try await library.acquire(instrumentIDs: ["unknown"]); Issue.record("Unknown instrument accepted") }
        catch { #expect(error as? SoundLibraryError == .unknownInstrument("unknown")) }
    }

    @Test func installAcquireRemovalAndReopenUseSameExactBank() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = service(root)
        do { _ = try await library.acquire(instrumentIDs: [preset().id]); Issue.record("Missing bank accepted") }
        catch { #expect(error as? SoundLibraryError == .missingBanks(["fixture"])) }
        try await library.ensureInstalled(bankIDs: ["fixture"])
        let lease = try await library.acquire(instrumentIDs: [preset().id])
        #expect(try Data(contentsOf: #require(lease.urls[preset().id])) == sound)
        #expect(await library.snapshot()["fixture"] == .installed(bytes: Int64(sound.count), inUse: true))
        await #expect(throws: SoundLibraryError.self) { try await library.remove(bankID: "fixture") }
        await lease.release()
        let reopened = service(root)
        #expect(await reopened.snapshot()["fixture"]?.isInstalled == true)
        try await library.remove(bankID: "fixture")
        #expect(await library.snapshot()["fixture"] == .notInstalled)
    }

    @Test func corruptionAndOversizedExtractionNeverInstall() async throws {
        for kind in 0..<3 {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let bank = bank(archiveHash: kind == 0 ? String(repeating: "0", count: 64) : nil,
                            soundHash: kind == 1 ? String(repeating: "0", count: 64) : nil,
                            installedBytes: kind == 2 ? 1 : nil)
            let library = service(root, banks: [bank])
            await #expect(throws: (any Error).self) { try await library.ensureInstalled(bankIDs: [bank.id]) }
            if case .failed = await library.snapshot()[bank.id] {} else { Issue.record("Invalid bank was not reported as failed") }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("banks/fixture/1/example.sf2").path))
        }
    }

    @Test func deduplicatesTwoWaitersAndCancellationLeavesOtherWaiterRunning() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: archive, delay: .milliseconds(150))
        let library = service(root, downloader: downloader)
        let first = Task { try await library.ensureInstalled(bankIDs: ["fixture"]) }
        try await waitForCalls(downloader, 1)
        let second = Task { try await library.ensureInstalled(bankIDs: ["fixture"]) }
        try await Task.sleep(for: .milliseconds(20)); first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        #expect(await downloader.calls == 1)
        #expect(await library.snapshot()["fixture"]?.isInstalled == true)
    }

    @Test func cancelingManualOwnerDoesNotCancelAnAIWaiter() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: archive, delay: .milliseconds(120))
        let library = service(root, downloader: downloader)
        try await library.requestDownload(bankID: "fixture")
        let waiter = Task { try await library.ensureInstalled(bankIDs: ["fixture"]) }
        try await Task.sleep(for: .milliseconds(20))
        await library.cancelDownload(bankID: "fixture")
        try await waiter.value
        #expect(await downloader.calls == 1)
    }

    @Test func activityReportsOwnershipChangesAndSessionCompletion() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: archive, delay: .milliseconds(180))
        let library = service(root, downloader: downloader)
        #expect(await library.activitySnapshot()["fixture"]?.completedAt == nil)
        try await library.requestDownload(bankID: "fixture")
        var activity = try #require(await library.activitySnapshot()["fixture"])
        #expect(activity.libraryRequested)
        #expect(!activity.requiredByOtherOperations)
        #expect(activity.state.isBusy)
        let waiter = Task { try await library.ensureInstalled(bankIDs: ["fixture"]) }
        for _ in 0..<200 {
            if await library.activitySnapshot()["fixture"]?.requiredByOtherOperations == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        activity = try #require(await library.activitySnapshot()["fixture"])
        #expect(activity.libraryRequested && activity.requiredByOtherOperations)
        await library.cancelDownload(bankID: "fixture")
        activity = try #require(await library.activitySnapshot()["fixture"])
        #expect(!activity.libraryRequested && activity.requiredByOtherOperations)
        try await waiter.value
        activity = try #require(await library.activitySnapshot()["fixture"])
        #expect(activity.state.isInstalled)
        #expect(activity.completedAt != nil)
        #expect(!activity.libraryRequested && !activity.requiredByOtherOperations)
        let reopened = service(root)
        #expect(await reopened.activitySnapshot()["fixture"]?.completedAt == nil)
    }

    @Test func explicitInstrumentInstallationValidatesAllIDsBeforeDownloading() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: archive)
        let library = service(root, downloader: downloader)
        do {
            try await library.ensureInstalled(instrumentIDs: [preset().id, "not-in-catalog"])
            Issue.record("Unknown instrument accepted")
        } catch { #expect(error as? SoundLibraryError == .unknownInstrument("not-in-catalog")) }
        #expect(await downloader.calls == 0)
        try await library.ensureInstalled(instrumentIDs: [preset().id])
        #expect(await downloader.calls == 1)
    }

    @Test func newWaiterAfterLastOwnerCancelsStartsAFreshJob() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: archive, delay: .milliseconds(60))
        let library = service(root, downloader: downloader)
        try await library.requestDownload(bankID: "fixture")
        try await waitForCalls(downloader, 1)
        await library.cancelDownload(bankID: "fixture")
        try await library.ensureInstalled(bankIDs: ["fixture"])
        #expect(await downloader.calls == 2)
        #expect(await library.snapshot()["fixture"]?.isInstalled == true)
    }

    @Test func atMostTwoDownloadsRunAndQueuedCancellationDoesNotFetch() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: archive, delay: .milliseconds(100))
        let library = service(root, banks: (0..<5).map { bank("bank\($0)") }, downloader: downloader)
        try await library.requestDownload(bankID: "bank0")
        try await library.requestDownload(bankID: "bank1")
        try await library.requestDownload(bankID: "bank2")
        await library.cancelDownload(bankID: "bank2")
        try await library.ensureInstalled(bankIDs: ["bank0", "bank1", "bank3", "bank4"])
        #expect(await downloader.peak == 2)
        #expect(await downloader.calls == 4)
        #expect(await library.snapshot()["bank2"] == .notInstalled)
    }

    @Test func failedDownloadsHaveNoAutomaticRetryAndExplicitRetryWorks() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureDownloader(data: Data("bad".utf8))
        let library = service(root, downloader: downloader)
        await #expect(throws: (any Error).self) { try await library.ensureInstalled(bankIDs: ["fixture"]) }
        #expect(await downloader.calls == 1)
        _ = await library.snapshot()
        #expect(await downloader.calls == 1)
        await #expect(throws: (any Error).self) { try await library.ensureInstalled(bankIDs: ["fixture"]) }
        #expect(await downloader.calls == 2)
    }

    @Test func importRequiresExactFileRetainsOriginalAndRejectsUnknown() async throws {
        let root = root(), source = self.root(); defer {
            try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("existing.sf2")
        try sound.write(to: file)
        let library = service(root)
        #expect(try await library.importExisting(urls: [file]) == ["fixture"])
        #expect(try Data(contentsOf: file) == sound)
        try Data("unrecognized".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await library.importExisting(urls: [file]) }
        #expect(await library.snapshot()["fixture"]?.isInstalled == true)
    }

    @Test func batchImportReportsFailuresAndContinuesWithValidFiles() async throws {
        let root = root(), source = self.root(); defer {
            try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let valid = source.appendingPathComponent("known.sf2"), invalid = source.appendingPathComponent("unknown.sf2")
        let missing = source.appendingPathComponent("missing.sf2")
        try sound.write(to: valid); try Data("unknown".utf8).write(to: invalid)
        let library = service(root)
        let report = try await library.importExistingReporting(urls: [invalid, valid, missing, valid])
        #expect(report.importedBankIDs == ["fixture"])
        #expect(report.failures.map(\.fileName) == ["unknown.sf2", "missing.sf2"])
        #expect(report.failures.allSatisfy { !$0.message.isEmpty })
        #expect(await library.snapshot()["fixture"]?.isInstalled == true)
        #expect(try Data(contentsOf: valid) == sound)
        let repeatReport = try await library.importExistingReporting(urls: [valid])
        #expect(repeatReport.importedBankIDs == ["fixture"] && repeatReport.failures.isEmpty)
    }

    @Test func diskFailureDoesNotPublishInstallationAndRestartClearsStaging() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = service(root, fileCheck: { if case .install = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        await #expect(throws: (any Error).self) { try await library.ensureInstalled(bankIDs: ["fixture"]) }
        #expect(await library.snapshot()["fixture"]?.isInstalled == false)
        let leftover = root.appendingPathComponent(".staging/interrupted/archive")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: leftover)
        _ = await service(root).snapshot()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func deletedOrChangedInstalledFileCannotBeAcquired() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = service(root)
        try await library.ensureInstalled(bankIDs: ["fixture"])
        try Data(repeating: 0, count: sound.count).write(to: root.appendingPathComponent("banks/fixture/1/example.sf2"))
        do { _ = try await library.acquire(instrumentIDs: [preset().id]); Issue.record("Corrupt installed file accepted") }
        catch { #expect(error as? SoundLibraryError == .missingBanks(["fixture"])) }
        try await library.ensureInstalled(bankIDs: ["fixture"])
        let lease = try await library.acquire(instrumentIDs: [preset().id]); await lease.release()
    }

    @Test func rejectsTraversalBeforeExtraction() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = service(root, banks: [bank(member: "../outside.sf2")])
        await #expect(throws: (any Error).self) { try await library.ensureInstalled(bankIDs: ["fixture"]) }
    }

    @Test func realTarExtractsOnlyPinnedMemberAndRejectsExpansionBeyondLimit() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let member = root.appendingPathComponent("example.sf2"), other = root.appendingPathComponent("unrelated.txt")
        try sound.write(to: member); try Data("unrelated".utf8).write(to: other)
        let archiveURL = root.appendingPathComponent("test.tar")
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", archiveURL.path, "-C", root.path, "example.sf2", "unrelated.txt"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
        let archiveBytes = try Data(contentsOf: archiveURL)
        func description(limit: Int64) -> SoundBank {
            SoundBank(id: "tar", sourceID: "fixture", version: "1", url: URL(string: "https://example.test/test.tar")!,
                archiveSHA256: digest(archiveBytes), member: "example.sf2", fileName: "installed.sf2", sha256: digest(sound),
                downloadBytes: Int64(archiveBytes.count), installedBytes: limit, license: "CC0-1.0",
                licenseURL: URL(string: "https://example.test/license")!, attribution: "Fixture", sourceURL: URL(string: "https://example.test/")!)
        }
        let output = root.appendingPathComponent("installed.sf2")
        try await TarBankExtractor().extract(description(limit: Int64(sound.count)), archive: archiveURL, to: output)
        #expect(try Data(contentsOf: output) == sound)
        await #expect(throws: (any Error).self) {
            try await TarBankExtractor().extract(description(limit: 1), archive: archiveURL, to: root.appendingPathComponent("oversized.sf2"))
        }
        #expect((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("oversized.sf2").path)[.size] as? NSNumber)?.int64Value == 0)
    }

    @Test func realTarAndHashProcessEveryChunkOfALargerBank() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var data = Data(repeating: 0x5a, count: 1_048_613)
        data[0] = 0x31; data[data.count - 1] = 0xff
        let member = root.appendingPathComponent("large.sf2")
        try data.write(to: member)
        let archiveURL = root.appendingPathComponent("large.tar")
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", archiveURL.path, "-C", root.path, "large.sf2"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
        let archiveData = try Data(contentsOf: archiveURL)
        let bank = SoundBank(id: "large", sourceID: "fixture", version: "1", url: URL(string: "https://example.test/large.tar")!,
                            archiveSHA256: digest(archiveData), member: "large.sf2", fileName: "installed.sf2", sha256: digest(data),
                            downloadBytes: Int64(archiveData.count), installedBytes: Int64(data.count), license: "CC0-1.0",
                            licenseURL: URL(string: "https://example.test/license")!, attribution: "Fixture", sourceURL: URL(string: "https://example.test/")!)
        let output = root.appendingPathComponent("installed.sf2")
        try await TarBankExtractor().extract(bank, archive: archiveURL, to: output)
        #expect(try BankFileValidation.hash(output, expectedBytes: Int64(data.count)) == digest(data))
        #expect(try Data(contentsOf: output) == data)
    }
}
