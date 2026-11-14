import SwiftUI
import UnabletonCore
import UnabletonLibrary

struct SoundLibraryDownloadsView: View {
    @ObservedObject var store: SoundLibraryStore
    var search = ""
    var sourceID = "all"
    var clearFilters: (() -> Void)? = nil
    var reveal: (String) -> Void

    private var allActive: [SoundBank] { banks { $0.isBusy } }
    private var allFailed: [SoundBank] { banks { if case .failed = $0 { true } else { false } } }
    private var allCompleted: [SoundBank] {
        store.recentlyCompletedBankIDs.compactMap { id in
            guard store.states[id]?.isInstalled == true else { return nil }
            return SoundBankCatalog.bank(id: id)
        }
    }
    private var matchingSounds: [SoundLibraryItem] {
        let filters = SoundLibraryPresentation()
        filters.search = search; filters.sourceID = sourceID
        return filters.sounds(states: store.states)
    }
    private var matchingBankIDs: Set<String> { Set(matchingSounds.compactMap { $0.preset.soundBankID }) }
    private func filtered(_ banks: [SoundBank]) -> [SoundBank] {
        let matches = matchingBankIDs
        return banks.filter { matches.contains($0.id) }
    }
    private func banks(where matches: (SoundBankState) -> Bool) -> [SoundBank] {
        SoundBankCatalog.banks.filter { matches(store.states[$0.id] ?? .notInstalled) }
            .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }

    var body: some View {
        let active = filtered(allActive), failed = filtered(allFailed), completed = filtered(allCompleted)
        if allActive.isEmpty && allFailed.isEmpty && allCompleted.isEmpty {
            ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                   description: Text("Download sounds from the library to use them offline in all your songs. Progress and recent downloads appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if active.isEmpty && failed.isEmpty && completed.isEmpty {
            ContentUnavailableView {
                Label("No Downloads Found", systemImage: "magnifyingglass")
            } description: {
                Text("No current or recent downloads match this search and source. Try another search or clear your filters.")
            } actions: {
                if let clearFilters { Button("Clear Filters", action: clearFilters) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !active.isEmpty { section("In Progress", banks: active) }
                    if !failed.isEmpty { section("Needs Attention", banks: failed) }
                    if !completed.isEmpty { section("Completed This Session", banks: completed) }
                }
                .padding(24)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Sound downloads")
        }
    }

    private func section(_ title: String, banks: [SoundBank]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text("\(banks.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(banks) { bank in
                row(bank)
                if bank.id != banks.last?.id { Divider() }
            }
        }
    }

    private func row(_ bank: SoundBank) -> some View {
        let sounds = SoundLibraryPresentation.sharedBankPresets(bank.id)
        let state = store.states[bank.id] ?? .notInstalled
        let activity = store.activities[bank.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sounds.first?.symbol ?? "music.note")
                    .font(.title3).foregroundStyle(.secondary).frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(bank)).font(.headline)
                    Text(sounds.count > 1 ? "Includes \(sounds.count) sounds · \(bytes(bank.downloadBytes)) download" : "\(SoundLibraryItem.providerTitle(bank.sourceID)) · \(bytes(bank.downloadBytes)) download")
                        .font(.caption).foregroundStyle(.secondary)
                    if sounds.count > 1 {
                        Text(sounds.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let first = sounds.first(where: { candidate in matchingSounds.contains { $0.id == candidate.id } }) ?? sounds.first {
                    Button("Show Sound") { reveal(first.id) }
                        .controlSize(.small)
                        .accessibilityLabel("Show \(title(bank)) in the sound library")
                }
            }
            switch state {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(1, total)))
                    .accessibilityLabel("Downloading \(title(bank))")
                Text("\(bytes(received)) of \(bytes(total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            case .queued:
                Label("Queued", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
            case .verifying:
                phaseProgress("Verifying download…")
            case .installing:
                phaseProgress("Installing…")
            case .installed:
                Label("Ready to use offline", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            case .failed(let message):
                Label("Download failed", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                Text(message).font(.callout).textSelection(.enabled)
                Button("Retry Download") { store.download(bank.id) }
                    .accessibilityLabel("Retry downloading \(title(bank))")
            case .notInstalled:
                Text("Not downloaded").font(.callout).foregroundStyle(.secondary)
            }
            if state.isBusy {
                if activity?.libraryRequested == true {
                    Button(activity?.requiredByOtherOperations == true ? "Cancel Library Request" : "Cancel Download") { store.cancel(bank.id) }
                        .controlSize(.small)
                        .accessibilityLabel("Cancel the library's download request for \(title(bank))")
                }
                if activity?.requiredByOtherOperations == true {
                    Text(activity?.libraryRequested == true
                         ? "Another operation also needs this sound. Canceling the library request lets that download continue."
                         : "Required by another operation. The download continues while that operation needs it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private func phaseProgress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
    private func title(_ bank: SoundBank) -> String {
        SoundLibraryPresentation.sharedBankPresets(bank.id).first?.name ?? bank.fileName
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
