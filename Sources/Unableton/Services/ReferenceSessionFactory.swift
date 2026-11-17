import Foundation
import AVFAudio
import UnabletonAI
import UnabletonCore
import UnabletonAudio

extension ProjectSession {
    func referenceTools(for request: QueuedPrompt, budget: GenerationBudget, openAIKey: String) -> ReferenceTools? {
        guard let chat = file.conversations.first(where: { $0.id == request.conversationID }),
              let cutoff = chat.messages.firstIndex(where: { $0.id == request.messageID }) else { return nil }
        var ids: [UUID] = []
        for id in chat.messages.prefix(through: cutoff).flatMap({ $0.attachmentIDs ?? [] }) where !ids.contains(id) { ids.append(id) }
        let attachments = ids.compactMap { attachment($0) }
        guard !attachments.isEmpty else { return nil }
        let runtime = SongReferenceRuntime(attachments: attachments, sources: assetURLs.filter { ids.contains($0.key) },
            directory: cacheURL.appendingPathComponent("ReferenceDraft-\(budget.runID)", isDirectory: true), budget: budget,
            processor: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.makeReferenceProcessor()
            }, inspector: OpenAIAudioInspection(apiKey: openAIKey, authorize: {
                guard ReferencePrivacyPreferences.allowsAudioInspection(in: .standard) else { throw ReferenceProcessingFailure("OpenAI audio inspection was disabled before upload. No audio was sent.") }
            }, authorizeUpload: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.authorizeReferenceUpload()
            }), lease: document.blobStore?.snapshot().lease,
            allowsAudioInspection: ReferencePrivacyPreferences.allowsAudioInspection(in: .standard),
            vocalNotesUserPrompt: chat.messages[cutoff].role == "user" ? chat.messages[cutoff].text : "",
            update: { [weak self] id, analysis, midi in
                try await MainActor.run {
                    guard let self, !self.closed, let index = self.file.attachments?.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    var project = self.file
                    if let analysis { project.attachments?[index].analysis = analysis }
                    if let midi { project.attachments?[index].midi = midi }
                    try ProjectArchive.validateMetadata(project)
                    self.file = project
                }
            }, updateReconstruction: { [weak self] id, reconstruction in
                try await MainActor.run {
                    guard let self, !self.closed, let index = self.file.attachments?.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    var project = self.file
                    project.attachments?[index].reconstruction = reconstruction
                    try ProjectArchive.validateMetadata(project)
                    self.file = project
                }
            }, fittingResources: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.referenceSoundResources()
            }, status: { [weak self] id, value in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    self.attachmentStatus[id] = value; self.generationStatus = value
                }
            })
        return runtime.tools()
    }
    func makeReferenceProcessor() async throws -> ReferenceProcessing {
        guard !closed else { throw CancellationError() }
        if let referenceProcessing { return referenceProcessing }
        let engine = LocalReferenceProvider.makeEngine()
        let directory = cacheURL.appendingPathComponent("ReferenceProcessing-\(UUID())", isDirectory: true)
        let provider = LocalReferenceProvider(engine: engine, status: { [weak self] text in
            Task { @MainActor in if let self, !self.closed { self.generationStatus = text } }
        })
        let processing = ReferenceProcessing(provider: provider, directory: directory, prepare: { source, output in
            try await referenceWork {
                let file = try AVAudioFile(forReading: source)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                _ = try ReferenceAudioProcessor.renderSegment(source: source, to: output, startSeconds: 0, durationSeconds: duration)
                return output
            }
        })
        referenceProcessing = processing
        return processing
    }
    func referenceSoundResources() async throws -> InstrumentResources {
        guard !closed else { throw CancellationError() }
        let installed = await SoundLibraryStore.shared.installedIDs()
        let resources = try await SoundLibraryStore.shared.existingResources(for: installed)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return resources
    }
    func authorizeReferenceUpload() throws {
        guard !closed else { throw CancellationError() }
        guard ReferencePrivacyPreferences.allowsAudioInspection(in: .standard) else { throw ReferenceProcessingFailure("OpenAI audio inspection was disabled before upload. No audio was sent.") }
    }
    func retryReferenceProcessing(_ id: UUID) {
        guard let attachment = attachment(id), let referenceProcessing else { return }
        Task {
            do {
                try await referenceProcessing.retryFailed(sha256: attachment.sha256)
                guard !closed else { return }
                attachmentStatus[id] = "Ready to retry when you send a prompt"
            } catch { if !closed { errorMessage = error.localizedDescription } }
        }
    }
}
