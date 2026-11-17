import AppKit
import AVFAudio
import UniformTypeIdentifiers
import UnabletonCore
import UnabletonAudio

nonisolated func referenceWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: work)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

extension ProjectSession {
    var pendingAttachmentIDs: [UUID] { selectedConversationID.flatMap { composerAttachments[$0] } ?? [] }
    func setPendingAttachments(_ ids: [UUID], conversationID: UUID) {
        composerAttachments[conversationID] = ids
        if let index = file.conversations.firstIndex(where: { $0.id == conversationID }) {
            file.conversations[index].draftAttachmentIDs = ids.isEmpty ? nil : ids
        }
    }
    func attachment(_ id: UUID) -> SongAttachment? { file.attachments?.first { $0.id == id } }
    func attachmentNumber(_ id: UUID, conversation: Conversation? = nil) -> Int {
        let chat = conversation ?? currentConversation
        var ids: [UUID] = []
        for value in (chat?.messages.flatMap { $0.attachmentIDs ?? [] } ?? []) + ((chat?.id).flatMap { composerAttachments[$0] } ?? []) where !ids.contains(value) { ids.append(value) }
        return (ids.firstIndex(of: id) ?? 0) + 1
    }
    func chooseSongAttachments() {
        guard !closed, !attachmentImporting else { return }
        if selectedConversationID == nil { newConversation() }
        guard let origin = selectedConversationID else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach Songs"
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in self?.attachSongs(panel.urls, conversationID: origin) }
        }
        if let window = document.nativeDocument?.windowControllers.first?.window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func attachSongs(_ urls: [URL], conversationID origin: UUID? = nil) {
        guard !closed, !attachmentImporting, !urls.isEmpty else { return }
        if selectedConversationID == nil && origin == nil { newConversation() }
        guard let conversationID = origin ?? selectedConversationID, file.conversations.contains(where: { $0.id == conversationID }) else { return }
        guard (composerAttachments[conversationID]?.count ?? 0) + urls.count <= SongAttachmentLimits.maximumPerMessage else {
            errorMessage = "Attach up to four songs per message."; return
        }
        guard let store = document.blobStore else { errorMessage = "The project audio store is unavailable."; return }
        attachmentImporting = true
        attachmentImportTask = Task { [weak self] in
            defer { self?.attachmentImporting = false; self?.attachmentImportTask = nil }
            for source in urls {
                let id = UUID()
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-Attachment-\(id)", isDirectory: true)
                var adopted = false, published = false
                defer {
                    try? FileManager.default.removeItem(at: staging)
                    if adopted && !published { try? store.discardUnpublished(ids: [id]) }
                }
                do {
                    let prepared = try await referenceWork { () -> (SongAttachment, URL) in
                        let scoped = source.startAccessingSecurityScopedResource()
                        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                        try Task.checkCancellation()
                        let metadata = try ReferenceAudioProcessor.inspect(url: source)
                        // Copy before hashing/decoding again so a changing external
                        // source cannot alter a submitted reference later.
                        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                        let owned = staging.appendingPathComponent("source.\(source.pathExtension)")
                        try FileManager.default.copyItem(at: source, to: owned)
                        let copied = try ReferenceAudioProcessor.inspect(url: owned)
                        let hash = try SongAttachmentLimits.sha256(file: owned)
                        guard metadata.duration == copied.duration, hash == (try SongAttachmentLimits.sha256(file: source)) else { throw ProjectError("The song changed while attaching. Choose the file again.") }
                        let attachment = SongAttachment(id: id, fileName: source.lastPathComponent, duration: copied.duration,
                                                        sampleRate: copied.sampleRate, channels: copied.channels,
                                                        byteCount: copied.byteCount, sha256: hash)
                        try SongAttachmentLimits.validate(attachment)
                        return (attachment, owned)
                    }
                    guard let self, !self.closed, !Task.isCancelled else { return }
                    try self.validateReferenceStorage(adding: [prepared.0.id: prepared.1])
                    _ = try await referenceWork { try store.insert(file: prepared.1, id: id, maximumBytes: SongAttachmentLimits.maximumSourceBytes) }
                    adopted = true
                    guard !self.closed, !Task.isCancelled else { return }
                    try self.validateReferenceStorage(adding: [id: prepared.1])
                    var project = self.file
                    project.attachments = (project.attachments ?? []) + [prepared.0]
                    let draftIDs = (self.composerAttachments[conversationID] ?? []) + [prepared.0.id]
                    guard let conversationIndex = project.conversations.firstIndex(where: { $0.id == conversationID }) else { throw CancellationError() }
                    project.conversations[conversationIndex].draftAttachmentIDs = draftIDs
                    try ProjectArchive.validateMetadata(project)
                    self.document.publishInstalledBlobs()
                    self.assetURLs[prepared.0.id] = self.document.blobURLs[prepared.0.id]
                    self.retainedReferenceIDs.insert(prepared.0.id)
                    self.composerAttachments[conversationID] = draftIDs
                    self.file = project
                    published = true
                } catch is CancellationError { return }
                catch { self?.errorMessage = "Couldn’t attach \(source.lastPathComponent): \(error.localizedDescription)" }
            }
        }
    }
    func removePendingAttachment(_ id: UUID) {
        guard let conversationID = selectedConversationID else { return }
        setPendingAttachments((composerAttachments[conversationID] ?? []).filter { $0 != id }, conversationID: conversationID)
        let inComposer = composerAttachments.values.contains { $0.contains(id) }
        let inHistory = file.conversations.contains { $0.messages.contains { ($0.attachmentIDs ?? []).contains(id) } }
        let inMusic = file.song.assets.contains { $0.referenceDerivation?.attachmentID == id } || file.song.tracks.flatMap(\.clips).contains { $0.referenceAttachmentID == id }
        if !inComposer && !inHistory && !inMusic {
            file.attachments?.removeAll { $0.id == id }
            assetURLs.removeValue(forKey: id)
            // An older in-flight save may still own the source. Its physical
            // bytes remain counted until this document closes.
        }
    }
    func movePendingAttachment(_ id: UUID, by offset: Int) {
        guard let conversationID = selectedConversationID, var ids = composerAttachments[conversationID], let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset); setPendingAttachments(ids, conversationID: conversationID)
    }
    func playAttachment(_ id: UUID) {
        guard !closed, !audio.isRecording, !transcription.isCapturing, let url = assetURLs[id] else { return }
        PlaybackFocus.claim(self); audio.pause(); previewPlayer?.stop()
        do { previewPlayer = try AVAudioPlayer(contentsOf: url); previewPlayer?.play() }
        catch { errorMessage = error.localizedDescription }
    }
    func validateReferenceStorage(adding files: [UUID: URL]) throws {
        let ids = retainedReferenceIDs.union(files.keys)
        let all = document.blobURLs.merging(files) { _, new in new }
        var total = 0
        for id in ids {
            guard let url = all[id], let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += bytes
            guard total <= SongAttachmentLimits.maximumRetainedBytes else { throw ProjectError("Reference songs and retained remix audio exceed 1 GiB. Use shorter source ranges or a new project.") }
        }
    }
}
