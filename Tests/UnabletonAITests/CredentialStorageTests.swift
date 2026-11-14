import Foundation
import Testing
@testable import UnabletonAI

struct CredentialStorageTests {
    private func fixture() throws -> (UserDefaults, String) {
        let name = "org.unableton.CredentialStorageTests." + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func newPreferencesUseFileStorageWithoutKeychainOptIn() throws {
        let (defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(defaults.object(forKey: CredentialStore.storagePreferenceKey) == nil)
        #expect(CredentialStorage.selected(in: defaults) == .file)
    }

    @Test func enablingKeychainSelectsKeychainStorage() throws {
        let (defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: CredentialStore.storagePreferenceKey)
        #expect(CredentialStorage.selected(in: defaults) == .keychain)
    }

    @Test func disablingKeychainReturnsToFileStorage() throws {
        let (defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: CredentialStore.storagePreferenceKey)
        defaults.set(false, forKey: CredentialStore.storagePreferenceKey)
        #expect(CredentialStorage.selected(in: defaults) == .file)
    }

    @Test func legacyDevelopmentPreferenceDoesNotCountAsKeychainConsent() throws {
        let (defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        for oldValue in ["keychain", "developmentFile"] {
            defaults.set(oldValue, forKey: "development.credentialStorage")
            #expect(CredentialStorage.selected(in: defaults) == .file)
        }
    }

    @Test func keychainOperationsRequireCurrentExplicitConsent() throws {
        let (defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(throws: (any Error).self) { try CredentialStore.requireKeychainEnabled(in: defaults) }
        defaults.set(true, forKey: CredentialStore.storagePreferenceKey)
        try CredentialStore.requireKeychainEnabled(in: defaults)
        defaults.set(false, forKey: CredentialStore.storagePreferenceKey)
        #expect(throws: (any Error).self) { try CredentialStore.requireKeychainEnabled(in: defaults) }
    }
}
