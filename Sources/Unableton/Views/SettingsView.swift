import SwiftUI
import UnabletonAI

struct SettingsView: View {
    @AppStorage(CredentialStore.storagePreferenceKey) private var useKeychain = false
    @AppStorage(SoundLibraryStore.automaticPreference) private var automaticDownloads = false
    @AppStorage("ai.routing") private var routing = "auto"
    @AppStorage("ai.model") private var model = "gpt-6-luna"
    @AppStorage("ai.customModel") private var customModel = ""
    @AppStorage("ai.reasoning") private var reasoning = "low"
    @State private var apiKey = ""
    @State private var message = ""
    @State private var busy = false
    @State private var models: [String] = []
    @State private var loadingKey = true
    @State private var loadID = UUID()
    private var storage: CredentialStorage { useKeychain ? .keychain : .file }
    private var credentialBusy: Bool { loadingKey || busy }
    private let curated = ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"]
    private var selection: Binding<String> {
        Binding(get: { routing == "auto" ? "auto" : routing == "custom" ? "custom" : model }, set: { next in
            if next == "auto" { routing = "auto" }
            else if next == "custom" { routing = "custom" }
            else { model = next; routing = "fixed" }
        })
    }
    private var extraModels: [String] {
        Array(Set(models + (routing == "fixed" && !curated.contains(model) ? [model] : []))).filter { !curated.contains($0) }.sorted()
    }
    private var effectiveModel: String { routing == "auto" ? "gpt-6-luna" : routing == "custom" ? customModel : model }
    var body: some View {
        Form {
            Section("Credentials") {
                Toggle("Use macOS Keychain for Credentials", isOn: $useKeychain)
                if useKeychain {
                    Text("Credentials are saved in macOS Keychain only while this is enabled. Loading or saving keys may require macOS authorization.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Credentials are stored unencrypted in a local file with owner-only permissions, outside song documents and Git. Keychain is off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(CredentialStore.fileURL.path).font(.caption).textSelection(.enabled)
                }
                Text("Switching storage does not move existing keys. Save each key in the selected store.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("OpenAI") {
                SecureField("API key", text: $apiKey).textContentType(.password).disabled(credentialBusy)
                if storage == .keychain {
                    Button("Load Saved Key") { Task { await loadKey(allowKeychain: true) } }
                        .disabled(credentialBusy)
                }
                Picker("Model", selection: selection) {
                    Text("Auto — economical, upgrade when needed").tag("auto")
                    Divider()
                    Text("GPT-6 Luna — economical").tag("gpt-6-luna")
                    Text("GPT-6.1 Sol — balanced").tag("gpt-6.1-sol")
                    Text("GPT-6 Astra — frontier").tag("gpt-6-astra")
                    ForEach(extraModels, id: \.self) { candidate in Text(candidate).tag(candidate) }
                    Divider()
                    Text("Other…").tag("custom")
                }.pickerStyle(.menu)
                if routing == "custom" { TextField("Custom Responses model ID", text: $customModel) }
                if routing == "auto" {
                    Text("Starts with gpt-6-luna. If a stronger model is needed, Unableton may retry once with gpt-6-astra. The chat shows any upgrade; frontier requests can cost more.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Uses \(effectiveModel.isEmpty ? "the model ID entered above" : effectiveModel) for every request. Automatic upgrades are off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh Available Models") { refreshModels() }.disabled(credentialBusy || apiKey.isEmpty)
                    Spacer()
                    Picker("Reasoning", selection: $reasoning) {
                        Text("Model default").tag(""); Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high")
                    }.frame(width: 210)
                }
                HStack {
                    Button("Save Key") { saveKey() }.disabled(credentialBusy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Test Connection") { testConnection() }.disabled(credentialBusy || effectiveModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty)
                    Spacer()
                    Button("Remove Key", role: .destructive) { removeKey() }.disabled(credentialBusy)
                }
                Text("Credential storage: \(storage.title). Prompts and the song’s notes and instrument settings are sent to OpenAI. Audio stays on your Mac unless you enable optional OpenAI audio inspection or use a vocal provider below.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("OpenAI API settings", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
            DraftReviewSettingsView()
            ReferenceSettingsView()
            VocalSettingsView()
            Section("Sound Library") {
                Toggle("Allow automatic sound downloads for AI", isOn: $automaticDownloads)
                Text("Sampled instruments download separately and are shared by all songs. Six synthesized sounds remain built in. Downloads are stored in Application Support/Unableton/SoundLibrary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                LabeledContent("Input and output", value: "System default devices")
                Text("Change devices in macOS Sound settings. Input monitoring is off. Recording asks for microphone access the first time you use it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            if busy || loadingKey { ProgressView().controlSize(.small) }
        }
        .formStyle(.grouped).padding().frame(width: 650, height: 700)
        .task(id: useKeychain) { await loadKey() }
    }
    private func loadKey(allowKeychain: Bool = false) async {
        let selectedStorage = storage, preference = useKeychain, id = UUID()
        loadID = id; loadingKey = true; apiKey = ""; message = ""
        guard selectedStorage != .keychain || allowKeychain else {
            loadingKey = false
            return
        }
        do {
            let loaded = try await Task.detached { try CredentialStore.load(storage: selectedStorage) }.value
            guard !Task.isCancelled, loadID == id, useKeychain == preference else { return }
            apiKey = loaded ?? ""
        } catch {
            guard !Task.isCancelled, loadID == id, useKeychain == preference else { return }
            message = error.localizedDescription
        }
        if !Task.isCancelled, loadID == id, useKeychain == preference { loadingKey = false }
    }
    private func refreshModels() {
        busy = true; message = "Loading models…"
        Task {
            do {
                let available = try await MusicAgent().availableModels(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                models = available.filter { ModelRouting.supportedModelIDs.contains($0) }
                message = "Available supported composition models loaded. Other model IDs can be entered through Other…."
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func saveKey() {
        let selectedStorage = storage, preference = useKeychain, key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            do {
                try await Task.detached { try CredentialStore.save(key, storage: selectedStorage) }.value
                if useKeychain == preference { message = "Key saved in \(selectedStorage.title)." }
            } catch { if useKeychain == preference { message = error.localizedDescription } }
            busy = false
        }
    }
    private func removeKey() {
        let selectedStorage = storage, preference = useKeychain
        busy = true
        Task {
            do {
                try await Task.detached { try CredentialStore.delete(storage: selectedStorage) }.value
                if useKeychain == preference { apiKey = ""; message = "Key removed from \(selectedStorage.title)." }
            } catch { if useKeychain == preference { message = error.localizedDescription } }
            busy = false
        }
    }
    private func testConnection() {
        let testedModel = effectiveModel
        busy = true; message = "Checking \(testedModel)…"
        let configuration = AgentConfiguration(model: testedModel, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), reasoningEffort: reasoning, autoUpgrade: false)
        Task {
            do { try await MusicAgent().testConnection(configuration: configuration); message = "Connected to \(testedModel)." }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
}
