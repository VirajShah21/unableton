import SwiftUI
import UnabletonAI

struct DraftReviewSettingsView: View {
    @AppStorage(DraftReviewPreferences.enabledKey) private var enabled = false
    @AppStorage(CredentialStore.storagePreferenceKey) private var useKeychain = false
    @State private var key = ""
    @State private var message = ""
    @State private var busy = false
    @State private var loading = true
    @State private var loadID = UUID()
    private var storage: CredentialStorage { useKeychain ? .keychain : .file }

    var body: some View {
        Section("Draft review") {
            Toggle("Observe AI drafts with Jev", isOn: $enabled)
            Text("Local analysis is saved with every generation. When enabled, Jev also reviews the prompt, change summary and musical measurements after the song is applied. Findings are available in chat; they do not repair, reject or upgrade a generation.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("TypeSafe API key", text: $key)
                .textContentType(.password).disabled(busy || loading)
            if useKeychain {
                Button("Load Saved TypeSafe Key") { Task { await loadKey(allowKeychain: true) } }
                    .disabled(busy || loading)
            }
            HStack {
                Button("Save TypeSafe Key") { saveKey() }.disabled(busy || loading || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test Jev Connection") { testConnection() }.disabled(busy || loading || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("Remove TypeSafe Key", role: .destructive) { removeKey() }.disabled(busy || loading)
            }
            Text("Uses jev-1.14.0 with separate TypeSafe billing. Sends bounded text and symbolic measurements; recordings, audio files and API keys are excluded from the review data. This does not evaluate how the music sounds. Credential storage: \(storage.title).")
                .font(.caption).foregroundStyle(.secondary)
            Link("TypeSafe API console", destination: URL(string: "https://console.typesafe.ai")!)
            if busy || loading { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
        }
        .task(id: useKeychain) { await loadKey() }
    }

    private func loadKey(allowKeychain: Bool = false) async {
        let selected = storage, preference = useKeychain, id = UUID()
        loadID = id; loading = true; key = ""; message = ""
        guard selected != .keychain || allowKeychain else { loading = false; return }
        do {
            let loaded = try await Task.detached { try CredentialStore.load(provider: "typesafe", storage: selected) }.value
            guard !Task.isCancelled, loadID == id, useKeychain == preference else { return }
            key = loaded ?? ""
        } catch {
            guard !Task.isCancelled, loadID == id, useKeychain == preference else { return }
            message = error.localizedDescription
        }
        if !Task.isCancelled, loadID == id, useKeychain == preference { loading = false }
    }

    private func saveKey() {
        let selected = storage, preference = useKeychain, value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            do {
                try await Task.detached { try CredentialStore.save(value, provider: "typesafe", storage: selected) }.value
                if useKeychain == preference { message = "TypeSafe key saved in \(selected.title)." }
            } catch { if useKeychain == preference { message = error.localizedDescription } }
            busy = false
        }
    }

    private func removeKey() {
        let selected = storage, preference = useKeychain
        busy = true
        Task {
            do {
                try await Task.detached { try CredentialStore.delete(provider: "typesafe", storage: selected) }.value
                if useKeychain == preference { key = ""; message = "TypeSafe key removed." }
            } catch { if useKeychain == preference { message = error.localizedDescription } }
            busy = false
        }
    }

    private func testConnection() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; message = "Checking Jev…"
        Task {
            do { try await JevClient().testConnection(apiKey: value); message = "Connected to Jev. This check uses a small TypeSafe request." }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
}
