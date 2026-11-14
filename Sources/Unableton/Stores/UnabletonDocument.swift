import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UnabletonCore

extension UTType {
    static let unabletonProject = UTType(exportedAs: "org.unableton.project", conformingTo: .package)
}

struct UnabletonSnapshot: Sendable {
    var project: ProjectFile
    var assets: [UUID: Data]
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
    @Published var assets: [UUID: Data] { didSet { refreshSnapshot() } }
    @MainActor weak var nativeDocument: NSDocument?
    @MainActor private var cachedUndoManager: UndoManager?
    @MainActor var editingUndoManager: UndoManager {
        if let cachedUndoManager { return cachedUndoManager }
        let manager = UndoManager(); cachedUndoManager = manager; return manager
    }
    private let archive: ArchiveSnapshotStore
    init(project: ProjectFile = ProjectFile(), assets: [UUID: Data] = [:]) {
        self.project = project; self.assets = assets
        archive = ArchiveSnapshotStore(UnabletonSnapshot(project: project, assets: assets))
    }
    required convenience init(configuration: ReadConfiguration) throws {
        let decoded = try ProjectArchive.decode(configuration.file)
        self.init(project: decoded.project, assets: decoded.assets)
    }
    private func refreshSnapshot() { archive.set(UnabletonSnapshot(project: project, assets: assets)) }
    func snapshot(contentType: UTType) throws -> UnabletonSnapshot { archive.get() }
    func fileWrapper(snapshot: UnabletonSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try ProjectArchive.encode(project: snapshot.project, assets: snapshot.assets)
    }
}
