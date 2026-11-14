import Foundation

public struct ParameterDescriptor: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let minimum: Double
    public let maximum: Double
    public let defaultValue: Double
    public let unit: String
    public let step: Double
    public var range: ClosedRange<Double> { minimum...maximum }
    public init(_ id: String, _ name: String, _ minimum: Double, _ maximum: Double, _ defaultValue: Double, _ unit: String = "", step: Double = 0.01) {
        self.id = id; self.name = name; self.minimum = minimum; self.maximum = maximum; self.defaultValue = defaultValue; self.unit = unit; self.step = step
    }
}
public struct InstrumentPreset: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let category: String
    public let symbol: String
    public let soundFontFileName: String?
    public let defaults: [String: Double]
    public let minimumPitch: Int
    public let maximumPitch: Int
    public let supportedPitches: [Int]?
    public let soundBankID: String?
    public let program: UInt8
    public let bank: UInt16
    public let pitchMap: [Int: Int]?
    public let description: String
    public let roles: [String]
    public let gmProgram: UInt8?
    public let unrenderablePitches: [Int]?
    public var isSampler: Bool { soundBankID != nil || soundFontFileName != nil }
    public init(_ id: String, _ name: String, _ category: String, _ symbol: String, soundFont: String? = nil, defaults: [String: Double] = [:], minimumPitch: Int = 0, maximumPitch: Int = 127, supportedPitches: [Int]? = nil, soundBankID: String? = nil, program: UInt8 = 0, bank: UInt16 = 0, pitchMap: [Int: Int]? = nil, description: String = "", roles: [String] = [], gmProgram: UInt8? = nil, unrenderablePitches: [Int]? = nil) {
        self.id = id; self.name = name; self.category = category; self.symbol = symbol; self.soundFontFileName = soundFont; self.defaults = defaults
        self.minimumPitch = minimumPitch; self.maximumPitch = maximumPitch; self.supportedPitches = supportedPitches
        self.soundBankID = soundBankID; self.program = program; self.bank = bank; self.pitchMap = pitchMap
        self.description = description; self.roles = roles; self.gmProgram = gmProgram; self.unrenderablePitches = unrenderablePitches
    }
}
public enum InstrumentCatalog {
    public static let parameterDescriptors: [ParameterDescriptor] = [
        .init("oscillator", "Waveform", 0, 3, 1, "0 sine · 1 saw · 2 square · 3 triangle", step: 1),
        .init("attack", "Attack", 0.001, 2, 0.01, "s", step: 0.001),
        .init("decay", "Decay", 0.01, 3, 0.2, "s"),
        .init("sustain", "Sustain", 0, 1, 0.65),
        .init("release", "Release", 0.01, 6, 0.3, "s"),
        .init("cutoff", "Filter cutoff", 40, 20_000, 6000, "Hz", step: 10),
        .init("resonance", "Resonance", 0.05, 0.95, 0.15),
        .init("detune", "Detune", 0, 40, 7, "cents", step: 0.1),
        .init("lfoRate", "LFO rate", 0.125, 16, 1, "cycles/beat", step: 0.125),
        .init("lfoDepth", "LFO depth", 0, 1, 0),
        .init("drive", "Drive", 0, 1, 0.05),
        .init("reverb", "Reverb", 0, 1, 0.12),
        .init("delay", "Delay", 0, 1, 0)
    ]
    public static let presets: [InstrumentPreset] = [
        .init("synth.bass", "Bass", "Synthesizers", "waveform", defaults: ["oscillator": 1, "cutoff": 450, "lfoDepth": 0.55, "lfoRate": 1, "drive": 0.35, "sustain": 0.8, "release": 0.12, "reverb": 0], description: "Procedural bass synth with filter modulation and drive.", roles: ["bass"]),
        .init("synth.lead", "Lead", "Synthesizers", "waveform", defaults: ["cutoff": 6500, "detune": 9], description: "Bright procedural lead synthesizer.", roles: ["melody", "countermelody"]),
        .init("synth.pad", "Pad", "Synthesizers", "waveform", defaults: ["attack": 0.7, "release": 2.2, "cutoff": 2500, "detune": 14, "reverb": 0.3], description: "Slow-attack sustained procedural pad.", roles: ["harmony", "texture"]),
        .init("synth.pluck", "Pluck", "Synthesizers", "waveform", defaults: ["attack": 0.002, "decay": 0.2, "sustain": 0.05, "release": 0.18, "cutoff": 4000, "delay": 0.15], description: "Short, plucked procedural synthesizer.", roles: ["melody", "arpeggio", "accompaniment"]),
        .init("synth.strings", "Synth strings", "Synthesizers", "waveform", defaults: ["attack": 0.3, "release": 1, "detune": 18, "cutoff": 3500, "reverb": 0.25], description: "Sustained detuned synthetic strings.", roles: ["harmony", "melody", "texture"]),
        .init("drums.electronic", "Electronic drums", "Drums", "drum", defaults: ["reverb": 0.04], description: "Procedural electronic kick, snare and hi-hat sounds using General MIDI percussion notes.", roles: ["drums"]),
        .init("sampled.piano", "Upright piano", "Acoustic", "pianokeys", soundFont: "piano.sf2", minimumPitch: 21, maximumPitch: 108, soundBankID: "piano", description: "Warm sampled upright piano, with two velocity layers.", roles: ["melody", "harmony", "accompaniment"]),
        .init("sampled.guitar", "Classical guitar", "Acoustic", "guitars", soundFont: "guitar.sf2", minimumPitch: 29, maximumPitch: 88, soundBankID: "guitar", description: "Nylon-string classical guitar.", roles: ["melody", "accompaniment"]),
        .init("sampled.bass", "Bass guitar", "Acoustic", "guitars", soundFont: "bass.sf2", minimumPitch: 26, maximumPitch: 45, soundBankID: "bass", description: "Finger-played electric bass guitar.", roles: ["bass"]),
        .init("sampled.mallets", "Xylophone", "Acoustic", "pianokeys", soundFont: "mallets.sf2", minimumPitch: 46, maximumPitch: 99, soundBankID: "mallets", description: "Xylophone played with medium mallets.", roles: ["melody", "percussion"]),
        .init("sampled.drums", "Acoustic drums", "Drums", "drum", soundFont: "drums.sf2", minimumPitch: 35, maximumPitch: 59, supportedPitches: [35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,55,56,57,59], soundBankID: "drums", pitchMap: [35:48,36:48,37:50,38:50,39:51,40:50,41:64,42:52,43:63,44:52,45:62,46:53,47:61,48:61,49:58,50:61,51:54,52:60,53:55,55:58,56:55,57:58,59:54], description: "Legacy Muldjord acoustic drum kit. Project notes use General MIDI percussion mapping. Compatibility warning: the native sampler currently renders mapped GM notes 41–53, 55–57 and 59 silently; only the kick/snare mappings 35–40 passed the native audit. Existing IDs, ranges and mappings are retained for project compatibility.", roles: ["drums"], unrenderablePitches: [41,42,43,44,45,46,47,48,49,50,51,52,53,55,56,57,59])
    ] + SoundBankCatalog.additionalPresets
    public static func preset(id: String) -> InstrumentPreset? { presets.first { $0.id == id } }
    public static func defaults(for id: String) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: parameterDescriptors.map { ($0.id, $0.defaultValue) }).merging(preset(id: id)?.defaults ?? [:]) { _, new in new }
    }
    public static func parameters(for id: String) -> [ParameterDescriptor] {
        preset(id: id)?.isSampler == true ? parameterDescriptors.filter { ["cutoff", "reverb", "delay", "drive"].contains($0.id) } : parameterDescriptors
    }
}
extension Track {
    public var effectiveParameters: [String: Double] { InstrumentCatalog.defaults(for: instrumentID).merging(parameters) { _, new in new } }
}
