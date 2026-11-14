import Foundation
import Combine
import UnabletonCore
import UnabletonLibrary

/// Display-only organization. These values never become instrument IDs or song metadata.
enum SoundFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case pianos, guitarsAndBass, organs, strings, winds, malletsAndPercussion, drums, synthesizers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pianos: "Pianos"
        case .guitarsAndBass: "Guitars & Bass"
        case .organs: "Organs"
        case .strings: "Strings"
        case .winds: "Winds"
        case .malletsAndPercussion: "Mallets & Percussion"
        case .drums: "Drums"
        case .synthesizers: "Synthesizers"
        }
    }
    var symbol: String {
        switch self {
        case .pianos, .organs: "pianokeys"
        case .guitarsAndBass: "guitars"
        case .strings: "music.note"
        case .winds: "wind"
        case .malletsAndPercussion: "music.note.list"
        case .drums: "square.grid.3x3"
        case .synthesizers: "waveform"
        }
    }
}

enum SoundLibraryDestination: Hashable, Sendable {
    case all, onThisMac, downloads, family(SoundFamily)
    var title: String {
        switch self {
        case .all: "All Sounds"
        case .onThisMac: "On This Mac"
        case .downloads: "Downloads"
        case .family(let family): family.title
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .onThisMac: "internaldrive"
        case .downloads: "arrow.down.circle"
        case .family(let family): family.symbol
        }
    }
    var storageKey: String {
        switch self {
        case .all: "all"
        case .onThisMac: "onThisMac"
        case .downloads: "downloads"
        case .family(let family): "family.\(family.rawValue)"
        }
    }
    init(storageKey: String) {
        if storageKey == "onThisMac" { self = .onThisMac }
        else if storageKey == "downloads" { self = .downloads }
        else if storageKey.hasPrefix("family."), let family = SoundFamily(rawValue: String(storageKey.dropFirst(7))) { self = .family(family) }
        else { self = .all }
    }
}

enum SoundLibrarySort: String, CaseIterable, Identifiable, Sendable {
    case name, downloadSize
    var id: String { rawValue }
    var title: String { self == .name ? "Name" : "Download Size" }
}

struct SoundLibraryItem: Identifiable, Sendable {
    let preset: InstrumentPreset
    let family: SoundFamily
    let name: String
    let description: String
    var id: String { preset.id }
    var symbol: String { family.symbol }
    var sourceName: String { preset.name }
    var bank: SoundBank? { preset.soundBankID.flatMap { SoundBankCatalog.bank(id: $0) } }
    var isBuiltIn: Bool { preset.soundBankID == nil }
    var providerID: String { bank?.sourceID ?? "builtin" }
    var providerName: String { Self.providerTitle(providerID) }
    var downloadBytes: Int64 { bank?.downloadBytes ?? 0 }
    var warning: String? {
        guard let unrenderable = preset.unrenderablePitches, !unrenderable.isEmpty else { return nil }
        return "Limited native playback: some drum notes are silent. Only the kick and snare mappings (GM 35–40) passed the playback audit. Existing song notes are preserved."
    }
    static func providerTitle(_ id: String) -> String {
        switch id { case "builtin": "Built-in"; case "freepats": "FreePats"; default: id }
    }
}

struct SoundLibraryDownloadSummary: Sendable {
    let banks: [SoundBank]
    let soundCount: Int
    var downloadCount: Int { banks.count }
    var downloadBytes: Int64 { banks.reduce(0) { $0 + $1.downloadBytes } }
    var installedBytes: Int64 { banks.reduce(0) { $0 + $1.installedBytes } }
}

@MainActor
final class SoundLibraryPresentation: ObservableObject {
    @Published var destination: SoundLibraryDestination = .all
    @Published var search = ""
    @Published var sourceID = "all"
    @Published var sort: SoundLibrarySort = .name
    @Published var selection: String?

