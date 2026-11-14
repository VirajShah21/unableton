import Foundation
import AVFAudio
import UnabletonCore
import UnabletonAudio
import UnabletonAI

struct QueuedPrompt {
    let conversationID: UUID
    let messageID: UUID
    let selection: ProjectSelection
}
extension ProjectSession {
    func submitPrompt() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            guard let key = try keyProvider(), !key.isEmpty else {
                errorMessage = "Add your OpenAI API key in Unableton Settings to generate music. Playback, recording and faithful transcription work offline; use Producer for manual editing."
                return
            }
        } catch { errorMessage = error.localizedDescription; return }
        if selectedConversationID == nil { newConversation() }
        guard let id = selectedConversationID, let index = file.conversations.firstIndex(where: { $0.id == id }) else { return }
        let message = ChatMessage(role: "user", text: text)
        if file.conversations[index].messages.isEmpty { file.conversations[index].title = String(text.prefix(48)) }
        file.conversations[index].messages.append(message)
        pendingPrompts.append(QueuedPrompt(conversationID: id, messageID: message.id, selection: selection))
        queuedCount = pendingPrompts.count
        composer = ""
        if generationTask == nil {
            generationTask = Task { await processQueue() }
        }
    }
    func cancelGeneration() {
        generationTask?.cancel()
        pendingPrompts.removeAll(); queuedCount = 0
        generationStatus = "Canceling…"
    }
    func processQueue() async {
        isGenerating = true
        defer {
            isGenerating = false; generationStatus = ""; generationTask = nil
            pendingPrompts.removeAll(); queuedCount = 0
        }
        while !pendingPrompts.isEmpty, !Task.isCancelled, !closed {
            while (transcription.isWorking || transcription.isCapturing), !Task.isCancelled, !closed {
                generationStatus = "Waiting for Transcribe…"
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, !closed else { break }
            let request = pendingPrompts.removeFirst(); queuedCount = pendingPrompts.count
            do { try await generate(request) }
            catch is CancellationError {
                appendAssistant("Generation canceled. The song was kept unchanged.", conversationID: request.conversationID)
                break
            } catch {
                appendAssistant("Unable to finish: \(error.localizedDescription)", conversationID: request.conversationID)
                errorMessage = error.localizedDescription
            }
        }
    }
    func generate(_ request: QueuedPrompt) async throws {
        guard let key = try keyProvider(), !key.isEmpty else { throw ProjectError("Add an OpenAI API key in Settings.") }
        let routing = UserDefaults.standard.string(forKey: "ai.routing") ?? "auto"
        let selectedModel = UserDefaults.standard.string(forKey: "ai.model") ?? "gpt-6-luna"
        let model = routing == "auto" ? "gpt-6-luna" : routing == "custom" ? (UserDefaults.standard.string(forKey: "ai.customModel") ?? "") : selectedModel
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("Choose a model in Settings before generating.") }
        let reasoning = UserDefaults.standard.string(forKey: "ai.reasoning") ?? "low"
        var configuration = AgentConfiguration(model: model, apiKey: key, reasoningEffort: reasoning, autoUpgrade: routing == "auto", frontierModel: "gpt-6-astra")
        let budget = GenerationBudget(maximumRequests: configuration.maximumSteps, timeout: configuration.timeout)
        configuration.runBudget = budget
        let instruments = InstrumentRunResources()
        let downloadStatus: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in if self?.closed == false { self?.generationStatus = text } }
        }
        configuration.instruments = InstrumentDependencies(
            installed: { await SoundLibraryStore.shared.installedIDs() },
            ensure: { ids in try await instruments.ensure(ids, budget: budget, status: downloadStatus) }
        )
        let vocals = try VocalPreferences.makeSession()
        let draftDirectory = cacheURL.appendingPathComponent("VocalDraft-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftDirectory) }
        for attempt in 0...1 {
            try await budget.check()
            guard let conversation = file.conversations.first(where: { $0.id == request.conversationID }) else { return }
            var context = conversation
            if let cutoff = context.messages.firstIndex(where: { $0.id == request.messageID }) { context.messages = Array(context.messages.prefix(through: cutoff)) }
            let snapshot = file.song; let assets = assetURLs; let cache = cacheURL
            generationStatus = attempt == 0 ? "Composing…" : "Updating for your latest edits…"
            let result = try await agent.generate(
                song: snapshot, conversation: context, selection: request.selection, configuration: configuration, vocals: vocals,
                preview: { song, fromBeat, lengthBeats in
                    try Task.checkCancellation()
                    var previewAssets = assets
                    if let vocals {
                        let generated = await vocals.assets(for: song)
                        if !generated.isEmpty { try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true) }
                        for (id, data) in generated {
                            let url = draftDirectory.appendingPathComponent("\(id).wav")
                            try data.write(to: url, options: .atomic); previewAssets[id] = url
                        }
                    }
                    let renderAssets = previewAssets
                    let resources = await instruments.snapshot()
                    let output = cache.appendingPathComponent("Preview-\(UUID().uuidString).wav")
                    let renderTask = Task.detached(priority: .userInitiated) {
                        try OfflineRenderer.render(song: song, assets: renderAssets, to: output, fromBeat: fromBeat, lengthBeats: lengthBeats, resources: resources)
                    }
                    let report = try await withTaskCancellationHandler {
                        try await renderTask.value
                    } onCancel: { renderTask.cancel() }
                    await MainActor.run { [weak self] in if self?.closed == false { self?.previewURL = output } }
                    return PreviewReport(url: output, duration: report.duration, peak: report.peak, rms: report.rms, clippedSamples: report.clippedSamples, silent: report.silent)
                }, status: { [weak self] text in
                    Task { @MainActor in if self?.closed == false { self?.generationStatus = text } }
                })
            try await budget.check()
            guard !closed else { return }
            if file.song.revision != snapshot.revision {
                if attempt == 0 { continue }
                throw ProjectError("The song changed again while composing. Your edits are safe; send the prompt again when ready.")
            }
            try ProjectEditor.validate(result.song)
            var musicalResult = result.song
            musicalResult.revision = snapshot.revision
            let hasChanges = musicalResult != snapshot
            if hasChanges { try InstrumentResources.validatePlayback(in: result.song) }
            if hasChanges { try await instruments.ensure(InstrumentResources.requiredIDs(in: result.song), budget: budget, status: downloadStatus) }
            let analysisSong: Song = {
                var song = result.song
                song.revision = snapshot.revision + (hasChanges ? 1 : 0)
                return song
            }()
            let usage = await budget.snapshot()
            var record = GenerationRecord(id: result.runID, conversationID: request.conversationID, model: result.model, summary: result.summary, baseRevision: snapshot.revision, appliedRevision: hasChanges ? snapshot.revision + 1 : nil, inputTokens: result.inputTokens, outputTokens: result.outputTokens, routingReason: result.routingReason, attemptedModels: result.attemptedModels)
            record.generationRequests = usage.requests
            record.transientRetries = usage.retries
            // Stage every payload before touching the document. A disk failure
            // or cancellation leaves both musical state and saved assets intact.
            var staged: [UUID: URL] = [:]
            var stagedWaveforms: [UUID: [Float]] = [:]
            var installed = false
            defer {
                if !installed {
                    for url in staged.values { try? FileManager.default.removeItem(at: url) }
                }
            }
            for asset in result.song.assets where !snapshot.assets.contains(where: { $0.id == asset.id }) {
                guard let data = result.generatedAssets[asset.id], !data.isEmpty else { throw ProjectError("Generated audio data is missing. The song was not changed.") }
                let url = cache.appendingPathComponent("\(asset.id)-Generated.wav")
                try data.write(to: url, options: .atomic); staged[asset.id] = url
                if let source = try? AVAudioFile(forReading: url) { stagedWaveforms[asset.id] = Self.waveform(file: source) }
            }
            try await budget.check()
            // The budget read yields. Recheck after all preparation, with no
            // further await between this guard and the complete transaction.
            guard !closed else { return }
            if file.song.revision != snapshot.revision {
                if attempt == 0 { continue }
                throw ProjectError("The song changed again while composing. Your edits are safe; send the prompt again when ready.")
            }
            for (id, url) in staged {
                assetData[id] = result.generatedAssets[id]; assetURLs[id] = url
                if let waveform = stagedWaveforms[id] { waveforms[id] = waveform }
            }
            installed = true
            file.generations.append(record)
            if let index = file.conversations.firstIndex(where: { $0.id == request.conversationID }) {
                file.conversations[index].responseItems = result.responseItems
                file.conversations[index].responseModel = result.model
                file.conversations[index].messages.append(ChatMessage(role: "assistant", text: result.summary + (result.routingReason.map { "\n\nModel upgrade: \($0)" } ?? ""), runID: result.runID))
            }
            if hasChanges { commit(result.song, replacing: snapshot, name: "AI: \(String(record.summary.prefix(40)))", generationID: record.id) }
            if selection.trackID == nil, let first = file.song.tracks.first { select(track: first.id, clip: first.clips.first?.id) }
            generationStatus = "Analyzing applied changes…"
            await analyzeAppliedDraft(runID: record.id, before: snapshot, after: analysisSong, selection: request.selection,
                                      prompt: context.messages.last(where: { $0.role == "user" })?.text ?? "", summary: result.summary)
            return
        }
    }
    func appendAssistant(_ text: String, conversationID: UUID) {
        guard let index = file.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        file.conversations[index].messages.append(ChatMessage(role: "assistant", text: text))
    }
}
