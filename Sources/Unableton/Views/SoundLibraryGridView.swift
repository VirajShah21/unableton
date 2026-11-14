import SwiftUI
import UnabletonLibrary

struct SoundLibraryGridView: View {
    let items: [SoundLibraryItem]
    @Binding var selection: String?
    @ObservedObject var store: SoundLibraryStore
    @ObservedObject var audition: SoundAuditionController
    let clearFilters: () -> Void
    @FocusState private var gridFocused: Bool
    @State private var columns = 2

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("No Sounds Found", systemImage: "magnifyingglass")
            } description: {
                Text("Try another search or source. Built-in sounds are always available on this Mac.")
            } actions: { Button("Clear Filters", action: clearFilters) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 270), spacing: 14)], spacing: 14) {
                        ForEach(items) { item in
                            SoundLibraryTile(item: item, selected: selection == item.id,
                                             keyboardFocused: gridFocused && selection == item.id,
                                             store: store, audition: audition) {
                                selection = item.id; gridFocused = true
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24).padding(.top, 2)
                }
                .onGeometryChange(for: Int.self) { geometry in max(1, Int((geometry.size.width - 26) / 190)) } action: { columns = $0 }
                .focusable().focused($gridFocused).focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(-1, proxy: proxy) }
                .onKeyPress(.rightArrow) { move(1, proxy: proxy) }
                .onKeyPress(.upArrow) { move(-columns, proxy: proxy) }
                .onKeyPress(.downArrow) { move(columns, proxy: proxy) }
                .onKeyPress(.space) {
                    guard let item = items.first(where: { $0.id == selection }), store.isInstalled(item.preset) else { return .ignored }
                    audition.preview(item.preset); return .handled
                }
                .onKeyPress(.escape) {
                    guard audition.phase != .idle else { return .ignored }
                    audition.stop(); return .handled
                }
                .onChange(of: selection) { _, value in
                    if let value { proxy.scrollTo(value, anchor: .center) }
                }
                .accessibilityLabel("Sound browser")
            }
        }
    }

    private func move(_ delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let index = selection.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        let destination = index.map { min(items.count - 1, max(0, $0 + delta)) } ?? 0
        selection = items[destination].id; proxy.scrollTo(items[destination].id, anchor: .center)
        return .handled
    }
}

private struct SoundLibraryTile: View {
    let item: SoundLibraryItem
    let selected: Bool
    let keyboardFocused: Bool
    @ObservedObject var store: SoundLibraryStore
    @ObservedObject var audition: SoundAuditionController
    let select: () -> Void
    @State private var hovered = false
    private var installed: Bool { store.isInstalled(item.preset) }
    private var state: SoundBankState? { store.state(for: item.preset) }
    private var active: Bool { audition.isActive(for: item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: item.symbol).font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.tint).frame(height: 32)
                        Spacer()
                        if item.warning != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Limited native playback. See sound details.") }
                    }
                    Text(item.name).font(.headline).lineLimit(2).frame(height: 34, alignment: .topLeading)
                    Text(item.description).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).frame(height: 30, alignment: .topLeading)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.name)
            .accessibilityValue(selected ? "Selected, \(availability)" : availability)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            HStack(spacing: 4) {
                Text(availability).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if installed {
                    Button {
                        select(); audition.preview(item.preset)
                    } label: { Image(systemName: active ? "stop.fill" : "play.fill").frame(width: 16, height: 16) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(audition.unavailableReason != nil && !active)
                    .accessibilityLabel("\(active ? "Stop preview of" : "Preview") \(item.name)")
                    .help(audition.unavailableReason ?? (active ? "Stop preview" : "Preview sound (Space)"))
                } else if let bank = item.bank, state?.isBusy != true {
                    Button { select(); store.download(bank.id) } label: { Image(systemName: "arrow.down").frame(width: 16, height: 16) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Download \(item.name), \(soundBytes(bank.downloadBytes))")
                        .help("Download \(soundBytes(bank.downloadBytes))")
                }
            }
            if case .downloading(let received, let total) = state {
                ProgressView(value: Double(received), total: Double(max(1, total))).controlSize(.small)
                    .accessibilityLabel("Downloading \(item.name)")
            } else if state?.isBusy == true {
                ProgressView().controlSize(.mini).frame(height: 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(hovered ? 0.065 : 0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(keyboardFocused ? Color.accentColor : selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: keyboardFocused ? 2.5 : 1))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var availability: String {
        if item.isBuiltIn { return "Built-in" }
        if installed { return "Downloaded" }
        if let state, state.isBusy { return state.title }
        if case .failed = state { return "Download failed" }
        return soundBytes(item.downloadBytes)
    }
}
