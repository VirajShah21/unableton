import Foundation
import CryptoKit

public struct SongAttachment: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var fileName: String
    public var duration: Double
    public var sampleRate: Double
    public var channels: Int
    public var byteCount: Int
    public var sha256: String
    public var analysis: JSONValue?
    public var midi: MIDIImport?
    public var reconstruction: ReferenceReconstruction?

    public init(id: UUID = UUID(), fileName: String, duration: Double, sampleRate: Double, channels: Int, byteCount: Int, sha256: String, analysis: JSONValue? = nil, midi: MIDIImport? = nil, reconstruction: ReferenceReconstruction? = nil) {
        self.id = id; self.fileName = fileName; self.duration = duration; self.sampleRate = sampleRate
        self.channels = channels; self.byteCount = byteCount; self.sha256 = sha256; self.analysis = analysis; self.midi = midi
        self.reconstruction = reconstruction
    }
}

public struct ReferenceAudioDerivation: Codable, Sendable, Equatable {
    public var attachmentID: UUID
    public var stem: String
    public var sourceStartSeconds: Double
    public var sourceEndSeconds: Double
    public var sourceTempo: Double?
    public var targetTempo: Double?
    public var stemNames: [String]?
    public var mixGain: Double?
    public init(attachmentID: UUID, stem: String, sourceStartSeconds: Double, sourceEndSeconds: Double, sourceTempo: Double? = nil, targetTempo: Double? = nil, stemNames: [String]? = nil, mixGain: Double? = nil) {
        self.attachmentID = attachmentID; self.stem = stem
        self.sourceStartSeconds = sourceStartSeconds; self.sourceEndSeconds = sourceEndSeconds
        self.sourceTempo = sourceTempo; self.targetTempo = targetTempo
        self.stemNames = stemNames; self.mixGain = mixGain
    }
}

public enum SongAttachmentLimits {
    public static let maximumPerMessage = 4
    public static let maximumDuration: Double = 600
    public static let maximumSourceBytes = 100 * 1024 * 1024
    public static let maximumRetainedBytes = 1024 * 1024 * 1024
    public static let maximumMetadataBytes = 16 * 1024 * 1024

    public static func validate(_ attachment: SongAttachment) throws {
        guard attachment.fileName == (attachment.fileName as NSString).lastPathComponent,
              !attachment.fileName.isEmpty, attachment.fileName != ".", attachment.fileName != "..",
              attachment.fileName.utf8.count <= 1024,
              attachment.duration.isFinite, attachment.duration > 0, attachment.duration <= maximumDuration,
              attachment.sampleRate.isFinite, (8_000...384_000).contains(attachment.sampleRate),
              (1...32).contains(attachment.channels), (1...maximumSourceBytes).contains(attachment.byteCount),
              attachment.sha256.utf8.count == 64,
              attachment.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProjectError("Invalid song attachment. Songs must be nonempty, at most ten minutes and 100 MiB.")
        }
        if let midi = attachment.midi { try midi.validate(maximumDuration: attachment.duration + 0.25) }
        if let reconstruction = attachment.reconstruction { try reconstruction.validate(maximumDuration: attachment.duration) }
    }

    public static func validate(_ project: ProjectFile) throws {
        var IDs = Set<UUID>(), retained = 0
        for attachment in project.attachments ?? [] {
            try validate(attachment)
            guard IDs.insert(attachment.id).inserted else { throw ProjectError("Duplicate song attachment identifier.") }
            retained += attachment.byteCount
            guard retained <= maximumRetainedBytes else { throw ProjectError("Song attachments exceed the 1 GiB project limit.") }
        }
        for conversation in project.conversations {
            let drafts = conversation.draftAttachmentIDs ?? []
            guard drafts.count <= maximumPerMessage, Set(drafts).count == drafts.count,
                  drafts.allSatisfy({ IDs.contains($0) }) else { throw ProjectError("A chat draft references missing or duplicate song attachments.") }
            for message in conversation.messages {
                let refs = message.attachmentIDs ?? []
                guard refs.count <= maximumPerMessage, Set(refs).count == refs.count,
                      refs.allSatisfy({ IDs.contains($0) }) else { throw ProjectError("A chat references missing or duplicate song attachments.") }
            }
        }
        for asset in project.song.assets {
            if let derivation = asset.referenceDerivation {
                guard IDs.contains(derivation.attachmentID), derivation.sourceStartSeconds.isFinite,
                      derivation.sourceEndSeconds.isFinite, derivation.sourceStartSeconds >= 0,
                      derivation.sourceEndSeconds > derivation.sourceStartSeconds,
                      derivation.sourceEndSeconds <= (project.attachments ?? []).first(where: { $0.id == derivation.attachmentID })!.duration + 0.001,
                      !derivation.stem.isEmpty, derivation.stem.utf8.count <= 120,
                      [derivation.sourceTempo, derivation.targetTempo].allSatisfy({ $0 == nil || ($0!.isFinite && (30...300).contains($0!)) }) else {
                    throw ProjectError("Invalid source-song audio provenance.")
                }
                if let names = derivation.stemNames {
                    guard (1...12).contains(names.count), Set(names).count == names.count,
                          names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }) else {
                        throw ProjectError("Mixed audio provenance must name one to twelve distinct stems.")
                    }
                }
                if let gain = derivation.mixGain, !gain.isFinite || !(0.001...1).contains(gain) {
                    throw ProjectError("Mixed audio provenance requires a finite gain from 0.001 to 1.")
                }
            }
        }
        for clip in project.song.tracks.flatMap(\.clips) {
            if let id = clip.referenceAttachmentID, !IDs.contains(id) { throw ProjectError("A clip references a missing source song.") }
            if let provenance = clip.referenceReconstruction {
                guard clip.kind == .notes, let attachment = project.attachments?.first(where: { $0.id == clip.referenceAttachmentID }) else {
                    throw ProjectError("Reconstructed notes reference a missing source song.")
                }
                try provenance.validate(maximumDuration: attachment.duration)
            }
        }
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
