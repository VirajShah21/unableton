import Foundation

/// Immutable, preflighted resources. Holding the owner keeps installed banks
/// leased for the lifetime of a graph or offline render.
public struct InstrumentResources: Sendable {
    public let urls: [String: URL]
    private let owner: (any Sendable)?
    public static let empty = InstrumentResources(urls: [:])
    public init(urls: [String: URL], owner: (any Sendable)? = nil) {
        self.urls = urls; self.owner = owner
    }
    public static func requiredIDs(in song: Song) -> Set<String> {
        let solo = song.tracks.contains(where: \.isSolo)
        return Set(song.tracks.filter { $0.kind == .instrument && !$0.isMuted && (!solo || $0.isSolo) }.map(\.instrumentID))
    }
    /// Legacy project identities remain valid even when Apple's sampler cannot
    /// render some source-bank regions. Never silently omit those notes.
    public static func validatePlayback(in song: Song) throws {
        let solo = song.tracks.contains(where: \.isSolo)
        for track in song.tracks where track.kind == .instrument && !track.isMuted && (!solo || track.isSolo) {
            guard let preset = InstrumentCatalog.preset(id: track.instrumentID),
                  let unavailable = preset.unrenderablePitches, !unavailable.isEmpty else { continue }
            let used = Set(track.clips.filter { $0.kind == .notes }.flatMap { clip in
                clip.notes.filter { $0.startBeat < clip.lengthBeats && $0.duration > 0 }.map(\.pitch)
            }).intersection(unavailable)
            if !used.isEmpty {
                throw ProjectError("\(preset.name) cannot render MIDI notes \(used.sorted().map(String.init).joined(separator: ", ")) with the native sampler. This source-bank limitation was found during validation. Choose another instrument; the song's notes have been preserved.")
            }
        }
    }
}

public struct MissingInstruments: LocalizedError, Sendable, Equatable {
    public let ids: Set<String>
    public init(_ ids: Set<String>) { self.ids = ids }
    public var errorDescription: String? {
        "Download required sounds: " + ids.sorted().map { InstrumentCatalog.preset(id: $0)?.name ?? $0 }.joined(separator: ", ") + ". Open Sound Library to install them."
    }
}
