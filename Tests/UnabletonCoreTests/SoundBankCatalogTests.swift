import Foundation
import Testing
@testable import UnabletonCore

@Suite("Reviewed sound catalog")
struct SoundBankCatalogTests {
    @Test func catalogHasStableUniqueIdentitiesAndCompleteArtifacts() throws {
        let presets = InstrumentCatalog.presets
        let banks = SoundBankCatalog.banks
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(Set(banks.map(\.id)).count == banks.count)
        #expect(presets.filter { !$0.isSampler }.count == 6)
        #expect(banks.count >= 40)
        #expect(presets.filter(\.isSampler).count >= 40)
        for bank in banks {
            #expect(bank.sourceID == "freepats")
            #expect(bank.url.scheme == "https")
            #expect(bank.sourceURL.scheme == "https")
            #expect(bank.licenseURL.scheme == "https")
            #expect(bank.archiveSHA256.count == 64)
            #expect(bank.sha256.count == 64)
            #expect(bank.archiveSHA256.allSatisfy { $0.isHexDigit })
            #expect(bank.sha256.allSatisfy { $0.isHexDigit })
            #expect(bank.downloadBytes > 0 && bank.installedBytes > 0)
            #expect(!bank.version.isEmpty && !bank.attribution.isEmpty)
            #expect(!bank.member.hasPrefix("/") && !bank.member.split(separator: "/").contains(".."))
            #expect(!bank.fileName.contains("/") && bank.fileName.lowercased().hasSuffix(".sf2"))
            #expect(presets.contains { $0.soundBankID == bank.id })
            #expect(try JSONDecoder().decode(SoundBank.self, from: JSONEncoder().encode(bank)) == bank)
        }
        for preset in presets where preset.isSampler {
            let bankID = try #require(preset.soundBankID)
            #expect(SoundBankCatalog.bank(id: bankID) != nil)
            #expect(preset.minimumPitch >= 0 && preset.maximumPitch <= 127)
            #expect(preset.minimumPitch <= preset.maximumPitch)
            #expect(preset.program <= 127)
            #expect(!preset.description.isEmpty && !preset.roles.isEmpty)
        }
    }

    @Test func legacyInstrumentContractsRemainIntact() throws {
        let contracts = [("sampled.piano", "piano", 21, 108), ("sampled.guitar", "guitar", 29, 88),
                         ("sampled.bass", "bass", 26, 45), ("sampled.mallets", "mallets", 46, 99),
                         ("sampled.drums", "drums", 35, 59)]
        for (id, bankID, low, high) in contracts {
            let preset = try #require(InstrumentCatalog.preset(id: id))
            #expect(preset.soundBankID == bankID)
            #expect(preset.minimumPitch == low && preset.maximumPitch == high)
            #expect(preset.program == 0 && preset.bank == 0)
        }
        let drums = try #require(InstrumentCatalog.preset(id: "sampled.drums"))
        #expect(drums.pitchMap == [35:48,36:48,37:50,38:50,39:51,40:50,41:64,42:52,43:63,44:52,45:62,46:53,47:61,48:61,49:58,50:61,51:54,52:60,53:55,55:58,56:55,57:58,59:54])
        #expect(SoundBankCatalog.bank(id: "piano")?.sha256 == "d9f5157720963671906727ca2e12b3293fd822c831bb0de477dd1c5f3ad37108")
    }
}
