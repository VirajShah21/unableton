import SwiftUI
import UnabletonCore
import UnabletonLibrary

struct SoundLibraryImportResultView: View {
    @ObservedObject var store: SoundLibraryStore
    var reveal: (String) -> Void

    private var report: SoundImportReport { store.importReport ?? .init(importedBankIDs: [], failures: []) }
    private var importedSounds: [SoundLibraryItem] {
        let bankIDs = Set(report.importedBankIDs)
        return SoundLibraryPresentation.items.filter { $0.preset.soundBankID.map(bankIDs.contains) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import Results").font(.title2).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            Text(summary).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !report.importedBankIDs.isEmpty { availableSection }
                    if !report.failures.isEmpty { failuresSection }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            Text("Original files stay in place. Exact matching sounds that were already installed are included as available.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let first = importedSounds.first {
                    Button("View Imported Sounds") {
                        store.importReport = nil
                        reveal(first.id)
                    }
                }
                Spacer()
                Button("Done") { store.importReport = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        let sounds = importedSounds.count
        let failures = report.failures.count
        let available = sounds == 1 ? "1 sound is available on this Mac." : "\(sounds) sounds are available on this Mac."
        guard failures > 0 else { return available }
        return available + (failures == 1 ? " 1 file could not be imported." : " \(failures) files could not be imported.")
    }

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(report.importedBankIDs, id: \.self) { id in
                let sounds = SoundLibraryPresentation.sharedBankPresets(id)
                if let first = sounds.first {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(first.name).fontWeight(.medium)
                            if sounds.count > 1 {
                                Text("Includes \(sounds.count) sounds: \(sounds.map(\.name).joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reveal") {
                            store.importReport = nil
                            reveal(first.id)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Reveal \(first.name) in the sound library")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private var failuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Could Not Import").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.fileName).fontWeight(.medium).textSelection(.enabled)
                        Text(failure.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
