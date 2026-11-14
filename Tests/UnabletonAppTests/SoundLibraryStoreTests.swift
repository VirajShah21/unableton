import CryptoKit
import Combine
import Foundation
import Testing
import UnabletonCore
import UnabletonLibrary
@testable import Unableton

private actor StoreFixtureDownloader: SoundBankDownloading {
    let bytes: Data
    let delay: Duration
    private(set) var calls = 0
    init(_ bytes: Data, delay: Duration = .zero) { self.bytes = bytes; self.delay = delay }
    func download(_ bank: SoundBank, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        calls += 1
        try await Task.sleep(for: delay)
        try bytes.write(to: destination)
        progress(Int64(bytes.count), Int64(bytes.count))
    }
}

private struct StoreFixtureExtractor: SoundBankExtracting {
    let bytes: Data
    func extract(_ bank: SoundBank, archive: URL, to destination: URL) async throws { try bytes.write(to: destination) }
}

@Suite(.serialized) @MainActor
struct SoundLibraryStoreTests {
    private let archive = Data("store archive".utf8)
    private let sound = Data("store sound".utf8)
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func bank() -> SoundBank {
        SoundBank(id: "piano", sourceID: "fixture", version: "1", url: URL(string: "https://example.test/piano.tar")!,
                  archiveSHA256: hash(archive), member: "piano.sf2", fileName: "piano.sf2", sha256: hash(sound),
                  downloadBytes: Int64(archive.count), installedBytes: Int64(sound.count), license: "CC0-1.0",
                  licenseURL: URL(string: "https://example.test/license")!, attribution: "Fixture", sourceURL: URL(string: "https://example.test")!)
    }
    private func library(_ root: URL, downloader: StoreFixtureDownloader) -> SoundLibrary {
        SoundLibrary(root: root, banks: [bank()],
            presets: [.init("sampled.piano", "Piano", "Tests", "pianokeys", soundFont: "piano.sf2", soundBankID: "piano")],
            downloader: downloader, extractor: StoreFixtureExtractor(bytes: sound))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Store did not receive the expected activity update")
    }

    @Test func explicitUseDoesNotEnableAutomaticConsentAndPublishesCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SoundStore-\(UUID())")
        let suite = "SoundStoreTests.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let downloader = StoreFixtureDownloader(archive, delay: .milliseconds(100))
        let service = library(root, downloader: downloader), store = SoundLibraryStore(library: service, preferences: preferences)
        let operation = Task { try await store.resourcesForExplicitUse(for: ["sampled.piano"]) }
        try await waitUntil { store.activeDownloadCount == 1 }
        #expect(store.activities["piano"]?.requiredByOtherOperations == true)
        #expect(store.activities["piano"]?.libraryRequested == false)
        let resources = try await operation.value
        #expect(resources.urls["sampled.piano"] != nil)
        #expect(!preferences.bool(forKey: SoundLibraryStore.automaticPreference))
        try await waitUntil { store.recentlyCompletedBankIDs == ["piano"] && store.activeDownloadCount == 0 }
        #expect(await downloader.calls == 1)
        withExtendedLifetime(resources) {}
    }

    @Test func importPublishesMixedResultsAndRevealIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SoundStore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = library(root, downloader: StoreFixtureDownloader(archive)), store = SoundLibraryStore(library: service)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("piano-original.sf2"), invalid = root.appendingPathComponent("unknown.sf2")
        try sound.write(to: valid); try Data("unknown".utf8).write(to: invalid)
        await store.importSounds(urls: [invalid, valid])
        #expect(!store.isImporting)
        #expect(store.importReport?.importedBankIDs == ["piano"])
        #expect(store.importReport?.failures.map(\.fileName) == ["unknown.sf2"])
        #expect(store.importedInstrumentIDs == ["sampled.piano"])
        #expect(store.error == nil)
        #expect(try Data(contentsOf: valid) == sound)
    }

    @Test func unchangedLeaseSnapshotsDoNotRepublishHistoryOrStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SoundStore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = library(root, downloader: StoreFixtureDownloader(archive)), store = SoundLibraryStore(library: service)
        let resources = try await store.resourcesForExplicitUse(for: ["sampled.piano"])
        try await waitUntil { store.recentlyCompletedBankIDs == ["piano"] && store.states["piano"] == .installed(bytes: Int64(sound.count), inUse: true) }
        var historyPublications = 0, statePublications = 0, activityPublications = 0
        let history = store.$recentlyCompletedBankIDs.dropFirst().sink { _ in historyPublications += 1 }
        let states = store.$states.dropFirst().sink { _ in statePublications += 1 }
        let activities = store.$activities.dropFirst().sink { _ in activityPublications += 1 }
        let extraLease = try await service.acquire(instrumentIDs: ["sampled.piano"])
        await extraLease.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(historyPublications == 0)
        #expect(statePublications == 0)
        #expect(activityPublications == 0)
        withExtendedLifetime((resources, history, states, activities)) {}
    }
}
