import Foundation

/// The package snapshot is self-contained. Asset filenames are generated from IDs, never model paths.
public enum ProjectArchive {
    public static func encode(project: ProjectFile, assets: [UUID: Data]) throws -> FileWrapper {
        try ProjectEditor.validate(project.song)
        guard project.formatVersion == 1 else { throw ProjectError("Unsupported project version.") }
        // Foundation's numeric Date representation preserves subsecond precision exactly.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var audio: [String: FileWrapper] = [:]
        for asset in project.song.assets {
            guard let bytes = assets[asset.id], !bytes.isEmpty else { throw ProjectError("Missing audio data for \(asset.fileName).") }
            audio[asset.id.uuidString] = FileWrapper(regularFileWithContents: bytes)
        }
        return FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: try encoder.encode(project)),
            "Audio": FileWrapper(directoryWithFileWrappers: audio)
        ])
    }
    public static func decode(_ wrapper: FileWrapper) throws -> (project: ProjectFile, assets: [UUID: Data]) {
        guard wrapper.isDirectory, let data = wrapper.fileWrappers?["project.json"]?.regularFileContents else { throw ProjectError("This is not an Unableton project package.") }
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
        try ProjectEditor.validate(project.song)
        var assets: [UUID: Data] = [:]
        for asset in project.song.assets {
            guard let bytes = wrapper.fileWrappers?["Audio"]?.fileWrappers?[asset.id.uuidString]?.regularFileContents, !bytes.isEmpty else { throw ProjectError("Missing audio data for \(asset.fileName).") }
            assets[asset.id] = bytes
        }
        return (project, assets)
    }
}
