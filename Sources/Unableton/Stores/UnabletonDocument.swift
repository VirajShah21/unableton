import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UnabletonCore

extension UTType {
    static let unabletonProject = UTType(exportedAs: "org.unableton.project", conformingTo: .package)
}

struct UnabletonSnapshot: Sendable {
    var project: ProjectFile
    var blobs: ProjectBlobSnapshot?
    var storageError: String?
    var assets: [UUID: Data] { (blobs?.urls ?? [:]).compactMapValues { try? Data(contentsOf: $0) } }
}

/// Editing occurs on the main actor. SwiftUI's background save reads only this
/// immutable, locked snapshot, never the observable editing properties.
private final class ArchiveSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UnabletonSnapshot
    init(_ value: UnabletonSnapshot) { self.value = value }
    func set(_ next: UnabletonSnapshot) { lock.lock(); defer { lock.unlock() }; value = next }
    func get() -> UnabletonSnapshot { lock.lock(); defer { lock.unlock() }; return value }
}

final class UnabletonDocument: ReferenceFileDocument, @unchecked Sendable {
    static var readableContentTypes: [UTType] { [.unabletonProject] }
    @Published var project: ProjectFile { didSet { refreshSnapshot() } }
    @Published private(set) var blobURLs: [UUID: URL] = [:]
    let blobStore: ProjectBlobStore?
    private(set) var storageError: String?
    /// Compatibility access for small callers and tests. Production paths install
    /// individual immutable files instead of rebuilding an in-memory asset map.
    var assets: [UUID: Data] {
        get { blobURLs.compactMapValues { try? Data(contentsOf: $0) } }
        set {
            do {
                guard let blobStore else { throw ProjectError(storageError ?? "The project audio store is unavailable.") }
                for (id, data) in newValue { try blobStore.insert(data: data, id: id) }
                blobURLs = blobStore.snapshot().urls; storageError = nil
            } catch { storageError = error.localizedDescription }
            refreshSnapshot()
        }
    }
    @MainActor weak var nativeDocument: NSDocument?
    @MainActor private var cachedUndoManager: UndoManager?
    @MainActor var editingUndoManager: UndoManager {
        if let cachedUndoManager { return cachedUndoManager }
        let manager = UndoManager(); cachedUndoManager = manager; return manager
    }
    private let archive: ArchiveSnapshotStore
    init(project: ProjectFile = ProjectFile(), assets: [UUID: Data] = [:]) {
        self.project = project
        let store = try? ProjectBlobStore()
        blobStore = store
        archive = ArchiveSnapshotStore(UnabletonSnapshot(project: project, blobs: nil, storageError: nil))
        self.assets = assets
        if store == nil { storageError = "Could not create the project audio store."; refreshSnapshot() }
    }
    required convenience init(configuration: ReadConfiguration) throws {
        self.init()
        guard let blobStore else { throw ProjectError(storageError ?? "Could not open the project audio store.") }
        let decoded = try ProjectArchive.decodeFiles(configuration.file, into: blobStore)
        blobURLs = decoded.assets
        project = decoded.project
    }
    func install(files: [UUID: URL]) throws {
        guard let blobStore else { throw ProjectError(storageError ?? "The project audio store is unavailable.") }
        for (id, url) in files { try blobStore.insert(file: url, id: id) }
        blobURLs = blobStore.snapshot().urls
        refreshSnapshot()
    }
    func publishInstalledBlobs() {
        blobURLs = blobStore?.snapshot().urls ?? [:]
        refreshSnapshot()
    }
    func install(data: Data, id: UUID) throws -> URL {
        guard let blobStore else { throw ProjectError(storageError ?? "The project audio store is unavailable.") }
        let url = try blobStore.insert(data: data, id: id)
        blobURLs = blobStore.snapshot().urls
        refreshSnapshot()
        return url
    }
    private func refreshSnapshot() { archive.set(UnabletonSnapshot(project: project, blobs: blobStore?.snapshot(), storageError: storageError)) }
    func snapshot(contentType: UTType) throws -> UnabletonSnapshot { archive.get() }
    func fileWrapper(snapshot: UnabletonSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        if let error = snapshot.storageError { throw ProjectError(error) }
        return try ProjectArchive.encode(project: snapshot.project, blobURLs: snapshot.blobs?.urls ?? [:], lease: snapshot.blobs?.lease)
    }
}