    static let items: [SoundLibraryItem] = InstrumentCatalog.presets.map { preset in
        SoundLibraryItem(preset: preset, family: family(for: preset), name: names[preset.id] ?? preset.name,
                         description: descriptions[preset.id] ?? conciseDescription(for: preset))
    }
    static func item(id: String?) -> SoundLibraryItem? { items.first { $0.id == id } }
    static var sourceIDs: [String] { ["all", "builtin"] + Set(SoundBankCatalog.banks.map(\.sourceID)).sorted() }
    static func sharedBankPresets(_ bankID: String) -> [SoundLibraryItem] { items.filter { $0.preset.soundBankID == bankID } }

    func sounds(states: [String: SoundBankState], recentlyCompleted: Set<String> = []) -> [SoundLibraryItem] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return Self.items.filter { item in
            let state = item.preset.soundBankID.flatMap { states[$0] }
            let matchesDestination: Bool
            switch destination {
            case .all: matchesDestination = true
            case .onThisMac: matchesDestination = item.isBuiltIn || state?.isInstalled == true
            case .family(let family): matchesDestination = item.family == family
            case .downloads:
                if case .failed = state { matchesDestination = true }
                else { matchesDestination = state?.isBusy == true || item.preset.soundBankID.map(recentlyCompleted.contains) == true }
            }
            let searchable = [item.name, item.sourceName, item.description, item.preset.description, item.family.title,
                              item.providerName, item.providerID, item.preset.roles.joined(separator: " ")].joined(separator: " ")
            return matchesDestination && (sourceID == "all" || sourceID == item.providerID) &&
                terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }.sorted { first, second in
            if sort == .downloadSize, first.downloadBytes != second.downloadBytes { return first.downloadBytes < second.downloadBytes }
            let order = first.name.localizedStandardCompare(second.name)
            return order == .orderedSame ? first.id < second.id : order == .orderedAscending
        }
    }

    /// Returns true when the caller needs to stop an audition for an invisible selection.
    @discardableResult func reconcileSelection(states: [String: SoundBankState], recentlyCompleted: Set<String> = []) -> Bool {
        guard let selection, !sounds(states: states, recentlyCompleted: recentlyCompleted).contains(where: { $0.id == selection }) else { return false }
        self.selection = nil
        return true
    }
    var hasFilters: Bool { !search.isEmpty || sourceID != "all" }
    func clearFilters() { search = ""; sourceID = "all" }

    static func remainingDownloadSummary(states: [String: SoundBankState]) -> SoundLibraryDownloadSummary {
        let banks = SoundBankCatalog.banks.filter { bank in
            let state = states[bank.id]
            return state?.isInstalled != true && state?.isBusy != true
        }
        let ids = Set(banks.map(\.id))
        return SoundLibraryDownloadSummary(banks: banks, soundCount: items.filter { $0.preset.soundBankID.map(ids.contains) == true }.count)
    }

    /// Every reviewed preset is assigned explicitly; category fallback only supports future providers.
    static let familiesByID: [String: SoundFamily] = {
        let groups: [(SoundFamily, [String])] = [
            (.pianos, ["sampled.piano", "freepats.fm-piano1.0.0", "freepats.fm-piano1.0.1", "freepats.fm-piano1.0.2", "freepats.fm-piano1.0.3", "freepats.fm-piano2", "freepats.ydp-grandpiano", "freepats.salamandergrandpiano", "freepats.pianofb"]),
            (.guitarsAndBass, ["sampled.guitar", "sampled.bass", "freepats.pickedbassyr", "freepats.ukulele", "freepats.fss-steelstringguitar"]),
            (.organs, ["freepats.drawbarorganemulation", "freepats.percussiveorganemulation", "freepats.rockorganemulation", "freepats.churchorganemulation"]),
            (.strings, ["freepats.concertharp"]),
            (.winds, ["freepats.clarinet", "freepats.tenorsaxophone", "freepats.ocarina"]),
            (.malletsAndPercussion, ["sampled.mallets", "freepats.jawharp"]),
            (.drums, ["drums.electronic", "sampled.drums", "freepats.synthesizerpercussion"]),
            (.synthesizers, ["synth.bass", "synth.lead", "synth.pad", "synth.pluck", "synth.strings", "freepats.latelybass", "freepats.synthbass1", "freepats.synthbass2", "freepats.synthbrass1", "freepats.synthbrass2", "freepats.synthgoblins", "freepats.synthsoundtrack", "freepats.synthscifi", "freepats.synthcrystal", "freepats.synthbasslead", "freepats.synthfifths", "freepats.synthsquare", "freepats.synthcalliope", "freepats.synthpadchoir", "freepats.sweeppad", "freepats.newage", "freepats.synthpadbowed", "freepats.synthstrings1", "freepats.synthstrings2"])
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { family, ids in ids.map { ($0, family) } })
    }()
    private static func family(for preset: InstrumentPreset) -> SoundFamily {
        if let family = familiesByID[preset.id] { return family }
        switch preset.category.lowercased() {
        case "pianos": return .pianos
        case "guitars": return .guitarsAndBass
        case "organs": return .organs
        case "strings": return .strings
        case "winds": return .winds
        case "percussion": return .malletsAndPercussion
        case "drums": return .drums
        default: return .synthesizers
        }
    }
    private static let names: [String: String] = [
        "synth.bass": "Bass synth", "synth.lead": "Lead synth", "synth.pad": "Pad synth", "synth.pluck": "Pluck synth",
        "freepats.pickedbassyr": "Picked bass guitar",
        "freepats.fm-piano1.0.0": "FM piano 1", "freepats.fm-piano1.0.1": "FM piano 1 · v60",
        "freepats.fm-piano1.0.2": "FM piano 1 · v80", "freepats.fm-piano1.0.3": "FM piano 1 · v100",
        "freepats.fm-piano2": "FM piano 2", "freepats.jawharp": "Jaw harp",
        "freepats.drawbarorganemulation": "Drawbar organ", "freepats.percussiveorganemulation": "Percussive organ",
        "freepats.rockorganemulation": "Rock organ", "freepats.churchorganemulation": "Church organ",
        "freepats.synthesizerpercussion": "Synth percussion", "freepats.ydp-grandpiano": "YDP grand piano",
        "freepats.salamandergrandpiano": "Salamander grand piano", "freepats.pianofb": "Old piano FB",
        "freepats.tenorsaxophone": "Tenor saxophone", "freepats.latelybass": "Lately bass",
        "freepats.synthbass1": "Synth bass 1", "freepats.synthbass2": "Synth bass 2",
        "freepats.synthbrass1": "Synth brass 1", "freepats.synthbrass2": "Synth brass 2",
        "freepats.synthgoblins": "Goblins", "freepats.synthsoundtrack": "Soundtrack", "freepats.synthscifi": "Sci-fi",
        "freepats.synthcrystal": "Crystal", "freepats.synthbasslead": "Bass & lead", "freepats.synthfifths": "Fifths lead",
        "freepats.synthsquare": "Square lead", "freepats.synthcalliope": "Calliope lead", "freepats.synthpadchoir": "Choir pad",
        "freepats.sweeppad": "Sweep pad", "freepats.newage": "New age", "freepats.synthpadbowed": "Bowed pad",
        "freepats.synthstrings1": "Synth strings 1", "freepats.synthstrings2": "Synth strings 2",
        "freepats.fss-steelstringguitar": "Steel-string guitar", "freepats.concertharp": "Concert harp"
    ]
    private static let descriptions: [String: String] = [
        "synth.bass": "Modulated bass with filter movement and drive.",
        "synth.lead": "Bright lead for melodies and countermelodies.",
        "synth.pad": "Slow attack and sustained harmony.",
        "synth.pluck": "Short plucked notes for melodies and arpeggios.",
        "synth.strings": "Sustained, detuned synthetic strings.",
        "drums.electronic": "Electronic kick, snare, and hi-hats.",
        "sampled.piano": "Sampled upright piano with two velocity layers.",
        "sampled.guitar": "Nylon-string classical guitar.",
        "sampled.bass": "Finger-played electric bass guitar.",
        "sampled.mallets": "Xylophone played with medium mallets.",
        "sampled.drums": "Acoustic kit with limited native note support.",
        "freepats.pickedbassyr": "Electric bass guitar played with a pick.",
        "freepats.fm-piano1.0.0": "FM piano for melodies, chords, and accompaniment.",
        "freepats.fm-piano1.0.1": "FM piano for melodies, chords, and accompaniment.",
        "freepats.fm-piano1.0.2": "FM piano for melodies, chords, and accompaniment.",
        "freepats.fm-piano1.0.3": "FM piano for melodies, chords, and accompaniment.",
        "freepats.fm-piano2": "FM piano for melodic and harmonic parts.",
        "freepats.jawharp": "Jaw harp for melodies and percussion.",
        "freepats.ukulele": "Ukulele for melodies and accompaniment.",
        "freepats.drawbarorganemulation": "Drawbar organ for chords and lead lines.",
        "freepats.percussiveorganemulation": "Percussive organ for melodic and harmonic parts.",
        "freepats.rockorganemulation": "Rock organ for melodies and accompaniment.",
        "freepats.churchorganemulation": "Church organ for melodies and chords.",
        "freepats.synthesizerpercussion": "Synth kick, snare, hi-hats, toms, and percussion.",
        "freepats.ydp-grandpiano": "Grand piano for melodies, chords, and accompaniment.",
        "freepats.salamandergrandpiano": "Grand piano for melodic and harmonic parts.",
        "freepats.pianofb": "Piano for melodies and accompaniment.",
        "freepats.clarinet": "Clarinet for melodies and countermelodies.",
        "freepats.tenorsaxophone": "Tenor saxophone for lead and supporting melodies.",
        "freepats.latelybass": "Synth bass for basslines.",
        "freepats.synthbass1": "Synth bass for low-register parts.",
        "freepats.synthbass2": "Synth bass for basslines and low-register parts.",
        "freepats.synthbrass1": "Synth brass for melodies and countermelodies.",
        "freepats.synthbrass2": "Synth brass for lead and supporting melodies.",
        "freepats.synthgoblins": "Goblins-style synth for harmony and texture.",
        "freepats.synthsoundtrack": "Soundtrack-style synth for harmonic layers.",
        "freepats.synthscifi": "Sci-fi synth for harmony and texture.",
        "freepats.synthcrystal": "Crystal-style synth for harmony and texture.",
        "freepats.synthbasslead": "Bass-and-lead synth for melodic parts.",
        "freepats.synthfifths": "Fifths synth for melodies and countermelodies.",
        "freepats.synthsquare": "Square lead for melodies and countermelodies.",
        "freepats.synthcalliope": "Calliope-style synth for lead lines.",
        "freepats.synthpadchoir": "Choir-style synth pad for harmony and texture.",
        "freepats.sweeppad": "Sweep pad for harmonic layers and texture.",
        "freepats.newage": "New age synth for harmony and texture.",
        "freepats.synthpadbowed": "Bowed-style synth pad for harmonic layers.",
        "freepats.synthstrings1": "Synth strings for harmony and texture.",
        "freepats.synthstrings2": "Synth strings for harmonic layers.",
        "freepats.ocarina": "Ocarina for melodies and countermelodies.",
        "freepats.fss-steelstringguitar": "Steel-string acoustic guitar for melodies and accompaniment.",
        "freepats.concertharp": "Concert harp for melodies, chords, and accompaniment."
    ]
    private static func conciseDescription(for preset: InstrumentPreset) -> String {
        let description = preset.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty && description != preset.name && description.count <= 150 { return description }
        let roles = preset.roles.map { $0 == "countermelody" ? "countermelodies" : $0 }.joined(separator: ", ")
        return roles.isEmpty ? "Sampled instrument from FreePats." : "FreePats sound for \(roles)."
    }
}
