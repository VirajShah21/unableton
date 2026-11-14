import Foundation
import AVFAudio
import UnabletonCore
import UnabletonAudio
import UnabletonAI

extension TranscriptionSession {
    func configuration(timeout: Double = 300) async throws -> AgentConfiguration {
        guard let project else { throw CancellationError() }
        let keyProvider = project.keyProvider
        // Security.framework may wait for a user authorization prompt. Keep
        // that synchronous call off the main actor so Cancel and the UI work.
        let lookup = Task.detached { try keyProvider() }
        let savedKey = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
        try Task.checkCancellation()
        guard let key = savedKey, !key.isEmpty else { throw ProjectError("Add an OpenAI key in Settings for Auto-time or accompaniment. Preserve Time with performance layers works offline.") }
        let routing = UserDefaults.standard.string(forKey: "ai.routing") ?? "auto"
        let model = routing == "auto" ? ModelRouting.economicalModel : routing == "custom" ? (UserDefaults.standard.string(forKey: "ai.customModel") ?? "") : (UserDefaults.standard.string(forKey: "ai.model") ?? ModelRouting.economicalModel)
        guard !model.isEmpty else { throw ProjectError("Choose a model in Settings.") }
        return AgentConfiguration(model: model, apiKey: key, reasoningEffort: UserDefaults.standard.string(forKey: "ai.reasoning") ?? "low", timeout: timeout, autoUpgrade: routing == "auto")
    }
    func makePrepared(plan: TranscriptionArrangementPlan, snapshot: Song, transcript: PerformanceTranscript,
                      options: TranscriptionOptions, result: TranscriptionArrangementResult?) throws -> PreparedTranscription {
        guard let take else { throw ProjectError("Record or choose a take first.") }
        let existing = snapshot.assets.first { $0.id == committedSourceID && $0.transcriptionTake?.transcript == transcript }
        let asset = existing ?? AudioAsset(fileName: "\(transcript.mode.displayName)-take.\(take.url.pathExtension)", duration: take.duration, sampleRate: take.sampleRate, channels: take.channels,
                                          transcriptionTake: TranscriptionTake(transcript: transcript, recordedTempo: take.tempo, recordedStartBeat: take.startBeat))
        var commands: [ProjectCommand] = existing == nil ? [.init(op: .addAsset, asset: asset)] : []
        commands += try TranscriptionArrangementBuilder.commands(plan: plan, transcript: transcript, options: options, song: snapshot, sourceAssetID: asset.id)
        var draft = snapshot; try ProjectEditor.apply(commands, to: &draft)
        return PreparedTranscription(revision: snapshot.revision, options: options, transcript: transcript, commands: commands, song: draft, asset: asset, result: result)
    }
    func addToSong() {
        guard transcript != nil, phase == .review, !isWorking, !isCapturing, !alreadyInserted else { return }
        if effectiveOptions.requiresAI && !isPrepared { preview(addAfterPreparing: true) }
        else { insert() }
    }
    func preview(addAfterPreparing: Bool = false, autoplay: Bool = true) {
        guard let project, let transcript, let take, phase == .review, !isWorking, !isCapturing else { return }
        if autoplay && !addAfterPreparing { PlaybackFocus.stopLibraryAudition() }
        if isPrepared, previewReady, let renderedPreviewURL {
            if addAfterPreparing { insert(); return }
            project.previewURL = renderedPreviewURL
            if autoplay { project.playPreview() }
            return
        }
        let options = effectiveOptions
        if options.requiresAI, project.isGenerating { error = "Wait for the current chat generation, then arrange this take."; return }
        operationID = UUID(); let id = operationID
        phase = .arranging; error = nil; status = options.requiresAI ? "Arranging the detected notes…" : "Rendering the detected performance…"
        let arranger = arranger
        operation = Task { [weak self, weak project] in
            guard let self, let project else { return }
            defer { if operationID == id { operation = nil; phase = .review } }
            do {
                if options.requiresAI { status = "Accessing the saved OpenAI key…" }
                var baseConfiguration = options.requiresAI ? try await configuration() : nil
                if let config = baseConfiguration {
                    baseConfiguration?.runBudget = GenerationBudget(maximumRequests: min(32, config.maximumSteps), timeout: config.timeout)
                }
                for attempt in 0...1 {
                    try Task.checkCancellation()
                    try await baseConfiguration?.runBudget?.check()
                    let snapshot = project.file.song
                    let ids = InstrumentResources.requiredIDs(in: snapshot).union(options.layers.map(\.instrumentID))
                    let resources = try await SoundLibraryStore.shared.resources(for: ids, automatic: options.requiresAI, budget: baseConfiguration?.runBudget, status: { [weak self] text in
                        Task { @MainActor in if self?.operationID == id { self?.status = text } }
                    })
                    try Task.checkCancellation()
                    let result: TranscriptionArrangementResult?
                    let plan: TranscriptionArrangementPlan
                    if options.requiresAI {
                        guard let config = baseConfiguration else { throw ProjectError("OpenAI configuration is missing.") }
                        result = try await arranger.arrange(request: .init(transcript: transcript, options: options, song: snapshot), configuration: config, status: { [weak self] text in
                            Task { @MainActor in if self?.operationID == id { self?.status = text } }
                        })
                        plan = result!.plan
                    } else { result = nil; plan = TranscriptionArrangementPlan() }
                    try Task.checkCancellation()
                    try await baseConfiguration?.runBudget?.check()
                    guard operationID == id, !project.closed else { return }
                    if project.file.song.revision != snapshot.revision {
                        if attempt == 0 { status = "Updating for the song's latest edits…"; continue }
                        throw ProjectError("The song changed again. Your take is safe; preview it again when ready.")
                    }
                    let prepared = try makePrepared(plan: plan, snapshot: snapshot, transcript: transcript, options: options, result: result)
                    let output = project.cacheURL.appendingPathComponent("Transcription-preview-\(UUID()).wav")
                    var assets = project.assetURLs; assets[prepared.asset.id] = take.url
                    let draft = prepared.song, from = options.insertionBeat
                    let length = draft.tracks.suffix(options.layers.count).flatMap(\.clips).map(\.lengthBeats).max() ?? options.targetLengthBeats
                    let renderAssets = assets
                    let render = Task.detached(priority: .userInitiated) { try OfflineRenderer.render(song: draft, assets: renderAssets, to: output, fromBeat: from, lengthBeats: length, resources: resources) }
                    let budget = baseConfiguration?.runBudget
                    let report = try await withTaskCancellationHandler {
                        try await withThrowingTaskGroup(of: RenderReport.self) { group in
                            group.addTask {
                                try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
                            }
                            if let budget { group.addTask { try await budget.waitUntilExpired() } }
                            defer { group.cancelAll() }
                            guard let result = try await group.next() else { throw CancellationError() }
                            return result
                        }
                    } onCancel: { render.cancel() }
                    try Task.checkCancellation()
                    try await baseConfiguration?.runBudget?.check()
                    guard operationID == id, !project.closed else { return }
                    guard project.file.song.revision == snapshot.revision else {
                        if attempt == 0 { continue }
                        throw ProjectError("The song changed during preview. Preview again before inserting.")
                    }
                    self.prepared = prepared; renderedPreviewURL = output; previewReady = true
                    status = "\(plan.summary) Preview: \(report.clippedSamples == 0 ? "no clipping" : "\(report.clippedSamples) clipped samples")."
                    if addAfterPreparing {
                        // One explicit Add action may prepare AI work and then
                        // commit it. insert() revalidates revision/options and
                        // installs a new operation ID before this task exits.
                        phase = .review
                        insert()
                        return
                    }
                    project.previewURL = output
                    if autoplay { project.playPreview() }
                    return
                }
            } catch is CancellationError { if operationID == id { status = "Canceled. The take and song were kept." } }
            catch { if operationID == id { self.error = error.localizedDescription } }
        }
    }
    func insert() {
        guard let project, let transcript, let take, phase == .review, !isWorking, !isCapturing else { return }
        guard !alreadyInserted else { return }
        do {
            if !isPrepared {
                guard !effectiveOptions.requiresAI else { throw ProjectError("Arrange and preview these settings before inserting." ) }
                prepared = try makePrepared(plan: .init(), snapshot: project.file.song, transcript: transcript, options: effectiveOptions, result: nil)
            }
            guard let prepared else { return }
            operationID = UUID(); let id = operationID
            phase = .inserting; error = nil
            operation = Task { [weak self, weak project] in
                guard let self, let project else { return }
                defer { if operationID == id { operation = nil; phase = .review } }
                do {
                    let resources = try await SoundLibraryStore.shared.resources(for: Set(prepared.options.layers.map(\.instrumentID)))
                    let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: take.url) }.value
                    defer { withExtendedLifetime(resources) {} }
                    try Task.checkCancellation()
                    guard operationID == id, !project.closed else { return }
                    guard isPrepared, project.file.song.revision == prepared.revision else { throw ProjectError("The song or transcription settings changed. Preview again before inserting.") }
                    let before = project.file.song
                    var after = before; try ProjectEditor.apply(prepared.commands, to: &after)
                    var additions = after; additions.tracks.removeAll { track in before.tracks.contains { $0.id == track.id } }
                    try InstrumentResources.validatePlayback(in: additions)
                    // Bytes are ready and all commands validated before the first document mutation.
                    project.assetData[prepared.asset.id] = data
                    project.assetURLs[prepared.asset.id] = take.url
                    var generationID: UUID?
                    if let result = prepared.result {
                        var conversation = Conversation(title: "Transcribe: \(transcript.mode.displayName)")
                        conversation.messages = [.init(role: "user", text: "\(transcript.mode.displayName) take · \(prepared.options.timing.displayName) · \(prepared.options.layers.count) layers. \(prepared.options.instructions)")]
                        var record = GenerationRecord(conversationID: conversation.id, model: result.model, summary: result.plan.summary, baseRevision: before.revision, appliedRevision: before.revision + 1, inputTokens: result.inputTokens, outputTokens: result.outputTokens, routingReason: result.routingReason, attemptedModels: result.attemptedModels)
                        record.generationRequests = result.generationRequests
                        record.transientRetries = result.transientRetries
                        generationID = record.id
                        conversation.messages.append(.init(role: "assistant", text: result.plan.summary + (result.routingReason.map { "\n\nModel upgrade: \($0)" } ?? ""), runID: record.id))
                        project.file.conversations.append(conversation); project.file.generations.append(record)
                        project.selectedConversationID = conversation.id
                    }
                    project.commit(after, replacing: before, name: "Transcribe \(transcript.mode.displayName)", generationID: generationID)
                    if let first = after.tracks.first(where: { track in !before.tracks.contains(where: { $0.id == track.id }) }) {
                        project.selection = ProjectSelection(trackID: first.id, clipID: first.clips.first?.id)
                        project.arrangementReveal = ArrangementRevealRequest(trackID: first.id, beat: first.clips.first?.startBeat ?? prepared.options.insertionBeat)
                    }
                    committedSourceID = prepared.asset.id; inserted = true; self.prepared = nil; previewReady = false
                    lastInsertedOptions = prepared.options; lastInsertedTranscript = transcript
                    lastInsertedSourceURL = take.url
                    lastInsertedTrackIDs = Set(after.tracks.map(\.id)).subtracting(before.tracks.map(\.id))
                    let count = prepared.options.layers.count
                    status = "Added \(count) \(count == 1 ? "track" : "tracks") at \(TrackColors.position(prepared.options.insertionBeat, beatsPerBar: after.beatsPerBar)). Play in Song to hear the result. Undo removes this addition."
                    project.notice = status
                    if let generationID, let result = prepared.result {
                        var observed = after; observed.revision = before.revision + 1
                        await project.analyzeAppliedDraft(runID: generationID, before: before, after: observed,
                            selection: ProjectSelection(startBeat: prepared.options.insertionBeat, endBeat: prepared.options.insertionBeat + prepared.options.targetLengthBeats),
                            prompt: "Transcribe \(transcript.mode.displayName), \(prepared.options.timing.displayName), requested layers: \(prepared.options.layers.map { $0.role.rawValue }.joined(separator: ", ")). \(prepared.options.instructions)",
                            summary: result.plan.summary)
                    }
                } catch { if operationID == id { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func revealInSong() {
        guard let project, let first = project.file.song.tracks.first(where: { lastInsertedTrackIDs.contains($0.id) }),
              let clip = first.clips.first else { return }
        project.selection = ProjectSelection(trackID: first.id, clipID: clip.id)
        project.arrangementReveal = ArrangementRevealRequest(trackID: first.id, beat: clip.startBeat)
    }
    func playInSong() {
        guard let project, alreadyInserted else { return }
        revealInSong()
        PlaybackFocus.claim(project); project.previewPlayer?.stop()
        let start = project.arrangementReveal?.beat ?? effectiveOptions.insertionBeat
        project.audio.seek(to: start)
        rehearsing = false
        // Hear the added part with the song even if capture was Solo or
        // Silent, and without an unrelated loop hiding its destination.
        project.preparePlayback(audition: .accompaniment)
    }
}
