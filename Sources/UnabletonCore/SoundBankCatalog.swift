import Foundation

/// A reviewed, immutable downloadable artifact. IDs are provider-neutral;
/// installing content never changes the song or the catalog's musical identity.
public struct SoundBank: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceID: String
    public let version: String
    public let url: URL
    public let archiveSHA256: String
    public let member: String
    public let fileName: String
    public let sha256: String
    public let downloadBytes: Int64
    public let installedBytes: Int64
    public let license: String
    public let licenseURL: URL
    public let attribution: String
    public let sourceURL: URL

    public init(id: String, sourceID: String, version: String, url: URL, archiveSHA256: String, member: String,
                fileName: String, sha256: String, downloadBytes: Int64, installedBytes: Int64,
                license: String, licenseURL: URL, attribution: String, sourceURL: URL) {
        self.id = id; self.sourceID = sourceID; self.version = version; self.url = url
        self.archiveSHA256 = archiveSHA256; self.member = member; self.fileName = fileName; self.sha256 = sha256
        self.downloadBytes = downloadBytes; self.installedBytes = installedBytes
        self.license = license; self.licenseURL = licenseURL; self.attribution = attribution; self.sourceURL = sourceURL
    }
}

public enum SoundBankCatalog {
    public static let banks: [SoundBank] = content.banks
    public static func bank(id: String) -> SoundBank? { banks.first { $0.id == id } }
    static let additionalPresets: [InstrumentPreset] = content.presets

    private struct Content: Decodable {
        let banks: [SoundBank]
        let presets: [InstrumentPreset]
    }
    private static let content: Content = {
        let packagedBundle = Bundle.main.resourceURL?
            .appendingPathComponent("Unableton_UnabletonCore.bundle")
        // A packaged app must resolve its own resource bundle. Only package
        // executables/tests use SwiftPM's generated build-directory lookup.
        let bundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let packagedBundle, let installed = Bundle(url: packagedBundle) else {
                preconditionFailure("Unableton's reviewed sound catalog resource bundle is missing.")
            }
            bundle = installed
        } else {
            bundle = .module
        }
        guard let url = bundle.url(forResource: "sound-library", withExtension: "json"),
              let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode(Content.self, from: data) else {
            preconditionFailure("Unableton's reviewed sound catalog is missing or invalid.")
        }
        return result
    }()
}
