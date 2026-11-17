import Foundation
import Testing
@testable import UnabletonCore

struct SongAttachmentTests {
    private func fixture() -> (ProjectFile, SongAttachment, Data) {
        var project = ProjectFile()
        let bytes = Data([1, 2, 3, 4])
        let attachment = SongAttachment(fileName: "Song.mp3", duration: 60, sampleRate: 44_100, channels: 2,
                                        byteCount: bytes.count, sha256: SongAttachmentLimits.sha256(bytes))
        project.attachments = [attachment]
        project.conversations[0].messages = [ChatMessage(role: "user", text: "Use this song", attachmentIDs: [attachment.id])]
        return (project, attachment, bytes)
    }

    @Test func referenceOnlyAttachmentRoundTripsWithoutMusicalEdit() throws {
        let (project, attachment, bytes) = fixture()
        #expect(project.song.tracks.isEmpty && project.song.assets.isEmpty)
        let archive = try ProjectArchive.encode(project: project, assets: [attachment.id: bytes])
        let restored = try ProjectArchive.decode(archive)
        #expect(restored.project == project)
        #expect(restored.project.song.revision == 0)
        #expect(restored.assets[attachment.id] == bytes)
        #expect(restored.project.conversations[0].messages[0].attachmentIDs == [attachment.id])
    }

