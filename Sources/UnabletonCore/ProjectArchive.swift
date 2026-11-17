import Foundation

/// A save wrapper owns its immutable source files until SwiftUI finishes writing it.
private final class LeasedProjectWrapper: FileWrapper, @unchecked Sendable {
    private let blobLease: ProjectBlobLease?
    init(children: [String: FileWrapper], lease: ProjectBlobLease?) {
        blobLease = lease
        super.init(directoryWithFileWrappers: children)
    }
    required init?(coder: NSCoder) {
        blobLease = nil
        super.init(coder: coder)
    }
}

/// The package snapshot is self-contained. Filenames are generated from IDs, never model paths.
public enum ProjectArchive {
    /// Check the exact on-disk encoding before publishing a metadata transaction.
    public static func validateMetadata(_ project: ProjectFile) throws {
        _ = try encodedMetadata(project)
    }

    public static func encode(project: ProjectFile, assets: [UUID: Data]) throws -> FileWrapper {
        try validate(project)
        var audio: [String: FileWrapper] = [:], sizes: [UUID: Int] = [:]
        for (id, name) in requiredFiles(project) {
            guard let bytes = assets[id], !bytes.isEmpty else { throw ProjectError("Missing audio data for \(name).") }
            try validateSource(id: id, bytes: bytes, project: project)
            audio[id.uuidString] = FileWrapper(regularFileWithContents: bytes); sizes[id] = bytes.count
        }
        try validateRetainedSize(project, sizes: sizes)
        return try wrapper(project, audio: audio)
    }

