import Foundation
import Combine
import Darwin
@preconcurrency import AVFAudio
import UnabletonCore
import UnabletonAudio

struct SoundAuditionRender: Sendable {
    let peak: Double
    let silent: Bool
}

@MainActor
protocol SoundAuditionFocusing {
    var unavailableReason: String? { get }
    func begin(_ audition: SoundAuditionController) -> UUID?
    func owns(_ token: UUID) -> Bool
    func release(_ token: UUID)
}

@MainActor
private struct NativeSoundAuditionFocus: SoundAuditionFocusing {
    var unavailableReason: String? { PlaybackFocus.libraryAuditionUnavailableReason }
    func begin(_ audition: SoundAuditionController) -> UUID? { PlaybackFocus.beginLibraryAudition(audition) }
    func owns(_ token: UUID) -> Bool { PlaybackFocus.ownsLibraryAudition(token) }
    func release(_ token: UUID) { PlaybackFocus.releaseLibraryAudition(token) }
}

@MainActor
protocol SoundAuditionPlaying: AnyObject {
    func play(url: URL, volume: Float, completion: @escaping @MainActor () -> Void) throws
    func stop()
}

@MainActor
private final class NativeSoundAuditionPlayer: NSObject, SoundAuditionPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: (@MainActor () -> Void)?
    func play(url: URL, volume: Float, completion: @escaping @MainActor () -> Void) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = volume; player.delegate = self
        self.player = player; self.completion = completion
        guard player.play() else { stop(); throw ProjectError("The sound preview could not start. Check your audio output and try again.") }
    }
    func stop() { player?.stop(); player = nil; completion = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            let finished = self.completion; self.stop(); finished?()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}

/// Audition owns no project and never edits one. All loading/rendering happens
/// before playback; the resource lease remains held until playback finishes.
@MainActor
final class SoundAuditionController: ObservableObject {
    enum Phase: Equatable { case idle, preparing, playing }
    static let shared = SoundAuditionController()
    @Published private(set) var instrumentID: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var error: String?
    var unavailableReason: String? { focusCoordinator.unavailableReason }
    private let resourceProvider: @Sendable (String) async throws -> InstrumentResources
    private let render: @Sendable (Song, URL, InstrumentResources) async throws -> SoundAuditionRender
    private let player: any SoundAuditionPlaying
    private let focusCoordinator: any SoundAuditionFocusing
    private let directory: URL
    private let ownsDirectory: Bool
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var focusToken: UUID?
    private var resources: InstrumentResources?
    private var availabilityObservation: AnyCancellable?
    private struct Cached { let url: URL; let report: SoundAuditionRender; var lastUsed: Date }
    private var cache: [String: Cached] = [:]
    private let maximumCacheEntries = 8

