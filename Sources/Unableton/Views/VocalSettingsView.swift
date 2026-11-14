import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UnabletonAI

struct VocalSettingsView: View {
    @AppStorage(CredentialStore.storagePreferenceKey) private var useKeychain = false
    @AppStorage("vocals.enabled") private var enabled = false
    @AppStorage("vocals.provider") private var provider = "audial"
    @AppStorage("vocals.audialUserID") private var userID = ""
    @AppStorage("vocals.referenceName") private var referenceName = ""
    @State private var key = ""
    @State private var message = ""
    @State private var busy = false
    @State private var loadingKey = true
    @State private var loadID = UUID()
    private var storage: CredentialStorage { useKeychain ? .keychain : .file }
    private var credentialBusy: Bool { busy || loadingKey }
    var body: some View {
        Section("Vocals") {
            Toggle("Enable singing generation in AI chats", isOn: $enabled)
            Picker("Vocal provider", selection: $provider) {
                Text("Audial — reference voice").tag("audial")
                Text("Rinoa — stock singers (experimental)").tag("rinoa")
            }.pickerStyle(.menu).disabled(busy)
            SecureField("Vocal API key", text: $key).textContentType(.password).disabled(credentialBusy)
            if storage == .keychain {
                Button("Load Saved Vocal Key") { Task { await loadKey(allowKeychain: true) } }
                    .disabled(credentialBusy)
            }
            Text("Credential storage: \(storage.title).")
                .font(.caption).foregroundStyle(.secondary)
            if provider == "audial" {
                TextField("Audial user ID", text: $userID)
                HStack {
                    LabeledContent("Reference voice", value: referenceName.isEmpty ? "None selected" : referenceName)
                    Button("Choose…") { chooseReference() }
                    if !referenceName.isEmpty {
                        Button("Remove", role: .destructive) {
                            do { try FileManager.default.removeItem(at: VocalPreferences.referenceURL); referenceName = "" }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
                Text("Choose 5–10 seconds of your voice or a singer who has agreed to this use. Vocal generation uploads that clip, the lyrics and melody to Audial. Its subscription is separate from OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Audial setup and pricing", destination: URL(string: "https://www.audialmusic.ai/tools/text-to-vocal")!)
            } else {
                Text("Uses stock English or Chinese singers. Rinoa receives lyrics and the melody score and charges its own credits. Its public API and general terms contain conflicting integration guidance; confirm your permitted use before releasing recordings or distributing an integration.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Rinoa API settings", destination: URL(string: "https://rinoa.ai/settings/api")!)
            }
            HStack {
                Button("Save Vocal Key") { saveKey() }.disabled(credentialBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(provider == "audial" ? "Check Setup" : "Load Singers") { checkSetup() }.disabled(credentialBusy || key.isEmpty)
                Spacer()
                Button("Remove Vocal Key", role: .destructive) { removeKey() }.disabled(credentialBusy)
            }
            Text("Singing becomes an audio clip; the editable source melody and lyric syllables are saved with each take. Change notes or lyrics in chat, then render again. Canceling stops local work; a submitted provider job may still consume credits.")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            if busy || loadingKey { ProgressView().controlSize(.small) }
        }
        .task(id: "\(useKeychain)-\(provider)") { await loadKey() }
    }
    private func loadKey(allowKeychain: Bool = false) async {
        let selectedStorage = storage, preference = useKeychain, selectedProvider = provider, id = UUID()
        loadID = id; loadingKey = true; key = ""; message = ""
        guard selectedStorage != .keychain || allowKeychain else {
            loadingKey = false
            return
        }
        do {
            let loaded = try await Task.detached { try CredentialStore.load(provider: selectedProvider, storage: selectedStorage) }.value
            guard !Task.isCancelled, loadID == id, useKeychain == preference, provider == selectedProvider else { return }
            key = loaded ?? ""
        } catch {
            guard !Task.isCancelled, loadID == id, useKeychain == preference, provider == selectedProvider else { return }
            message = error.localizedDescription
        }
        if !Task.isCancelled, loadID == id, useKeychain == preference, provider == selectedProvider { loadingKey = false }
    }
    private func saveKey(successMessage: String? = nil) {
        let selectedStorage = storage, preference = useKeychain, selectedProvider = provider, value = key
        busy = true
        Task {
            do {
                try await Task.detached { try CredentialStore.save(value, provider: selectedProvider, storage: selectedStorage) }.value
                if useKeychain == preference, provider == selectedProvider {
                    message = successMessage ?? "Vocal key saved in \(selectedStorage.title)."
                }
            } catch { if useKeychain == preference, provider == selectedProvider { message = error.localizedDescription } }
            busy = false
        }
    }
    private func removeKey() {
        let selectedStorage = storage, preference = useKeychain, selectedProvider = provider
        busy = true
        Task {
            do {
                try await Task.detached { try CredentialStore.delete(provider: selectedProvider, storage: selectedStorage) }.value
                if useKeychain == preference, provider == selectedProvider { key = ""; message = "Vocal key removed from \(selectedStorage.title)." }
            } catch { if useKeychain == preference, provider == selectedProvider { message = error.localizedDescription } }
            busy = false
        }
    }
    private func chooseReference() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Choose 5–10 seconds of your own or a consenting singer’s voice."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try VocalPreferences.saveReference(url); message = "Reference voice saved locally." }
        catch { message = error.localizedDescription }
    }
    private func checkSetup() {
        if provider == "audial" {
            guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !referenceName.isEmpty, FileManager.default.fileExists(atPath: VocalPreferences.referenceURL.path) else {
                message = "Add your user ID and choose a reference voice first."; return
            }
            saveKey(successMessage: "Local setup is ready. Credentials and subscription are verified when you generate a vocal; no credits were spent by this check.")
            return
        }
        busy = true; message = "Loading singers…"
        Task {
            do { let singers = try await RinoaVocalClient(apiKey: key).singers(); message = "Connected: \(singers.count) singers available." }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
}
