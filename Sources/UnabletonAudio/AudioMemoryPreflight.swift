import Foundation
@preconcurrency import AVFAudio
import UnabletonCore

struct AudioSourceRange {
    var startSeconds: Double
    var endSeconds: Double
}

/// The native renderer owns stereo Float32 samples. Preflight the same audible
/// graph and source ranges before any sample buffers are allocated.
public enum AudioMemoryPreflight {
    public static let maximumDecodedBytes = 512 * 1024 * 1024
    public static let maximumPreparationBytes = 768 * 1024 * 1024

    @discardableResult
    public static func validate(song: Song, assets: [UUID: URL]) throws -> Int {
        try ProjectEditor.validate(song)
        let ranges = sourceRanges(song: song)
        var retained = 0, maximumScratch = 0
        for (id, range) in ranges {
            guard let url = assets[id] else { throw AudioError.missingAsset(id) }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = frameRange(file: file, range: range).count
            guard frames >= 0, frames <= 64_000_000 else {
                throw AudioError.unreadableAudio("A selected audio range exceeds 64 million source frames. Shorten the range before playback.")
            }
            let bytes = frames * 2 * MemoryLayout<Float>.size
            let temporary = frames * Int(file.processingFormat.channelCount) * MemoryLayout<Float>.size
            guard temporary <= maximumPreparationBytes, bytes <= maximumDecodedBytes - retained else {
                throw AudioError.unreadableAudio("This arrangement needs more than 512 MiB of decoded audio or 768 MiB during preparation. Shorten the audio ranges or use fewer stems.")
            }
            retained += bytes
            maximumScratch = max(maximumScratch, temporary)
        }
        guard maximumScratch <= maximumPreparationBytes - retained else {
            throw AudioError.unreadableAudio("Audio preparation exceeds its 768 MiB allocation limit. Shorten the audio ranges or use fewer stems.")
        }
        return retained
    }

    static func sourceRanges(song: Song) -> [UUID: AudioSourceRange] {
        let solo = song.tracks.contains(where: \.isSolo)
        var ranges: [UUID: AudioSourceRange] = [:]
        for track in song.tracks where !track.isMuted && (!solo || track.isSolo) {
            for clip in track.clips where clip.kind == .audio {
                guard let id = clip.assetID else { continue }
                let end = clip.sourceOffsetSeconds + clip.lengthBeats * 60 / song.tempo
                if let previous = ranges[id] {
                    ranges[id] = AudioSourceRange(startSeconds: min(previous.startSeconds, clip.sourceOffsetSeconds),
                                                  endSeconds: max(previous.endSeconds, end))
                } else { ranges[id] = AudioSourceRange(startSeconds: clip.sourceOffsetSeconds, endSeconds: end) }
            }
        }
        return ranges
    }

    static func frameRange(file: AVAudioFile, range: AudioSourceRange) -> Range<Int> {
        let rate = file.processingFormat.sampleRate
        let start = Int(min(Double(file.length), max(0, (range.startSeconds * rate).rounded(.down))))
        let end = max(start, Int(min(Double(file.length), max(0, (range.endSeconds * rate).rounded(.up)))))
        return start..<end
    }
}
