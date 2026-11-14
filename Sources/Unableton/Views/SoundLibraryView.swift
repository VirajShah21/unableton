import SwiftUI
import UnabletonCore
import UnabletonLibrary

struct SoundLibraryView: View {
    @ObservedObject private var store = SoundLibraryStore.shared
    @ObservedObject private var navigation = SoundLibraryNavigation.shared
    @ObservedObject private var audition = SoundAuditionController.shared
    @StateObject private var presentation = SoundLibraryPresentation()
    @SceneStorage("soundLibrary.destination") private var restoredDestination = "all"
    @SceneStorage("soundLibrary.search") private var restoredSearch = ""
    @SceneStorage("soundLibrary.source") private var restoredSource = "all"
    @SceneStorage("soundLibrary.sort") private var restoredSort = "name"
    @SceneStorage("soundLibrary.inspector") private var showingInspector = true
    @State private var restored = false
    @State private var confirmingAll = false
    @State private var removing: SoundBank?
    @FocusState private var searchFocused: Bool
    private var sounds: [SoundLibraryItem] { presentation.sounds(states: store.states, recentlyCompleted: Set(store.recentlyCompletedBankIDs)) }
    private var selected: SoundLibraryItem? { SoundLibraryPresentation.item(id: presentation.selection ?? "") }

