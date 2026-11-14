import Foundation
import Darwin

/// Private local plaintext storage. The lock covers the complete read/modify/write
/// transaction so concurrent saves for different providers cannot lose a key.
final class LocalCredentialStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let providers: Set<String> = ["openai", "rinoa", "audial", "typesafe"]
    private let maximumBytes = 64 * 1024

    init(url: URL) { self.url = url }

    func load(provider: String) throws -> String? {
        try lock.withLock {
            try validateProvider(provider)
            return try read()[provider]
        }
    }
    func save(_ key: String, provider: String) throws {
        try merge([provider: key])
    }
    func merge(_ keys: [String: String]) throws {
        try lock.withLock {
            guard !keys.isEmpty else { return }
            for (provider, key) in keys {
                try validateProvider(provider)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      key.utf8.count <= 16 * 1024 else { throw failure("Enter a valid API key.") }
            }
            var existing = try read()
            existing.merge(keys.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) { _, new in new }
            try write(existing)
        }
    }
    func delete(provider: String) throws {
        try lock.withLock {
            try validateProvider(provider)
            var existing = try read()
            guard existing.removeValue(forKey: provider) != nil else { return }
            try write(existing)
        }
    }
    private func validateProvider(_ provider: String) throws {
        guard providers.contains(provider) else { throw failure("Unsupported credential provider.") }
    }
    private func failure(_ message: String) -> AgentError {
        .configuration("Local credentials: " + message)
    }
    private func attributes(_ path: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: path.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        catch { throw failure("Could not inspect the local file. No Keychain fallback was attempted.") }
    }
    private func verify(_ attributes: [FileAttributeKey: Any], type: FileAttributeType) throws {
        guard attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw failure("The local file and its directory must belong to you, have owner-only permissions, and must not be symbolic links.")
        }
    }
    private func directory(create: Bool) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        if let existing = try attributes(directory) { try verify(existing, type: .typeDirectory); return true }
        guard create else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw failure("Could not create the private credentials directory.") }
        guard let created = try attributes(directory) else { throw failure("The credentials directory is missing.") }
        try verify(created, type: .typeDirectory)
        return true
    }
    private func read() throws -> [String: String] {
        guard try directory(create: false), let existing = try attributes(url) else { return [:] }
        try verify(existing, type: .typeRegular)
        guard let size = existing[.size] as? NSNumber, size.intValue <= maximumBytes else { throw failure("The local file is too large.") }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= maximumBytes else { throw failure("The local file is too large.") }
            let keys = try JSONDecoder().decode([String: String].self, from: data)
            guard keys.keys.allSatisfy(providers.contains), keys.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 }) else {
                throw failure("Invalid local credential file.")
            }
            return keys
        } catch { throw failure("Could not read the local credential file. No Keychain fallback was attempted.") }
    }
    private func write(_ keys: [String: String]) throws {
        _ = try directory(create: true)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(keys)
            guard data.count <= maximumBytes else { throw failure("The local file is too large.") }
            // Atomic replacement happens inside the private 0700 directory.
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw failure("Could not save the local credential file.") }
    }
}
