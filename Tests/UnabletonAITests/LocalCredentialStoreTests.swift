import Foundation
import Testing
@testable import UnabletonAI

struct LocalCredentialStoreTests {
    private func fixture() -> (URL, LocalCredentialStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (root, LocalCredentialStore(url: root.appendingPathComponent("private/credentials.json")))
    }

    @Test func missingLocalKeyDoesNotCreateAFile() throws {
        let (root, store) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.load(provider: "openai") == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func storesAllProvidersWithPrivatePermissionsAndRetainsOtherKeys() throws {
        let (root, store) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.merge(["openai": " test-openai ", "rinoa": "test-rinoa"])
        try store.save("test-audial", provider: "audial")
        let reopened = LocalCredentialStore(url: store.url)
        #expect(try reopened.load(provider: "openai") == "test-openai")
        #expect(try reopened.load(provider: "rinoa") == "test-rinoa")
        #expect(try reopened.load(provider: "audial") == "test-audial")
        let file = try FileManager.default.attributesOfItem(atPath: store.url.path)
        let directory = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try reopened.delete(provider: "rinoa")
        #expect(try store.load(provider: "rinoa") == nil)
        #expect(try store.load(provider: "openai") == "test-openai")
        #expect(try store.load(provider: "audial") == "test-audial")
    }

    @Test func concurrentProviderUpdatesDoNotLoseKeys() async throws {
        let (root, store) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                for provider in ["openai", "rinoa", "audial"] {
                    group.addTask { try store.save("test-" + provider, provider: provider) }
                }
            }
            try await group.waitForAll()
        }
        for provider in ["openai", "rinoa", "audial"] {
            #expect(try store.load(provider: provider) == "test-" + provider)
        }
    }

    @Test func malformedFileIsNotOverwrittenAndErrorsDoNotExposeContents() throws {
        let (root, store) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.save("test-openai", provider: "openai")
        let malformed = Data("private-fixture-value invalid JSON".utf8)
        try malformed.write(to: store.url)
        do {
            try store.save("test-rinoa", provider: "rinoa")
            Issue.record("Malformed credentials should be rejected.")
        } catch { #expect(!error.localizedDescription.contains("private-fixture-value")) }
        #expect(try Data(contentsOf: store.url) == malformed)
    }

    @Test func rejectsPublicPermissionsAndSymbolicLinks() throws {
        let (root, store) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.save("test-openai", provider: "openai")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        #expect(throws: (any Error).self) { try store.load(provider: "openai") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        let target = root.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: store.url, to: target)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.load(provider: "openai") }
        #expect(throws: (any Error).self) { try store.save("replacement", provider: "openai") }
        #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: target))["openai"] == "test-openai")
    }

    @Test func invalidProviderAndOversizedValuesCannotReplaceSavedKeys() throws {
        let (root, store) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.save("test-openai", provider: "openai")
        #expect(throws: (any Error).self) { try store.save("test", provider: "unknown") }
        #expect(throws: (any Error).self) { try store.save(String(repeating: "x", count: 20_000), provider: "openai") }
        #expect(try store.load(provider: "openai") == "test-openai")
    }
}
