import Foundation

/// Immutable files outlive editing sessions while saves, playback or Undo hold a lease.
private final class BlobLifetime: @unchecked Sendable {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    deinit {
        let directory = directory
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
    }
}

public final class ProjectBlobLease: @unchecked Sendable {
    private let lifetime: BlobLifetime
    fileprivate init(_ lifetime: BlobLifetime) { self.lifetime = lifetime }
}

public struct ProjectBlobSnapshot: Sendable {
    public let urls: [UUID: URL]
    public let lease: ProjectBlobLease
}

public final class ProjectBlobStore: @unchecked Sendable {
    private let lifetime: BlobLifetime
    private let lock = NSLock()
    private var files: [UUID: URL] = [:]
    public var directory: URL { lifetime.directory }

    public init(parentDirectory: URL = FileManager.default.temporaryDirectory) throws {
        let directory = parentDirectory.appendingPathComponent("UnabletonBlobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lifetime = BlobLifetime(directory)
    }

    @discardableResult public func insert(data: Data, id: UUID, maximumBytes: Int = Int.max) throws -> URL {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ProjectError("Audio payload is empty or exceeds its storage limit.") }
        if let existing = knownFile(id) {
            guard try SongAttachmentLimits.sha256(file: existing) == SongAttachmentLimits.sha256(data) else { throw ProjectError("An immutable audio identifier was reused with different data.") }
            return existing
        }
        let staging = directory.appendingPathComponent("Staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        return try publish(staging: staging, id: id)
    }

    @discardableResult public func insert(file: URL, id: UUID, maximumBytes: Int = Int.max) throws -> URL {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else { throw ProjectError("Audio source must be a regular, nonempty file within its storage limit.") }
        if let existing = knownFile(id) {
            guard try SongAttachmentLimits.sha256(file: existing) == SongAttachmentLimits.sha256(file: file) else { throw ProjectError("An immutable audio identifier was reused with different data.") }
            return existing
        }
        let staging = directory.appendingPathComponent("Staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: file, to: staging)
        let copiedValues = try staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let copied = copiedValues.fileSize ?? 0
        guard copiedValues.isRegularFile == true, copiedValues.isSymbolicLink != true,
              copied == size, copied <= maximumBytes,
              try SongAttachmentLimits.sha256(file: staging) == SongAttachmentLimits.sha256(file: file) else { throw ProjectError("The source file changed while it was being copied.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        return try publish(staging: staging, id: id)
    }

    private func knownFile(_ id: UUID) -> URL? {
        lock.lock(); defer { lock.unlock() }; return files[id]
    }

    /// Only the final rename and registry publication hold the snapshot lock.
    /// Copying, encoding and hashing can therefore never block a UI snapshot.
    private func publish(staging: URL, id: UUID) throws -> URL {
        lock.lock()
        if let existing = files[id] {
            lock.unlock()
            guard try SongAttachmentLimits.sha256(file: existing) == SongAttachmentLimits.sha256(file: staging) else { throw ProjectError("An immutable audio identifier was reused with different data.") }
            return existing
        }
        let output = directory.appendingPathComponent(id.uuidString)
        do {
            try FileManager.default.moveItem(at: staging, to: output)
            files[id] = output
            lock.unlock()
            return output
        } catch { lock.unlock(); throw error }
    }

    /// Roll back caller-owned preparation only. The caller must guarantee these
    /// IDs have NEVER appeared in document metadata, Undo, playback or a save.
    /// Published blobs remain immutable and retained for the store's lifetime.
    public func discardUnpublished(ids: Set<UUID>) throws {
        for id in ids {
            lock.lock()
            do {
                if let url = files[id] {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    files.removeValue(forKey: id)
                }
                lock.unlock()
            } catch { lock.unlock(); throw error }
        }
    }

    public func snapshot(ids: Set<UUID>? = nil) -> ProjectBlobSnapshot {
        lock.lock(); defer { lock.unlock() }
        return ProjectBlobSnapshot(urls: ids.map { selected in files.filter { selected.contains($0.key) } } ?? files,
                                   lease: ProjectBlobLease(lifetime))
    }
}
