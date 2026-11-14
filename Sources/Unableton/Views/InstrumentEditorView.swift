import SwiftUI
import UnabletonCore

struct InstrumentEditorView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject private var library = SoundLibraryStore.shared
    @Environment(\.openWindow) private var openWindow
    let effectsOnly: Bool
    private let effects = ["drive", "reverb", "delay"]
    var body: some View {
        if let track = session.selectedTrack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(track.name).font(.title3)
                        Spacer()
                        if track.kind == .instrument {
                            Text(SoundLibraryPresentation.item(id: track.instrumentID)?.name ?? track.instrumentID)
                                .foregroundStyle(.secondary).textSelection(.enabled)
                            if !effectsOnly && session.canEditMusic {
                                Button("Choose Sound…") {
                                    SoundLibraryNavigation.shared.reveal(track.instrumentID, from: session)
                                    openWindow(id: "sound-library")
                                }.help("Choose an instrument in Sound Library")
                            }
                        }
                    }
                    if track.kind == .instrument, let preset = InstrumentCatalog.preset(id: track.instrumentID), !library.isInstalled(preset) {
                        HStack {
                            Text("This sound is not installed.").foregroundStyle(.secondary)
                            Button("Sound Library…") {
                                SoundLibraryNavigation.shared.reveal(preset.id, from: session)
                                openWindow(id: "sound-library")
                            }
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 24)], alignment: .leading, spacing: 18) {
                        if session.canEditMusic {
                            ParameterControl(name: "Volume", value: track.volume, range: 0...1.5, step: 0.01, unit: "") { session.parameter("volume", value: $0, track: track) }
                            ParameterControl(name: "Pan", value: track.pan, range: -1...1, step: 0.01, unit: "") { session.parameter("pan", value: $0, track: track) }
                        } else {
                            InstrumentParameterReadout(name: "Volume", value: track.volume * 100, unit: "%")
                            InstrumentParameterReadout(name: "Pan", text: panDescription(track.pan))
                        }
                        if track.kind == .instrument {
                            ForEach(InstrumentCatalog.parameters(for: track.instrumentID).filter { effectsOnly ? effects.contains($0.id) : !effects.contains($0.id) }) { descriptor in
                                if !session.canEditMusic {
                                    InstrumentParameterReadout(descriptor: descriptor, value: track.effectiveParameters[descriptor.id] ?? descriptor.defaultValue)
                                } else if descriptor.id == "oscillator" {
                                    VStack(alignment: .leading) {
                                        Text("Waveform").font(.caption).foregroundStyle(.secondary)
                                        Picker("Waveform", selection: Binding(get: { Int(track.effectiveParameters[descriptor.id] ?? descriptor.defaultValue) }, set: { session.parameter(descriptor.id, value: Double($0), track: track) })) {
                                            Text("Sine").tag(0); Text("Saw").tag(1); Text("Square").tag(2); Text("Triangle").tag(3)
                                        }.labelsHidden()
                                    }
                                } else {
                                    ParameterControl(name: descriptor.name, value: track.effectiveParameters[descriptor.id] ?? descriptor.defaultValue, range: descriptor.range, step: descriptor.step, unit: descriptor.unit) {
                                        session.parameter(descriptor.id, value: $0, track: track)
                                    }
                                }
                            }
                        }
                    }
                    if !session.canEditMusic {
                        HStack(spacing: 16) {
                            Text("Mute: \(track.isMuted ? "On" : "Off")")
                            Text("Solo: \(track.isSolo ? "On" : "Off")")
                            Text("Record arm: \(track.isArmed ? "On" : "Off")")
                        }
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Mute \(track.isMuted ? "on" : "off"), solo \(track.isSolo ? "on" : "off"), record arm \(track.isArmed ? "on" : "off")")
                    }
                    if let warning = InstrumentCatalog.preset(id: track.instrumentID), warning.unrenderablePitches != nil { Text(warning.description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if track.kind == .audio { Text(session.canEditMusic ? "Audio tracks support volume and pan. Imported vocals and recordings remain editable audio clips." : "Audio tracks support volume and pan. Imported vocals and recordings retain their original audio.").font(.caption).foregroundStyle(.secondary) }
                    if track.instrumentID.contains("drums") { Text("Drum notes: C1 kick · D1 snare · F♯1 closed hi-hat · A♯1 open hi-hat · C♯2 crash").font(.caption).foregroundStyle(.secondary) }
                }.padding(18)
            }
        } else { ContentUnavailableView("Select a track", systemImage: "slider.horizontal.3", description: Text(session.canEditMusic ? "Select a track to adjust its instrument and mix." : "Select a track to inspect its instrument, effects, and mix.")) }
    }
    private func panDescription(_ value: Double) -> String {
        abs(value) < 0.005 ? "Center" : "\(value < 0 ? "L" : "R") \((abs(value) * 100).formatted(.number.precision(.fractionLength(0...1))))%"
    }
}

struct InstrumentParameterReadout: View {
    let name: String
    private let formattedValue: String

    init(name: String, value: Double, unit: String = "") {
        self.name = name
        formattedValue = value.formatted(.number.precision(.fractionLength(0...3))) + (unit.isEmpty ? "" : " " + unit)
    }
    init(name: String, text: String) {
        self.name = name; formattedValue = text
    }
    init(descriptor: ParameterDescriptor, value: Double) {
        name = descriptor.name
        if descriptor.id == "oscillator" {
            formattedValue = ["Sine", "Saw", "Square", "Triangle"][min(3, max(0, Int(value)))]
        } else {
            formattedValue = value.formatted(.number.precision(.fractionLength(0...3))) + (descriptor.unit.isEmpty ? "" : " " + descriptor.unit)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(formattedValue).font(.system(.callout, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(formattedValue)
    }
}

struct ParameterControl: View {
    let name: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let commit: (Double) -> Void
    @State private var local: Double = 0
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(local.formatted(.number.precision(.fractionLength(0...2))))\(unit.isEmpty ? "" : " \(unit)")").font(.caption).monospacedDigit()
            }
            Slider(value: $local, in: range, step: step) { changing in
                editing = changing
                if !changing { commit(local) }
            }.accessibilityLabel(name).accessibilityValue(local.formatted())
        }
        .onAppear { local = min(range.upperBound, max(range.lowerBound, value)) }
        .onChange(of: value) { _, next in if !editing { local = min(range.upperBound, max(range.lowerBound, next)) } }
    }
}
