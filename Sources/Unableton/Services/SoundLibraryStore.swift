import AppKit
import Combine
import UnabletonCore
import UnabletonLibrary
import UnabletonAI

@MainActor
final class SoundLibraryStore: ObservableObject {
    static let shared = SoundLibraryStore()
    static let automaticPreference = "library.automaticDownloads"
    let library: SoundLibrary
    @Published private(set) var states: [String: SoundBankState] = [:]
    @Published private(set) var activities: [String: SoundBankActivity] = [:]
    @Published private(set) var recentlyCompletedBankIDs: [String] = []
    @Published private(set) var isImporting = false
    @Published var importReport: SoundImportReport?
    @Published var error: String?
    private var observation: Task<Void, Never>?
    private let consentCoordinator: SoundDownloadConsentCoordinator
    private let preferences: UserDefaults

    init(library: SoundLibrary = .shared, preferences: UserDefaults = .standard) {
        self.library = library; self.preferences = preferences
        consentCoordinator = SoundDownloadConsentCoordinator(presenter: NativeSoundDownloadConsentPresenter()) {
            preferences.set(true, forKey: Self.automaticPreference)
        }
        observation = Task { [weak self, library] in
            let updates = await library.activityUpdates()
            for await activities in updates {
                guard let self else { return }
                self.receive(activities)
            }
        }
    }
    deinit { observation?.cancel() }
    var activeDownloadCount: Int { activities.values.filter { $0.state.isBusy }.count }
    var importedInstrumentIDs: [String] {
        let banks = Set(importReport?.importedBankIDs ?? [])
        return InstrumentCatalog.presets.filter { $0.soundBankID.map(banks.contains) ?? false }.map(\.id)
    }

    private func receive(_ activities: [String: SoundBankActivity]) {
        let states = activities.mapValues(\.state)
        // Timestamps belong to this library actor's lifetime, so installed
        // files found at launch aren't mislabeled as recent. A fast completed
        // job is retained even when buffered progress snapshots coalesce.
        let completed = activities.values.filter { $0.completedAt != nil && $0.state.isInstalled }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }.map(\.bankID)
        var recent = recentlyCompletedBankIDs
        for id in completed.reversed() {
            recent.removeAll { $0 == id }
            recent.insert(id, at: 0)
        }
        recent.removeAll { states[$0]?.isInstalled != true }
        if recentlyCompletedBankIDs != recent { recentlyCompletedBankIDs = recent }
        if self.activities != activities { self.activities = activities }
        if self.states != states { self.states = states }
    }
    func state(for preset: InstrumentPreset) -> SoundBankState? {
        preset.soundBankID.map { states[$0] ?? .notInstalled }
    }
    func isInstalled(_ preset: InstrumentPreset) -> Bool {
        guard let state = state(for: preset) else { return true }
        if case .installed = state { return true }
        return false
    }
    func download(_ bankID: String) {
        Task { do { try await library.requestDownload(bankID: bankID) } catch { self.error = error.localizedDescription } }
    }
    func cancel(_ bankID: String) { Task { await library.cancelDownload(bankID: bankID) } }
    func remove(_ bank: SoundBank) {
        Task { do { try await library.remove(bankID: bank.id) } catch { self.error = error.localizedDescription } }
    }
    func importSounds() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sf2") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose existing SF2 files. Only exact versions in the sound catalog can be imported. Originals stay in place."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importSounds(urls: urls) }
    }
    func importSounds(urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true; importReport = nil
        defer { isImporting = false }
        do {
            let report = try await library.importExistingReporting(urls: urls)
            importReport = report
            var recent = recentlyCompletedBankIDs
            for id in report.importedBankIDs.reversed() {
                recent.removeAll { $0 == id }
                recent.insert(id, at: 0)
            }
            if recentlyCompletedBankIDs != recent { recentlyCompletedBankIDs = recent }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func resources(for ids: Set<String>, automatic: Bool = false, budget: GenerationBudget? = nil,
                   status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> InstrumentResources {
        try Task.checkCancellation()
        let requiredBanks = Set(ids.compactMap { InstrumentCatalog.preset(id: $0)?.soundBankID })
        let snapshot = await library.snapshot()
        let missing = requiredBanks.filter { id in
            if case .installed = snapshot[id] { return false }
            return true
        }
        if !missing.isEmpty {
            let install: @Sendable () async throws -> Void = { [self] in
                if automatic { try await self.requestAutomaticConsent(bankIDs: missing) }
                else { try await self.requestDownloadConsent(bankIDs: missing) }
                status("Downloading required sounds…")
                try await library.ensureInstalled(bankIDs: missing)
            }
            if let budget { try await budget.withDependencyWait(install) }
            else { try await install() }
        }
        try Task.checkCancellation()
        let lease = try await library.acquire(instrumentIDs: ids)
        return InstrumentResources(urls: lease.urls, owner: lease)
    }
    func existingResources(for ids: Set<String>) async throws -> InstrumentResources {
        let available = await installedIDs()
        let missing = ids.subtracting(available)
        if !missing.isEmpty { throw MissingInstruments(missing) }
        let lease = try await library.acquire(instrumentIDs: ids)
        return InstrumentResources(urls: lease.urls, owner: lease)
    }
    /// The user already chose Download/Download & Use beside the disclosed
    /// sound and size. This authorizes only those IDs, never future AI choices.
    func resourcesForExplicitUse(for ids: Set<String>) async throws -> InstrumentResources {
        try Task.checkCancellation()
        try await library.ensureInstalled(instrumentIDs: ids)
        try Task.checkCancellation()
        let lease = try await library.acquire(instrumentIDs: ids)
        return InstrumentResources(urls: lease.urls, owner: lease)
    }
    func installedIDs() async -> Set<String> {
        let snapshot = await library.snapshot()
        return Set(InstrumentCatalog.presets.filter { preset in
            guard let bankID = preset.soundBankID else { return true }
            if case .installed = snapshot[bankID] { return true }
            return false
        }.map(\.id))
    }
    private func requestAutomaticConsent(bankIDs: Set<String>) async throws {
        if preferences.bool(forKey: Self.automaticPreference) { return }
        guard try await consent(bankIDs: bankIDs, automatic: true) else { throw CancellationError() }
    }
    private func requestDownloadConsent(bankIDs: Set<String>) async throws {
        guard try await consent(bankIDs: bankIDs, automatic: false) else { throw CancellationError() }
    }
    private func consent(bankIDs: Set<String>, automatic: Bool) async throws -> Bool {
        try await consentCoordinator.request(bankIDs: bankIDs, automatic: automatic)
    }

}

/// One draft holds its downloaded versions through preview and final commit.
actor InstrumentRunResources {
    private var held: [InstrumentResources] = []
    private var urls: [String: URL] = [:]
    func ensure(_ ids: Set<String>, budget: GenerationBudget,
                status: @escaping @Sendable (String) -> Void) async throws {
        let needed = ids.filter { InstrumentCatalog.preset(id: $0)?.isSampler == true && urls[$0] == nil }
        guard !needed.isEmpty else { return }
        do {
            let resources = try await SoundLibraryStore.shared.resources(for: needed, automatic: true, budget: budget, status: status)
            held.append(resources); urls.merge(resources.urls) { _, new in new }
        } catch is CancellationError { throw CancellationError() }
        catch { throw InstrumentDependencyError(error.localizedDescription) }
    }
    func snapshot() -> InstrumentResources { InstrumentResources(urls: urls, owner: self) }
}
