import SwiftUI
import UnabletonCore

struct TranscriptionLayersView: View {
    @ObservedObject var store: TranscriptionSession
    @ObservedObject private var library = SoundLibraryStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Stepper("Performance layers: \(store.performanceLayerCount)", value: Binding(get: { store.performanceLayerCount }, set: { store.setPerformanceLayerCount($0) }), in: 1...max(1, store.availableTracks - store.options.layers.filter { $0.role != .performance }.count))
                Text("Performance layers play the detected notes. Extra musical parts are added only when you choose an AI layer below.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($store.options.layers) { $layer in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Layer name", text: $layer.name).textFieldStyle(.roundedBorder)
                            Text(layer.role.displayName + (layer.role == .performance ? "" : " · AI")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Picker("Instrument for \(layer.name)", selection: $layer.instrumentID) {
                            ForEach(presets(for: layer)) { Text($0.name + (library.isInstalled($0) ? "" : " — Download")).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 170)
                        Button { store.removeLayer(layer.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(layer.name)")
                            .disabled(layer.role == .performance && store.performanceLayerCount == 1)
                    }
                }
                Menu {
                    ForEach(TranscriptionLayerRole.allCases, id: \.self) { role in
                        Button(role.displayName + (role == .performance ? "" : " (AI)")) { store.addLayer(role) }
                    }
                } label: { Label("Add Layer", systemImage: "plus") }.disabled(store.options.layers.count >= store.availableTracks)
                Text("\(store.options.layers.count) tracks selected · \(store.availableTracks) slots available in this song")
                    .font(.caption2).foregroundStyle(.secondary)
                if store.effectiveOptions.requiresAI {
                    TextField("Optional arrangement instructions", text: $store.options.instructions, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(store.isWorking || store.isCapturing)
    }
    private func presets(for layer: TranscriptionLayer) -> [InstrumentPreset] {
        let drums = layer.role == .drums || (layer.role == .performance && store.mode == .beatboxing)
        return InstrumentCatalog.presets.filter { preset in
            guard (preset.category == "Drums") == drums else { return false }
            guard layer.role == .performance, let events = store.transcript?.events else { return true }
            return events.allSatisfy { (preset.minimumPitch...preset.maximumPitch).contains($0.pitch) && preset.supportedPitches?.contains($0.pitch) != false && preset.unrenderablePitches?.contains($0.pitch) != true }
        }
    }
}
