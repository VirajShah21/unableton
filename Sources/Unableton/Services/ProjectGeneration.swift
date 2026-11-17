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
        guard !closed, !attachmentImporting else { return }
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
        let message = ChatMessage(role: "user", text: text, attachmentIDs: pendingAttachmentIDs.isEmpty ? nil : pendingAttachmentIDs)
        var submitted = file
        if submitted.conversations[index].messages.isEmpty { submitted.conversations[index].title = String(text.prefix(48)) }
        submitted.conversations[index].messages.append(message)
        submitted.conversations[index].draftAttachmentIDs = nil
        do { try ProjectArchive.validateMetadata(submitted) }
        catch { errorMessage = error.localizedDescription; return }
        file = submitted
        pendingPrompts.append(QueuedPrompt(conversationID: id, messageID: message.id, selection: selection))
        queuedCount = pendingPrompts.count
        composer = ""
        composerAttachments[id] = []
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
        configuration.references = referenceTools(for: request, budget: budget, openAIKey: key)
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
        let referenceDirectory = cacheURL.appendingPathComponent("ReferenceDraft-\(budget.runID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: draftDirectory)
            try? FileManager.default.removeItem(at: referenceDirectory)
        }
        for attempt in 0...1 {
            try await budget.check()
            guard let conversation = file.conversations.first(where: { $0.id == request.conversationID }) else { return }
            var context = conversation
            if let cutoff = context.messages.firstIndex(where: { $0.id == request.messageID }) { context.messages = Array(context.messages.prefix(through: cutoff)) }
            let snapshot = file.song; let assets = assetURLs; let cache = cacheURL
            let references = configuration.references
            generationStatus = attempt == 0 ? "Composing…" : "Updating for your latest edits…"
            let result = try await agent.generate(
                song: snapshot, conversation: context, selection: request.selection, configuration: configuration, vocals: vocals,
                preview: { song, fromBeat, lengthBeats in
                    try Task.checkCancellation()
                    var previewAssets = assets
                    if let references { previewAssets.merge(await references.assets(song)) { _, new in new } }
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
            let stagingDirectory = cache.appendingPathComponent("Generated-\(UUID())", isDirectory: true)
            guard let blobStore = document.blobStore else { throw ProjectError("The project audio store is unavailable.") }
            let previousBlobIDs = Set(blobStore.snapshot().urls.keys)
            let newAssets = result.song.assets.filter { asset in !snapshot.assets.contains(where: { $0.id == asset.id }) }
            var installed = false
            defer {
                try? FileManager.default.removeItem(at: stagingDirectory)
                if !installed {
                    try? blobStore.discardUnpublished(ids: Set(newAssets.map(\.id)).subtracting(previousBlobIDs))
                }
            }
            let prepared = try await referenceWork { () -> ([UUID: URL], [UUID: [Float]]) in
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                var files: [UUID: URL] = [:], waveforms: [UUID: [Float]] = [:]
                for asset in newAssets {
                    try Task.checkCancellation()
                    let url = stagingDirectory.appendingPathComponent("\(asset.id).wav")
                    if let file = result.generatedFiles[asset.id] { try FileManager.default.copyItem(at: file, to: url) }
                    else if let data = result.generatedAssets[asset.id], !data.isEmpty { try data.write(to: url, options: .atomic) }
                    else { throw ProjectError("Generated audio data is missing. The song was not changed.") }
                    files[asset.id] = url
                    if let source = try? AVAudioFile(forReading: url) { waveforms[asset.id] = Self.waveform(file: source) }
                }
                try Task.checkCancellation()
                return (files, waveforms)
            }
            let staged = prepared.0, stagedWaveforms = prepared.1
            if references != nil {
                try validateReferenceStorage(adding: staged)
                let renderAssets = assets.merging(staged) { _, new in new }
                _ = try await referenceWork { try AudioMemoryPreflight.validate(song: result.song, assets: renderAssets) }
            }
            let adopted = try await referenceWork { () -> [UUID: URL] in
                var files: [UUID: URL] = [:]
                for (id, url) in staged { try Task.checkCancellation(); files[id] = try blobStore.insert(file: url, id: id) }
                return files
            }
            try await budget.check()
            // The budget read yields. Recheck after all preparation, with no
            // further await between this guard and the complete transaction.
            guard !closed else { return }
            if file.song.revision != snapshot.revision {
                if attempt == 0 { continue }
                throw ProjectError("The song changed again while composing. Your edits are safe; send the prompt again when ready.")
            }
            if references != nil { try validateReferenceStorage(adding: adopted) }
            var completed = file
            completed.song = analysisSong
            completed.generations.append(record)
            if let index = completed.conversations.firstIndex(where: { $0.id == request.conversationID }) {
                completed.conversations[index].responseItems = result.responseItems
                completed.conversations[index].responseModel = result.model
                completed.conversations[index].messages.append(ChatMessage(role: "assistant", text: result.summary + (result.routingReason.map { "\n\nModel upgrade: \($0)" } ?? ""), runID: result.runID))
            }
            try ProjectArchive.validateMetadata(completed)
            document.publishInstalledBlobs()
            for (id, _) in staged {
                assetURLs[id] = adopted[id]
                if result.song.assets.first(where: { $0.id == id })?.referenceDerivation != nil { retainedReferenceIDs.insert(id) }
                if let waveform = stagedWaveforms[id] { waveforms[id] = waveform }
            }
            installed = true
            if hasChanges { commit(result.song, replacing: snapshot, name: "AI: \(String(record.summary.prefix(40)))", generationID: record.id, project: completed) }
            else { file = completed }
            if selection.trackID == nil, let first = file.song.tracks.first { select(track: first.id, clip: first.clips.first?.id) }
            generationStatus = "Analyzing applied changes…"
            await analyzeAppliedDraft(runID: record.id, before: snapshot, after: analysisSong, selection: request.selection,
                                      prompt: context.messages.last(where: { $0.role == "user" })?.text ?? "", summary: result.summary)
            return
        }
    }
    func appendAssistant(_ text: String, conversationID: UUID) {
        guard let index = file.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var updated = file
        updated.conversations[index].messages.append(ChatMessage(role: "assistant", text: text))
        if (try? ProjectArchive.validateMetadata(updated)) != nil { file = updated }
        else { errorMessage = text }
    }
}
