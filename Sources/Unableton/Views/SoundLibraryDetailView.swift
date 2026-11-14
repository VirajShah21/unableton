import SwiftUI
import UnabletonCore
import UnabletonLibrary

struct SoundLibraryDetailView: View {
    let item: SoundLibraryItem
    @ObservedObject var store: SoundLibraryStore
    @ObservedObject var audition: SoundAuditionController
    let request: SoundLibraryNavigationRequest?
    let remove: (SoundBank) -> Void
    @State private var technicalDetails = false
    private var installed: Bool { store.isInstalled(item.preset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: item.symbol).font(.system(size: 32, weight: .medium)).foregroundStyle(.tint)
                    .frame(height: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(item.family.title + " · " + (item.isBuiltIn ? "Built-in" : store.state(for: item.preset)?.title ?? "Not downloaded"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let warning = item.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                previewActions
                if let request, let session = request.session, request.hasTarget {
                    SoundLibraryAssignmentView(request: request, session: session, item: item, installed: installed)
                }
                if let error = audition.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(item.description).font(.body).textSelection(.enabled)
                    if !item.preset.roles.isEmpty {
                        LabeledContent("Useful for", value: item.preset.roles.joined(separator: ", "))
                            .font(.callout)
                    }
                    if let bank = item.bank {
                        downloadState(bank)
                        sourceDetails(bank)
                    } else {
                        Text("Included with Unableton. Available offline and always ready to preview.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Technical Details", isExpanded: $technicalDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Range", value: "\(TrackColors.noteName(item.preset.minimumPitch))–\(TrackColors.noteName(item.preset.maximumPitch))")
                            if let pitches = item.preset.supportedPitches { Text("\(pitches.count) supported pitches within this range.") }
                            LabeledContent("Source name", value: item.sourceName)
                            if let bank = item.bank {
                                LabeledContent("Version", value: bank.version)
                                LabeledContent("Program", value: "\(item.preset.program)")
                                LabeledContent("Bank", value: "\(item.preset.bank)")
                            }
                        }.font(.caption).textSelection(.enabled).padding(.top, 10)
                    }.font(.callout)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: item.id) { _, _ in technicalDetails = false }
    }

    @ViewBuilder private var previewActions: some View {
        if installed {
            Button {
                audition.preview(item.preset)
            } label: {
                Label(audition.isActive(for: item.id) ? "Stop Preview" : "Preview", systemImage: audition.isActive(for: item.id) ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(audition.unavailableReason != nil && !audition.isActive(for: item.id))
            .accessibilityLabel("\(audition.isActive(for: item.id) ? "Stop preview of" : "Preview") \(item.name)")
            if audition.isActive(for: item.id) && audition.phase == .preparing {
                HStack { ProgressView().controlSize(.mini); Text("Preparing preview…").font(.caption).foregroundStyle(.secondary) }
            } else if let reason = audition.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        } else if let bank = item.bank, store.state(for: item.preset)?.isBusy != true {
            if request?.hasTarget == true && request?.session?.canEditMusic == true {
                downloadButton(bank).buttonStyle(.bordered).controlSize(.large)
            } else {
                downloadButton(bank).buttonStyle(.borderedProminent).controlSize(.large)
            }
            Text("Download to preview. Sounds stay available offline.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func downloadButton(_ bank: SoundBank) -> some View {
        Button { store.download(bank.id) } label: {
            Label("Download · \(soundBytes(bank.downloadBytes))", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func downloadState(_ bank: SoundBank) -> some View {
        let state = store.states[bank.id] ?? .notInstalled
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(1, total)))
                Text("\(soundBytes(received)) of \(soundBytes(total))").font(.caption).monospacedDigit()
                cancelAction(bank)
            case .queued, .verifying, .installing:
                HStack { ProgressView().controlSize(.small); Text(state.title).font(.callout) }
                cancelAction(bank)
            case .failed(let message):
                Label("Download Failed", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                Text(message).font(.caption).textSelection(.enabled)
                Button("Retry Download") { store.download(bank.id) }
            case .installed(_, let inUse):
                Button("Remove Download…", role: .destructive) { remove(bank) }.disabled(inUse)
                if inUse { Text("In use by playback, preview, rendering, or generation.").font(.caption).foregroundStyle(.secondary) }
            case .notInstalled: EmptyView()
            }
            let siblings = SoundLibraryPresentation.sharedBankPresets(bank.id)
            if siblings.count > 1 {
                Text("Shared download · Includes \(siblings.count) sounds: \(siblings.map(\.name).joined(separator: ", ")). Removing it removes all of them from this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func cancelAction(_ bank: SoundBank) -> some View {
        if store.activities[bank.id]?.libraryRequested == true {
            Button("Cancel Library Request") { store.cancel(bank.id) }
        }
        if store.activities[bank.id]?.requiredByOtherOperations == true {
            Text("Also required by another operation. Canceling a library request does not cancel that operation’s download.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sourceDetails(_ bank: SoundBank) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source & License").font(.headline)
            LabeledContent("Source", value: item.providerName)
            LabeledContent("Download", value: soundBytes(bank.downloadBytes))
            LabeledContent("Disk space", value: soundBytes(bank.installedBytes))
            Link(bank.license, destination: bank.licenseURL)
            Text(bank.attribution).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Link("View Original Source", destination: bank.sourceURL)
        }.font(.callout)
    }
}

private struct SoundLibraryAssignmentView: View {
    @ObservedObject var request: SoundLibraryNavigationRequest
    @ObservedObject var session: ProjectSession
    let item: SoundLibraryItem
    let installed: Bool
    var body: some View {
        let incompatibility = request.incompatibilityReason(for: item.id)
        VStack(alignment: .leading, spacing: 8) {
            if session.canEditMusic {
                Button {
                    request.use(item.id)
                } label: {
                    Text(request.actionTitle(installed: installed))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!request.canAssign || request.assignmentID != nil || incompatibility != nil)
                if let incompatibility {
                    Text(incompatibility).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if request.assignmentID != nil {
                    HStack { ProgressView().controlSize(.mini); Text("Preparing instrument…").font(.caption) }
                    Button("Cancel Assignment") { request.cancel() }
                }
            }
            if let message = request.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}
