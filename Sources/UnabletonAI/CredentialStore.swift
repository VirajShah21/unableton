import Foundation
import Security

public enum CredentialStorage: String, CaseIterable, Identifiable, Sendable {
    case file
    case keychain

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .file: "Local file"
        case .keychain: "Keychain"
        }
    }
    public static func selected(in defaults: UserDefaults) -> CredentialStorage {
        defaults.bool(forKey: CredentialStore.storagePreferenceKey) ? .keychain : .file
    }
}

/// Credentials never enter project documents, app bundles, logs or the agent transcript.
public enum CredentialStore {
    public static let storagePreferenceKey = "credentials.useMacOSKeychain"
    public static var storage: CredentialStorage { CredentialStorage.selected(in: .standard) }
    public static var fileURL: URL { fileStore.url }
    private static let fileStore: LocalCredentialStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = support.appendingPathComponent("Unableton/Credentials/credentials.json")
        let legacy = support.appendingPathComponent("Unableton/Development/credentials.json")
        // Keep any previously saved file in place. This never opens Keychain,
        // migrates secrets or treats the old preference as Keychain consent.
        let existingLegacy = !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path)
        return LocalCredentialStore(url: existingLegacy ? legacy : current)
    }()

    static func requireKeychainEnabled(in defaults: UserDefaults = .standard) throws {
        guard CredentialStorage.selected(in: defaults) == .keychain else {
            throw AgentError.configuration("Enable ‘Use macOS Keychain for Credentials’ in Settings before accessing Keychain.")
        }
    }

    private static func service(_ provider: String) -> String { "org.unableton." + provider }
    private static let account = "api-key"
    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(provider), kSecAttrAccount as String: account]
    }
    public static func load(provider: String = "openai", storage selectedStorage: CredentialStorage? = nil) throws -> String? {
        if (selectedStorage ?? storage) == .file { return try fileStore.load(provider: provider) }
        try requireKeychainEnabled()
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        try check(code)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ apiKey: String, provider: String = "openai", storage selectedStorage: CredentialStorage? = nil) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.configuration("Enter an API key.") }
        if (selectedStorage ?? storage) == .file { try fileStore.save(key, provider: provider); return }
        try requireKeychainEnabled()
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let code = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            var q = query(provider).merging(attributes) { _, new in new }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(q as CFDictionary, nil))
        } else { try check(code) }
    }
    public static func delete(provider: String = "openai", storage selectedStorage: CredentialStorage? = nil) throws {
        if (selectedStorage ?? storage) == .file { try fileStore.delete(provider: provider); return }
        try requireKeychainEnabled()
        let code = SecItemDelete(query(provider) as CFDictionary)
        if code != errSecItemNotFound { try check(code) }
    }
    private static func check(_ code: OSStatus) throws {
        guard code == errSecSuccess else {
            throw AgentError.configuration("Keychain: \(SecCopyErrorMessageString(code, nil) as String? ?? String(code))")
        }
    }
}
