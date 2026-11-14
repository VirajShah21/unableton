import Foundation
import AVFAudio
import Testing
import UnabletonCore
import UnabletonAudio

@Suite(.serialized)
struct VocalRenderTests {
    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    @Test func vocalScoreRestsAlignWithMelodyAndPreserveTheInstrumentStem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-Vocal-Render-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("vocal.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let channel = try #require(buffer.floatChannelData?[0])
        // This fixture stands in for a provider take: half a beat of silence,
        // then half a beat of sung audio, with the score's trailing rest intact.
        for frame in 0..<48_000 {
            channel[frame] = (12_000..<24_000).contains(frame) ? Float(sin(Double(frame - 12_000) * 2 * .pi * 440 / 48_000)) * 0.2 : 0
        }
        do {
            let writer = try AVAudioFile(forWriting: source, settings: format.settings)
            try writer.write(from: buffer)
        }
        var original = Song(); original.tempo = 120; original.lengthBars = 1
        let melody = Clip(name: "Melody", startBeat: 2, lengthBeats: 2, notes: [NoteEvent(pitch: 69, startBeat: 0.5, duration: 0.5)])
        let cleanSound: [String: Double] = ["oscillator": 0, "attack": 0.001, "decay": 0.01, "sustain": 0.7, "release": 0.01, "cutoff": 20_000, "drive": 0, "detune": 0, "lfoDepth": 0, "reverb": 0, "delay": 0]
        original.tracks = [Track(name: "Existing melody", instrumentID: "synth.lead", volume: 0.4, parameters: cleanSound, clips: [melody])]
        let score = try VocalScore.make(clip: melody, tempo: original.tempo, beatsPerBar: original.beatsPerBar, lyrics: ["Hey"])
        let asset = AudioAsset(fileName: "vocal.wav", duration: 1, sampleRate: 48_000, channels: 1,
                               vocalTake: VocalTake(provider: "fixture", singerID: "Test", sourceClipID: melody.id, score: score))
        let voice = Track(name: "Vocals", kind: .audio, volume: 0.7, parameters: ["cutoff": 20_000, "drive": 0, "delay": 0, "reverb": 0])
        var withVocals = original
        try ProjectEditor.apply([
            .init(op: .addTrack, track: voice),
            .init(op: .addClip, trackID: voice.id, clip: Clip(kind: .audio, startBeat: melody.startBeat, lengthBeats: score.lengthBeats, assetID: asset.id), asset: asset)
        ], to: &withVocals)
        #expect(withVocals.tracks[0] == original.tracks[0])
        let baselineURL = directory.appendingPathComponent("baseline.wav")
        let baselineReport = try OfflineRenderer.render(song: original, assets: [:], to: baselineURL)
        var melodyOnly = withVocals; melodyOnly.tracks[1].isMuted = true
        let unchangedURL = directory.appendingPathComponent("melody.wav")
        _ = try OfflineRenderer.render(song: melodyOnly, assets: [asset.id: source], to: unchangedURL)
        let baseline = try read(baselineURL), unchanged = try read(unchangedURL)
        #expect(unchanged.count >= baseline.count)
        #expect(zip(baseline, unchanged).allSatisfy { abs($0 - $1) < 0.000001 })
        let expectedOnset = 60_000 // (global beat 2 + relative beat 0.5) at 120 BPM.
        let melodyOnset = try #require(baseline.firstIndex { abs($0) > 0.00001 })
        #expect((expectedOnset..<expectedOnset + 100).contains(melodyOnset))
        var voiceOnly = withVocals; voiceOnly.tracks[0].isMuted = true
        let voiceURL = directory.appendingPathComponent("voice.wav")
        let voiceReport = try OfflineRenderer.render(song: voiceOnly, assets: [asset.id: source], to: voiceURL)
        let vocalSamples = try read(voiceURL)
        let vocalOnset = try #require(vocalSamples.firstIndex { abs($0) > 0.00001 })
        #expect((expectedOnset..<expectedOnset + 3).contains(vocalOnset))
        #expect(!baselineReport.silent && !voiceReport.silent)
        let mixed = try OfflineRenderer.render(song: withVocals, assets: [asset.id: source], to: directory.appendingPathComponent("mix.wav"))
        #expect(!mixed.silent && mixed.clippedSamples == 0)
        let seekURL = directory.appendingPathComponent("vocal-seek.wav")
        _ = try OfflineRenderer.render(song: voiceOnly, assets: [asset.id: source], to: seekURL, fromBeat: 2, lengthBeats: 2)
        let seekSamples = try read(seekURL)
        let seekOnset = try #require(seekSamples.firstIndex { abs($0) > 0.00001 })
        #expect((12_000..<12_003).contains(seekOnset))
    }
}