    /// URL children defer reads, but Foundation may still materialize a file while saving.
    /// Callers must retain the bounded workload; this is not a streaming writer.
    public static func encode(project: ProjectFile, blobURLs: [UUID: URL], lease: ProjectBlobLease? = nil) throws -> FileWrapper {
        try validate(project)
        var audio: [String: FileWrapper] = [:], sizes: [UUID: Int] = [:]
        for (id, name) in requiredFiles(project) {
            guard let url = blobURLs[id] else { throw ProjectError("Missing audio data for \(name).") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 else { throw ProjectError("Invalid audio file for \(name).") }
            if let attachment = project.attachments?.first(where: { $0.id == id }) {
                guard size == attachment.byteCount, try SongAttachmentLimits.sha256(file: url) == attachment.sha256 else { throw ProjectError("Song attachment data changed: \(name).") }
            }
            sizes[id] = size
            audio[id.uuidString] = try FileWrapper(url: url, options: [])
        }
        try validateRetainedSize(project, sizes: sizes)
        return try wrapper(project, audio: audio, lease: lease)
    }

    public static func decode(_ wrapper: FileWrapper) throws -> (project: ProjectFile, assets: [UUID: Data]) {
        let project = try metadata(wrapper)
        var assets: [UUID: Data] = [:], sizes: [UUID: Int] = [:]
        for (id, name) in requiredFiles(project) {
            let bytes = try contents(wrapper, id: id, name: name)
            try validateSource(id: id, bytes: bytes, project: project)
            assets[id] = bytes; sizes[id] = bytes.count
        }
        try validateRetainedSize(project, sizes: sizes)
        return (project, assets)
    }

    public static func decodeFiles(_ wrapper: FileWrapper, into store: ProjectBlobStore) throws -> (project: ProjectFile, assets: [UUID: URL]) {
        let project = try metadata(wrapper)
        var assets: [UUID: URL] = [:], sizes: [UUID: Int] = [:]
        for (id, name) in requiredFiles(project) {
            let bytes = try contents(wrapper, id: id, name: name)
            try validateSource(id: id, bytes: bytes, project: project)
            sizes[id] = bytes.count
            try validateRetainedSize(project, sizes: sizes)
            assets[id] = try store.insert(data: bytes, id: id)
        }
        return (project, assets)
    }

    private static func validate(_ project: ProjectFile) throws {
        guard project.formatVersion == 1 else { throw ProjectError("Unsupported project version.") }
        try ProjectEditor.validate(project.song)
        try SongAttachmentLimits.validate(project)
    }

    private static func requiredFiles(_ project: ProjectFile) -> [(UUID, String)] {
        var found = Set<UUID>(), files: [(UUID, String)] = []
        for asset in project.song.assets where found.insert(asset.id).inserted { files.append((asset.id, asset.fileName)) }
        for attachment in project.attachments ?? [] where found.insert(attachment.id).inserted { files.append((attachment.id, attachment.fileName)) }
        return files
    }

    private static func wrapper(_ project: ProjectFile, audio: [String: FileWrapper], lease: ProjectBlobLease? = nil) throws -> FileWrapper {
        let data = try encodedMetadata(project)
        return LeasedProjectWrapper(children: [
            "project.json": FileWrapper(regularFileWithContents: data),
            "Audio": FileWrapper(directoryWithFileWrappers: audio)
        ], lease: lease)
    }

    private static func encodedMetadata(_ project: ProjectFile) throws -> Data {
        try validate(project)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        guard data.count <= SongAttachmentLimits.maximumMetadataBytes else { throw ProjectError("Project metadata exceeds the supported size.") }
        return data
    }

    private static func metadata(_ wrapper: FileWrapper) throws -> ProjectFile {
        guard wrapper.isDirectory, !wrapper.isSymbolicLink,
              let metadata = wrapper.fileWrappers?["project.json"], metadata.isRegularFile, !metadata.isSymbolicLink,
              (knownSize(metadata) ?? 0) <= SongAttachmentLimits.maximumMetadataBytes,
              let data = metadata.regularFileContents, data.count <= SongAttachmentLimits.maximumMetadataBytes else { throw ProjectError("This is not a supported Unableton project package.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try value.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: text) else { throw ProjectError("Invalid date in project metadata.") }
            return date
        }
        let project = try decoder.decode(ProjectFile.self, from: data)
        guard project.formatVersion == 1 else { throw ProjectError("This project was saved by a newer version of Unableton.") }
        try validate(project)
        if let audio = wrapper.fileWrappers?["Audio"] {
            guard audio.isDirectory, !audio.isSymbolicLink else { throw ProjectError("The project audio store is invalid.") }
            for (name, child) in audio.fileWrappers ?? [:] {
                guard UUID(uuidString: name) != nil, child.isRegularFile, !child.isSymbolicLink else { throw ProjectError("The project contains an unsafe audio entry.") }
            }
            var sizes: [UUID: Int] = [:]
            for (id, _) in requiredFiles(project) {
                if let child = audio.fileWrappers?[id.uuidString], let size = knownSize(child) {
                    guard size > 0 else { throw ProjectError("The project contains an empty audio file.") }
                    sizes[id] = size
                    if let attachment = project.attachments?.first(where: { $0.id == id }), size != attachment.byteCount {
                        throw ProjectError("The project contains an oversized or incomplete song attachment.")
                    }
                }
            }
            try validateRetainedSize(project, sizes: sizes)
        }
        return project
    }

    private static func knownSize(_ wrapper: FileWrapper) -> Int? {
        (wrapper.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue
    }

    private static func contents(_ wrapper: FileWrapper, id: UUID, name: String) throws -> Data {
        guard let item = wrapper.fileWrappers?["Audio"]?.fileWrappers?[id.uuidString], item.isRegularFile, !item.isSymbolicLink,
              let data = item.regularFileContents, !data.isEmpty else { throw ProjectError("Missing audio data for \(name).") }
        return data
    }

    private static func validateSource(id: UUID, bytes: Data, project: ProjectFile) throws {
        if let attachment = project.attachments?.first(where: { $0.id == id }) {
            guard bytes.count == attachment.byteCount, SongAttachmentLimits.sha256(bytes) == attachment.sha256 else { throw ProjectError("Song attachment data is damaged: \(attachment.fileName).") }
        }
    }

    private static func validateRetainedSize(_ project: ProjectFile, sizes: [UUID: Int]) throws {
        let related = Set((project.attachments ?? []).map(\.id) + project.song.assets.filter { $0.referenceDerivation != nil }.map(\.id))
        var total = 0
        for id in related {
            total += sizes[id] ?? 0
            guard total <= SongAttachmentLimits.maximumRetainedBytes else { throw ProjectError("Reference songs and derived audio exceed the 1 GiB project limit. Shorten the selected audio ranges.") }
        }
    }
}