    @Test func legacyMetadataDefaultsToNoAttachmentsAndFades() throws {
        let encoded = try JSONEncoder().encode(ProjectFile())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attachments")
        let project = try JSONDecoder().decode(ProjectFile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(project.attachments == nil)
        #expect(project.conversations[0].draftAttachmentIDs == nil)
        let message = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(ChatMessage(role: "user", text: "Hello")))
        #expect(message.attachmentIDs == nil)
        let clip = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(Clip()))
        #expect(clip.fadeInBeats == nil)
        #expect(clip.referenceAttachmentID == nil)
    }

    @Test func sharedSourceIsStoredOnceAndHashesAreVerified() throws {
        var (project, attachment, bytes) = fixture()
        project.song.assets = [AudioAsset(id: attachment.id, fileName: attachment.fileName, duration: 60, sampleRate: 44_100, channels: 2)]
        let package = try ProjectArchive.encode(project: project, assets: [attachment.id: bytes])
        #expect(package.fileWrappers?["Audio"]?.fileWrappers?.count == 1)
        #expect(throws: ProjectError.self) { try ProjectArchive.encode(project: project, assets: [attachment.id: Data([4, 3, 2, 1])]) }
        let tampered = FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: try JSONEncoder().encode(project)),
            "Audio": FileWrapper(directoryWithFileWrappers: [attachment.id.uuidString: FileWrapper(regularFileWithContents: Data([4, 3, 2, 1]))])
        ])
        #expect(throws: ProjectError.self) { try ProjectArchive.decode(tampered) }
    }

    @Test func missingSourcesAndUnknownChatReferencesAreRejected() throws {
        var (project, attachment, _) = fixture()
        #expect(throws: ProjectError.self) { try ProjectArchive.encode(project: project, assets: [:]) }
        project.conversations[0].messages[0].attachmentIDs = [UUID()]
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
        project.conversations[0].messages[0].attachmentIDs = [attachment.id, attachment.id]
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
    }

    @Test func attachmentDurationAndNamesAreBounded() throws {
        var (_, attachment, _) = fixture()
        attachment.duration = 601
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(attachment) }
        attachment.duration = 60; attachment.fileName = "../song.mp3"
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(attachment) }
        attachment.fileName = "Song.mp3"; attachment.sha256 = "wrong"
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(attachment) }
    }

    @Test func diskStoreAndFileBackedArchiveOwnTheirCopies() throws {
        let (project, attachment, bytes) = fixture()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try bytes.write(to: source)
        let store = try ProjectBlobStore()
        let copy = try store.insert(file: source, id: attachment.id)
        try Data([9, 9]).write(to: source)
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(throws: ProjectError.self) { try store.insert(data: Data([1]), id: attachment.id) }
        let snapshot = store.snapshot()
        let package = try ProjectArchive.encode(project: project, blobURLs: snapshot.urls, lease: snapshot.lease)
        let restoredStore = try ProjectBlobStore()
        let restored = try ProjectArchive.decodeFiles(package, into: restoredStore)
        #expect(restored.project == project)
        #expect(try Data(contentsOf: #require(restored.assets[attachment.id])) == bytes)
    }

    @Test func symbolicAudioEntriesAreRejected() throws {
        let (project, attachment, _) = fixture()
        let data = try JSONEncoder().encode(project)
        let package = FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: data),
            "Audio": FileWrapper(directoryWithFileWrappers: [attachment.id.uuidString: FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/etc/passwd"))])
        ])
        #expect(throws: ProjectError.self) { try ProjectArchive.decode(package) }
    }

    @Test func returnedSaveWrapperKeepsBlobLeaseAfterStoreRelease() async throws {
        let (project, attachment, bytes) = fixture()
        var store: ProjectBlobStore? = try ProjectBlobStore()
        try store?.insert(data: bytes, id: attachment.id)
        let directory = try #require(store?.directory)
        var snapshot: ProjectBlobSnapshot? = store?.snapshot()
        var wrapper: FileWrapper? = try ProjectArchive.encode(project: project, blobURLs: #require(snapshot?.urls), lease: snapshot?.lease)
        snapshot = nil; store = nil
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try ProjectArchive.decode(#require(wrapper)).assets[attachment.id] == bytes)
        wrapper = nil
        for _ in 0..<50 where FileManager.default.fileExists(atPath: directory.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func canceledUnpublishedBlobsCanBeDiscardedWithoutTouchingOtherFiles() throws {
        let store = try ProjectBlobStore(), retainedID = UUID(), canceledID = UUID()
        let retained = try store.insert(data: Data([1, 2]), id: retainedID)
        let canceled = try store.insert(data: Data([3, 4]), id: canceledID)
        try store.discardUnpublished(ids: [canceledID, UUID()])
        #expect(store.snapshot().urls.keys.contains(retainedID))
        #expect(!store.snapshot().urls.keys.contains(canceledID))
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(!FileManager.default.fileExists(atPath: canceled.path))
    }

    @Test func concurrentSameIdentifierCopiesPublishOneImmutableFile() async throws {
        let store = try ProjectBlobStore(), id = UUID(), bytes = Data(repeating: 7, count: 65_536)
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 { group.addTask { try store.insert(data: bytes, id: id) } }
            var result: [URL] = []
            for try await url in group { result.append(url) }
            return result
        }
        #expect(Set(urls).count == 1)
        #expect(store.snapshot().urls.count == 1)
        #expect(try Data(contentsOf: #require(urls.first)) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == [id.uuidString])
    }

    @Test func metadataGuardUsesTheActualPrettyPrintedSaveSize() throws {
        var project = ProjectFile()
        project.conversations[0].messages = [ChatMessage(role: "user", text: "")]
        try ProjectArchive.validateMetadata(project)
        let compactOverhead = try JSONEncoder().encode(project).count
        project.conversations[0].messages[0].text = String(repeating: "x", count: SongAttachmentLimits.maximumMetadataBytes - compactOverhead - 1)
        #expect(try JSONEncoder().encode(project).count < SongAttachmentLimits.maximumMetadataBytes)
        #expect(throws: ProjectError.self) { try ProjectArchive.validateMetadata(project) }
    }

    @Test func mixedStemProvenanceIsBoundedAndBackwardCompatible() throws {
        var (project, attachment, _) = fixture()
        var asset = AudioAsset(fileName: "Instrumental.wav", duration: 1, sampleRate: 48_000, channels: 2)
        asset.referenceDerivation = ReferenceAudioDerivation(attachmentID: attachment.id, stem: "mix", sourceStartSeconds: 0,
            sourceEndSeconds: 1, stemNames: ["Bass", "Drums"], mixGain: 0.5)
        project.song.assets = [asset]
        try SongAttachmentLimits.validate(project)
        let encoded = try JSONEncoder().encode(asset.referenceDerivation)
        let decoded = try JSONDecoder().decode(ReferenceAudioDerivation.self, from: encoded)
        #expect(decoded.stemNames == ["Bass", "Drums"] && decoded.mixGain == 0.5)
        project.song.assets[0].referenceDerivation?.stemNames = ["Drums", "Drums"]
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
        project.song.assets[0].referenceDerivation?.stemNames = (0..<13).map { "Stem \($0)" }
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
        project.song.assets[0].referenceDerivation?.stemNames = [String(repeating: "x", count: 513)]
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
        project.song.assets[0].referenceDerivation?.stemNames = ["Drums"]
        for gain in [Double.nan, Double.infinity, 0, 1.01] {
            project.song.assets[0].referenceDerivation?.mixGain = gain
            #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
        }
        let legacy = ReferenceAudioDerivation(attachmentID: attachment.id, stem: "Vocals", sourceStartSeconds: 0, sourceEndSeconds: 1)
        let legacyDecoded = try JSONDecoder().decode(ReferenceAudioDerivation.self, from: JSONEncoder().encode(legacy))
        #expect(legacyDecoded.stemNames == nil && legacyDecoded.mixGain == nil)
    }

    @Test func unsentDraftAttachmentsRoundTripWithoutChangingMusic() throws {
        var (project, attachment, bytes) = fixture()
        let song = project.song
        project.conversations[0].messages = []
        project.conversations[0].draftAttachmentIDs = [attachment.id]
        let decoded = try ProjectArchive.decode(ProjectArchive.encode(project: project, assets: [attachment.id: bytes]))
        #expect(decoded.project.conversations[0].draftAttachmentIDs == [attachment.id])
        #expect(decoded.project.conversations[0].messages.isEmpty)
        #expect(decoded.project.song == song)
        #expect(decoded.assets[attachment.id] == bytes)
    }

    @Test func invalidDraftAttachmentReferencesAreRejected() throws {
        var (project, attachment, _) = fixture()
        project.conversations[0].draftAttachmentIDs = [UUID()]
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
        project.conversations[0].draftAttachmentIDs = [attachment.id, attachment.id]
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
        var attachments = [attachment]
        for _ in 0..<4 { var extra = attachment; extra.id = UUID(); attachments.append(extra) }
        project.attachments = attachments
        project.conversations[0].draftAttachmentIDs = attachments.map(\.id)
        #expect(throws: ProjectError.self) { try SongAttachmentLimits.validate(project) }
    }
}
