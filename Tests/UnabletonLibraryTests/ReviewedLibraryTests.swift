import Foundation
import Testing
import UnabletonCore
import UnabletonLibrary

struct ReviewedLibraryTests {
    @Test func completeShippedCatalogStartsEmptyAndBuiltinResourcesNeedNoFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewedLibrary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SoundLibrary(root: root)
        let states = await library.snapshot()
        #expect(states.count == SoundBankCatalog.banks.count)
        #expect(states.values.allSatisfy { $0 == .notInstalled })
        let builtin = Set(InstrumentCatalog.presets.filter { !$0.isSampler }.map(\.id))
        #expect(builtin.count == 6)
        let resources = try await library.acquire(instrumentIDs: builtin)
        #expect(resources.urls.isEmpty)
        await resources.release()
        for preset in InstrumentCatalog.presets where preset.isSampler {
            #expect(preset.soundBankID.flatMap { SoundBankCatalog.bank(id: $0) } != nil)
        }
    }
}
