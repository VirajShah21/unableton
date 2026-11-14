import Foundation
import Testing
import UnabletonCore
import UnabletonLibrary
@testable import Unableton

@Suite @MainActor
struct SoundLibraryPresentationTests {
    @Test func everyReviewedSoundHasAnExplicitFamilyAndUniqueDisplayName() {
        let items = SoundLibraryPresentation.items
        #expect(Set(items.map(\.id)) == Set(InstrumentCatalog.presets.map(\.id)))
        #expect(Set(SoundLibraryPresentation.familiesByID.keys) == Set(items.map(\.id)))
        #expect(Set(items.map(\.family)) == Set(SoundFamily.allCases))
        #expect(Set(items.map(\.name)).count == items.count)
        #expect(items.allSatisfy { !$0.name.isEmpty && !$0.description.isEmpty })
        #expect(SoundLibraryPresentation.item(id: "sampled.piano")?.family == .pianos)
        #expect(SoundLibraryPresentation.item(id: "sampled.mallets")?.family == .malletsAndPercussion)
        #expect(SoundLibraryPresentation.item(id: "synth.strings")?.family == .synthesizers)
    }

    @Test func conciseNamesPreserveSourceIdentityAndProgramVariants() {
        let variants = ["freepats.fm-piano1.0.0", "freepats.fm-piano1.0.1", "freepats.fm-piano1.0.2", "freepats.fm-piano1.0.3"]
        let items = variants.compactMap(SoundLibraryPresentation.item(id:))
        #expect(items.count == 4)
        #expect(Set(items.map(\.name)).count == 4)
        #expect(Set(items.compactMap { $0.preset.soundBankID }).count == 1)
        #expect(items.allSatisfy { $0.sourceName == $0.preset.name })
        #expect(SoundLibraryPresentation.item(id: "sampled.drums")?.warning != nil)
        #expect(SoundLibraryPresentation.item(id: "drums.electronic")?.warning == nil)
    }

    @Test func filtersSearchOriginalNamesRolesProvidersAndFamilies() {
        let model = SoundLibraryPresentation()
        model.search = "FSS Steel-String"
        #expect(model.sounds(states: [:]).map(\.id) == ["freepats.fss-steelstringguitar"])
        model.search = "FreePats bass"
        #expect(!model.sounds(states: [:]).isEmpty)
        #expect(model.sounds(states: [:]).allSatisfy { $0.providerID == "freepats" })
        model.search = "mallets"
        #expect(model.sounds(states: [:]).contains { $0.id == "sampled.mallets" })
        model.search = ""
        model.sourceID = "builtin"
        #expect(model.sounds(states: [:]).count == 6)
        model.sourceID = "freepats"
        model.destination = .family(.winds)
        #expect(model.sounds(states: [:]).count == 3)
    }

    @Test func tileDescriptionsStayConciseWhileTechnicalSourceTextRemainsSearchable() {
        #expect(SoundLibraryPresentation.items.allSatisfy { $0.description.count <= 100 })
        #expect(SoundLibraryPresentation.items.allSatisfy { !$0.description.localizedCaseInsensitiveContains("parameters differ") })
        let model = SoundLibraryPresentation()
        model.search = "parameters differ"
        #expect(model.sounds(states: [:]).contains { $0.id == "freepats.synthbass1" })
        #expect(SoundLibraryPresentation.item(id: "freepats.synthbass1")?.preset.description.contains("Parameters differ") == true)
    }

    @Test func onThisMacIncludesBuiltInsAndEveryPresetInInstalledBanks() throws {
        let model = SoundLibraryPresentation()
        model.destination = .onThisMac
        let bank = try #require(SoundLibraryPresentation.item(id: "freepats.fm-piano1.0.0")?.bank)
        let result = model.sounds(states: [bank.id: .installed(bytes: bank.installedBytes, inUse: false)])
        #expect(result.count == 10)
        #expect(result.filter { $0.preset.soundBankID == bank.id }.count == 4)
        #expect(result.filter(\.isBuiltIn).count == 6)
    }

    @Test func hiddenSelectionIsClearedWithoutSelectingAnUnrelatedSound() {
        let model = SoundLibraryPresentation()
        model.selection = "sampled.guitar"
        model.search = "xylophone"
        #expect(model.reconcileSelection(states: [:]))
        #expect(model.selection == nil)
        #expect(!model.reconcileSelection(states: [:]))
        model.selection = "sampled.mallets"
        #expect(!model.reconcileSelection(states: [:]))
        model.destination = .onThisMac
        #expect(model.reconcileSelection(states: [:]))
        #expect(model.selection == nil)
        model.clearFilters()
        #expect(!model.hasFilters)
        #expect(model.destination == .onThisMac)
    }

    @Test func downloadTotalsDeduplicateSharedBanksAndExcludeActiveAndInstalled() throws {
        let all = SoundLibraryPresentation.remainingDownloadSummary(states: [:])
        #expect(all.downloadCount == SoundBankCatalog.banks.count)
        #expect(all.soundCount == InstrumentCatalog.presets.filter(\.isSampler).count)
        let fm = try #require(SoundLibraryPresentation.item(id: "freepats.fm-piano1.0.0")?.bank)
        let piano = try #require(SoundBankCatalog.bank(id: "piano"))
        let states: [String: SoundBankState] = [fm.id: .downloading(received: 1, total: fm.downloadBytes), piano.id: .installed(bytes: piano.installedBytes, inUse: true)]
        let remaining = SoundLibraryPresentation.remainingDownloadSummary(states: states)
        #expect(remaining.downloadCount == all.downloadCount - 2)
        #expect(remaining.soundCount == all.soundCount - 5)
        #expect(remaining.downloadBytes == all.downloadBytes - fm.downloadBytes - piano.downloadBytes)
        #expect(remaining.installedBytes == all.installedBytes - fm.installedBytes - piano.installedBytes)
        #expect(SoundLibraryPresentation.sharedBankPresets(fm.id).count == 4)
        #expect(SoundLibraryPresentation.sharedBankPresets("not-a-bank").isEmpty)
    }

    @Test func downloadsDestinationIncludesFailuresActivityAndOnlyRecentCompletions() {
        let model = SoundLibraryPresentation()
        model.destination = .downloads
        let states: [String: SoundBankState] = ["piano": .installed(bytes: 1, inUse: false), "guitar": .queued, "bass": .failed("Offline")]
        #expect(Set(model.sounds(states: states).map(\.id)) == ["sampled.guitar", "sampled.bass"])
        #expect(Set(model.sounds(states: states, recentlyCompleted: ["piano"]).map(\.id)) == ["sampled.piano", "sampled.guitar", "sampled.bass"])
    }

    @Test func sizeSortAndNavigationStorageAreDeterministic() {
        let model = SoundLibraryPresentation()
        model.sort = .downloadSize
        let sizes = model.sounds(states: [:]).map(\.downloadBytes)
        #expect(sizes == sizes.sorted())
        for destination in [SoundLibraryDestination.all, .onThisMac, .downloads] + SoundFamily.allCases.map(SoundLibraryDestination.family) {
            #expect(SoundLibraryDestination(storageKey: destination.storageKey) == destination)
        }
        #expect(SoundLibraryDestination(storageKey: "old-value") == .all)
    }
}