    private var layout: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                browserHeader
                if presentation.destination == .downloads {
                    SoundLibraryDownloadsView(store: store, search: presentation.search, sourceID: presentation.sourceID,
                                              clearFilters: { presentation.clearFilters() }) { reveal($0) }
                } else {
                    SoundLibraryGridView(items: sounds, selection: $presentation.selection, store: store, audition: audition,
                                         clearFilters: { presentation.clearFilters() })
                }
            }
            .backgroundExtensionEffect()
            .inspector(isPresented: Binding(get: { showingInspector && selected != nil }, set: { showingInspector = $0 })) {
                if let selected {
                    SoundLibraryDetailView(item: selected, store: store, audition: audition,
                                           request: navigation.request, remove: { removing = $0 })
                } else {
                    ContentUnavailableView("Choose a Sound", systemImage: "pianokeys",
                                           description: Text("Select a sound to preview it and see its details."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
        }
        .searchable(text: $presentation.search, placement: .toolbar, prompt: "Search sounds, instruments, and roles")
        .searchFocused($searchFocused)
        .toolbar { libraryToolbar }
        .background {
            Button("Search Sounds") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true)
        }
    }

    private var observedContent: some View {
        layout
        .onAppear { restore(); applyRequest() }
        .onDisappear { audition.stop(); navigation.request?.cancel() }
        .onChange(of: navigation.request?.id) { _, _ in applyRequest() }
        .onChange(of: presentation.destination) { _, value in restoredDestination = value.storageKey; reconcile() }
        .onChange(of: presentation.search) { _, value in restoredSearch = value; reconcile() }
        .onChange(of: presentation.sourceID) { _, value in restoredSource = value; reconcile() }
        .onChange(of: presentation.sort) { _, value in restoredSort = value.rawValue }
        // Byte-progress updates change tile meters, not result membership.
        .onChange(of: sounds.map(\.id)) { _, _ in reconcile() }
        .onChange(of: presentation.selection) { _, value in
            if audition.instrumentID != value { audition.stop() }
            if value != nil { showingInspector = true }
        }
        .onExitCommand {
            if audition.phase != .idle { audition.stop() }
            else if searchFocused { presentation.search = ""; searchFocused = false }
        }
    }

    var body: some View {
        observedContent
        .confirmationDialog("Download the entire library?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Download Entire Library") {
                for bank in SoundLibraryPresentation.remainingDownloadSummary(states: store.states).banks { store.download(bank.id) }
                presentation.destination = .downloads
            }
        } message: {
            let summary = SoundLibraryPresentation.remainingDownloadSummary(states: store.states)
            Text("\(summary.soundCount) sounds in \(summary.downloadCount) new downloads. \(soundBytes(summary.downloadBytes)) to download; \(soundBytes(summary.installedBytes)) additional disk space. This includes every category, regardless of your filters. Installed and already queued downloads are excluded.")
        }
        .confirmationDialog("Remove this download?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let removing { Button("Remove Download", role: .destructive) { store.remove(removing); self.removing = nil } }
        } message: {
            let names = removing.map { SoundLibraryPresentation.sharedBankPresets($0.id).map(\.name).joined(separator: ", ") } ?? ""
            Text("This removes \(names) from this Mac. Songs keep their notes, but will need this download to play these sounds again.")
        }
        .sheet(isPresented: Binding(get: { store.importReport != nil }, set: { if !$0 { store.importReport = nil } })) {
            SoundLibraryImportResultView(store: store) { id in store.importReport = nil; reveal(id) }
        }
        .alert("Sound Library", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .frame(minWidth: 880, minHeight: 560)
    }

    private var sidebar: some View {
        List(selection: Binding<SoundLibraryDestination?>(get: { presentation.destination }, set: { if let value = $0 { presentation.destination = value } })) {
            Section("Library") {
                Label("All Sounds", systemImage: "square.grid.2x2").tag(SoundLibraryDestination.all)
                Label("On This Mac", systemImage: "internaldrive").tag(SoundLibraryDestination.onThisMac)
                HStack {
                    Label("Downloads", systemImage: "arrow.down.circle")
                    Spacer()
                    if store.activeDownloadCount > 0 { Text("\(store.activeDownloadCount)").monospacedDigit().foregroundStyle(.secondary) }
                }.tag(SoundLibraryDestination.downloads)
            }
            Section("Instruments") {
                ForEach(SoundFamily.allCases) { family in
                    Label(family.title, systemImage: family.symbol).tag(SoundLibraryDestination.family(family))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sound Library")
    }

    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.destination.title).font(.title2.weight(.semibold))
                    Text(browserSubtitle)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                        Picker("Source", selection: $presentation.sourceID) {
                            Text("All Sources").tag("all")
                            Text("Built-in").tag("builtin")
                            ForEach(Array(Set(SoundBankCatalog.banks.map(\.sourceID))).sorted(), id: \.self) { id in
                                Text(id == "freepats" ? "FreePats" : id).tag(id)
                            }
                        }
                        Picker("Sort By", selection: $presentation.sort) {
                            Text("Name").tag(SoundLibrarySort.name)
                            Text("Download Size").tag(SoundLibrarySort.downloadSize)
                        }
                        if presentation.hasFilters { Button("Clear Filters") { presentation.clearFilters() } }
                    } label: { Label("Filter and Sort", systemImage: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).fixedSize().help("Filter by source and sort sounds")
            }
            if let request = navigation.request, let session = request.session, request.hasTarget {
                SoundLibraryTargetView(request: request, session: session)
            }
            if store.isImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking imported sounds…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }.padding(20)
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem {
            Button { presentation.destination = .downloads } label: {
                Label(store.activeDownloadCount > 0 ? "Downloads (\(store.activeDownloadCount))" : "Downloads", systemImage: "arrow.down.circle")
                    .badge(store.activeDownloadCount)
            }.help("Show downloads")
        }
        ToolbarItem {
            Button("Sound Details", systemImage: "sidebar.right") { showingInspector.toggle() }
                .help("Show or hide sound details").keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(selected == nil)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Menu {
                Button("Import Existing Sounds…", systemImage: "square.and.arrow.down") { store.importSounds() }.disabled(store.isImporting)
                Button("Download Entire Library…", systemImage: "arrow.down.circle") { confirmingAll = true }
                    .disabled(SoundLibraryPresentation.remainingDownloadSummary(states: store.states).banks.isEmpty)
            } label: { Label("Library Actions", systemImage: "ellipsis.circle") }
            .help("Import sounds or download the entire library")
            .accessibilityLabel("Library Actions")
        }
    }

    private func restore() {
        guard !restored else { return }; restored = true
        presentation.destination = SoundLibraryDestination(storageKey: restoredDestination)
        presentation.search = restoredSearch; presentation.sourceID = restoredSource
        presentation.sort = SoundLibrarySort(rawValue: restoredSort) ?? .name
    }
    private var browserSubtitle: String {
        if presentation.destination == .downloads { return "Downloads are shared across all your songs." }
        let count = "\(sounds.count) \(sounds.count == 1 ? "sound" : "sounds")"
        if presentation.destination == .onThisMac { return "\(count) ready offline, including built-in sounds." }
        return "\(count) · Built-in and downloadable instruments."
    }
    private func reconcile() {
        if presentation.reconcileSelection(states: store.states, recentlyCompleted: Set(store.recentlyCompletedBankIDs)) { audition.stop() }
    }
    private func applyRequest() { if let id = navigation.request?.instrumentID { reveal(id) } }
    private func reveal(_ id: String) {
        presentation.destination = .all; presentation.clearFilters(); presentation.selection = id; showingInspector = true
    }
}

func soundBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

extension SoundBankState {
    var title: String {
        switch self {
        case .notInstalled: "Not downloaded"
        case .queued: "Queued"
        case .downloading: "Downloading…"
        case .verifying: "Verifying…"
        case .installing: "Installing…"
        case .installed: "Downloaded"
        case .failed: "Download failed"
        }
    }
}

private struct SoundLibraryTargetView: View {
    @ObservedObject var request: SoundLibraryNavigationRequest
    @ObservedObject var session: ProjectSession
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.targetTitle).font(.callout)
                if !request.canAssign {
                    Text(session.canEditMusic ? (request.createsTrack ? "Reopen Sound Library from the toolbar to choose a new track destination." : "Reselect this track to apply a sound.") : "Superhuman · Browse and preview. Use Producer to change instruments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Clear Target", systemImage: "xmark") { SoundLibraryNavigation.shared.clearTarget() }
                .labelStyle(.iconOnly).buttonStyle(.plain).help("Browse without a target track")
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
