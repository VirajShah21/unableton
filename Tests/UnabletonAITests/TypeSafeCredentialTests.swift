import Foundation
import Testing
@testable import UnabletonAI

struct TypeSafeCredentialTests {
    @Test func typeSafeKeyCoexistsWithOtherProvidersInPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-TypeSafe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalCredentialStore(url: directory.appendingPathComponent("credentials.json"))
        try store.save("openai-fixture", provider: "openai")
        try store.save("typesafe-fixture", provider: "typesafe")
        #expect(try store.load(provider: "typesafe") == "typesafe-fixture")
        try store.delete(provider: "typesafe")
        #expect(try store.load(provider: "typesafe") == nil)
        #expect(try store.load(provider: "openai") == "openai-fixture")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
