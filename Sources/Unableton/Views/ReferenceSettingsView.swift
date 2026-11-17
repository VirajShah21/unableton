import SwiftUI

struct ReferenceSettingsView: View {
    @ObservedObject private var local = LocalReferenceSetupStore.shared
    @AppStorage(ReferencePrivacyPreferences.audioInspectionKey) private var allowAudioInspection = false

    var body: some View {
        Section("Song Attachments") {
            LabeledContent("Local processing", value: local.availability?.installed == true ? "Ready" : "Not installed")
            if let availability = local.availability {
                Text(availability.message).font(.caption).foregroundStyle(.secondary)
            }
            if local.isInstalling {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(local.status).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Cancel") { local.cancel() }.disabled(local.isCanceling)
                }
            } else {
                HStack {
                    Button(setupLabel) { local.install() }.disabled(local.isChecking)
                    Button("Check Setup") { Task { await local.refresh() } }.disabled(local.isChecking)
                    if local.isChecking { ProgressView().controlSize(.small) }
                }
                if !local.status.isEmpty { Text(local.status).font(.caption).textSelection(.enabled) }
            }
            if let error = local.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("Local processing requires an Apple silicon Mac. Demucs separates vocals and instruments; Basic Pitch converts melodic parts to editable notes. Setup downloads the managed runtime and models once; there are no per-song separation or transcription API charges.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Setup requires uv", destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                .font(.caption)
            Toggle("Allow OpenAI audio inspection", isOn: $allowAudioInspection)
            Text("Chat and composition keep using your OpenAI key. When this option is enabled, the agent can send short audio excerpts to gpt-audio-1.5 for interpretation, with OpenAI billing. Local analysis, stem separation and note extraction work with this option off.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Up to four songs per message, ten minutes and 100 MiB each. Original vocals stay audio. Separation, note extraction and musical landmarks can contain errors.")
                .font(.caption).foregroundStyle(.secondary)
        }.task { await local.refresh() }
    }

    private var setupLabel: String {
        if local.error != nil { return "Retry Setup" }
        return local.availability?.installed == true ? "Repair Setup" : "Set Up Local Processing"
    }
}