    init(directory: URL? = nil,
         resourceProvider: @escaping @Sendable (String) async throws -> InstrumentResources = { id in try await SoundLibraryStore.shared.existingResources(for: [id]) },
         renderer: @escaping @Sendable (Song, URL, InstrumentResources) async throws -> SoundAuditionRender = { song, url, resources in
             let worker = Task.detached(priority: .userInitiated) {
                 let report = try OfflineRenderer.render(song: song, assets: [:], to: url, lengthBeats: 8, resources: resources)
                 return SoundAuditionRender(peak: report.peak, silent: report.silent)
             }
             return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
         }, player: (any SoundAuditionPlaying)? = nil, focus: (any SoundAuditionFocusing)? = nil) {
        ownsDirectory = directory == nil
        if directory == nil { Self.removeAbandonedDirectories() }
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-SoundPreviews-\(ProcessInfo.processInfo.processIdentifier)-\(UUID())", isDirectory: true)
        self.resourceProvider = resourceProvider; self.render = renderer; self.player = player ?? NativeSoundAuditionPlayer()
        self.focusCoordinator = focus ?? NativeSoundAuditionFocus()
        availabilityObservation = PlaybackFocus.availabilityChanges.sink { [weak self] in self?.objectWillChange.send() }
    }
    func isActive(for id: String) -> Bool { instrumentID == id && phase != .idle }
    func preview(_ preset: InstrumentPreset) {
        if isActive(for: preset.id) { stop(); return }
        stop()
        guard let focus = focusCoordinator.begin(self) else {
            error = unavailableReason ?? "Finish recording before previewing a sound."; return
        }
        focusToken = focus
        let request = UUID(); token = request
        instrumentID = preset.id; phase = .preparing; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            var unadopted: URL?
            defer { if let unadopted { try? FileManager.default.removeItem(at: unadopted) } }
            do {
                let resources = try await resourceProvider(preset.id)
                try Task.checkCancellation()
                guard self.isCurrent(request, focus: focus) else { return }
                let key = SoundAuditionPattern.cacheKey(for: preset)
                let rendered: Cached
                if var existing = cache[key], FileManager.default.fileExists(atPath: existing.url.path) {
                    existing.lastUsed = Date(); cache[key] = existing; rendered = existing
                } else {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let output = directory.appendingPathComponent("\(UUID()).wav"); unadopted = output
                    let song = try SoundAuditionPattern.song(for: preset)
                    let report = try await render(song, output, resources)
                    try Task.checkCancellation()
                    guard self.isCurrent(request, focus: focus) else { return }
                    guard !report.silent, report.peak.isFinite, report.peak > 0 else { throw ProjectError("This sound produced a silent preview. Try again or choose another sound.") }
                    rendered = Cached(url: output, report: report, lastUsed: Date())
                    cache[key] = rendered; unadopted = nil; trimCache()
                }
                guard self.isCurrent(request, focus: focus), self.unavailableReason == nil else { throw CancellationError() }
                self.resources = resources
                // Turn down unusually loud banks, without boosting quiet ones.
                let gain = Float(min(1, 0.5 / max(0.0001, rendered.report.peak)))
                try player.play(url: rendered.url, volume: gain) { [weak self] in
                    guard let self, self.token == request else { return }; self.stop()
                }
                guard self.token == request else { return }
                phase = .playing; task = nil
            } catch is CancellationError {
                if self.token == request { self.stop() }
            } catch {
                if self.token == request { self.stop(); self.error = error.localizedDescription }
            }
        }
    }
    func stop() {
        token = UUID(); task?.cancel(); task = nil
        player.stop(); resources = nil
        if let focusToken { focusCoordinator.release(focusToken) }
        focusToken = nil; instrumentID = nil; phase = .idle; error = nil
    }
    func shutdown() {
        stop()
        for entry in cache.values { try? FileManager.default.removeItem(at: entry.url) }
        cache.removeAll()
        if ownsDirectory { try? FileManager.default.removeItem(at: directory) }
    }
    private func isCurrent(_ request: UUID, focus: UUID) -> Bool {
        token == request && focusCoordinator.owns(focus)
    }
    private func trimCache() {
        while cache.count > maximumCacheEntries, let oldest = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            try? FileManager.default.removeItem(at: oldest.value.url); cache.removeValue(forKey: oldest.key)
        }
    }
    private static func removeAbandonedDirectories() {
        let prefix = "Unableton-SoundPreviews-"
        let root = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            let suffix = String(url.lastPathComponent.dropFirst(prefix.count))
            guard let separator = suffix.firstIndex(of: "-"),
                  let process = Int32(suffix[..<separator]), process > 0,
                  process != ProcessInfo.processInfo.processIdentifier,
                  UUID(uuidString: String(suffix[suffix.index(after: separator)...])) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // ESRCH proves the process is gone. Permission failures or malformed
            // paths are not permission to delete another process's cache.
            if Darwin.kill(process, 0) == -1 && errno == ESRCH { try? FileManager.default.removeItem(at: url) }
        }
    }
    deinit { if ownsDirectory { try? FileManager.default.removeItem(at: directory) } }
}
