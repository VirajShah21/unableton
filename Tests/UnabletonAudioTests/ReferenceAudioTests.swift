import Foundation
import Testing
@preconcurrency import AVFAudio
import UnabletonCore
import UnabletonDSP
@testable import UnabletonAudio

@Suite(.serialized)
struct ReferenceAudioTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReferenceAudioTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tone(_ url: URL, seconds: Double = 2, silentPrefix: Double = 0,
                      frequency: Double = 440, amplitude: Double = 0.25) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let frames = Int(seconds * 48_000)
        for offset in stride(from: 0, to: frames, by: 4096) {
            let count = min(4096, frames - offset); buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                let time = Double(offset + i) / 48_000
                let value = time < silentPrefix ? Float(0) : Float(sin(2 * .pi * frequency * time) * amplitude)
                buffer.floatChannelData![0][i] = value; buffer.floatChannelData![1][i] = value
            }
            try file.write(from: buffer)
        }
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test func prepareProviderM4AAndSourceRangeKeepRealAudio() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        try tone(source, silentPrefix: 0.25)
        let metadata = try ReferenceAudioProcessor.inspect(url: source)
        #expect(abs(metadata.duration - 2) < 0.001)
        let provider = try ReferenceAudioProcessor.prepareProviderAudio(source: source, to: folder.appendingPathComponent("provider.m4a"))
        let providerMetadata = try ReferenceAudioProcessor.inspect(url: provider)
        #expect(providerMetadata.byteCount < ReferenceAudioProcessor.maximumProviderBytes)
        #expect(abs(providerMetadata.duration - 2) < 0.1)
        #expect(try read(provider).contains { abs($0) > 0.1 })
        let whole = folder.appendingPathComponent("whole.wav")
        _ = try ReferenceAudioProcessor.renderSegment(source: source, to: whole, startSeconds: 0, durationSeconds: 1)
        let values = try read(whole)
        #expect(values.count == 48_000)
        let first = try #require(values.firstIndex { abs($0) > 0.01 })
        #expect(abs(first - 12_000) < 10)
        let selected = folder.appendingPathComponent("selected.wav")
        let selectedMetadata = try ReferenceAudioProcessor.renderSegment(source: source, to: selected, startSeconds: 0.5, durationSeconds: 0.5)
        #expect(abs(selectedMetadata.duration - 0.5) < 0.0001)
        #expect(try read(selected).prefix(100).contains { abs($0) > 0.1 })
    }

    @Test func tempoMatchingChangesDurationAndPreservesPitch() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav"), output = folder.appendingPathComponent("fast.wav")
        try tone(source)
        let result = try ReferenceAudioProcessor.renderSegment(source: source, to: output, startSeconds: 0,
            durationSeconds: 2, sourceTempo: 120, targetTempo: 180)
        #expect(abs(result.duration - 4.0 / 3) < 0.0001)
        let values = try read(output)
        let lower = 12_000, upper = min(values.count - 1, 48_000)
        let crossings = (lower..<upper).filter { values[$0] <= 0 && values[$0 + 1] > 0 }.count
        let frequency = Double(crossings) / (Double(upper - lower) / 48_000)
        #expect(abs(frequency - 440) < 8)
        let delayedSource = folder.appendingPathComponent("delayed.wav"), delayedOutput = folder.appendingPathComponent("delayed-fast.wav")
        try tone(delayedSource, silentPrefix: 0.3)
        _ = try ReferenceAudioProcessor.renderSegment(source: delayedSource, to: delayedOutput, startSeconds: 0,
            durationSeconds: 2, sourceTempo: 120, targetTempo: 180)
        let first = try #require(read(delayedOutput).firstIndex { abs($0) > 0.01 })
        #expect(abs(first - 9_600) < 1_024)
        #expect(throws: AudioError.self) {
            _ = try ReferenceAudioProcessor.renderSegment(source: source, to: output, startSeconds: 1.5, durationSeconds: 1)
        }
        #expect(throws: AudioError.self) {
            _ = try ReferenceAudioProcessor.renderSegment(source: source, to: output, startSeconds: 0,
                durationSeconds: 1, sourceTempo: 30, targetTempo: 300)
        }
    }

    @Test func nativeAudioFadesAreEqualPowerAndSeekStable() throws {
        let timeline = try #require(ub_timeline_create(48_000, 0, 0, 0, 0))
        defer { ub_timeline_destroy(timeline) }
        let track = try #require(ub_track_create(timeline, UBSynthParameters(), nil, 0))
        defer { ub_track_destroy(track) }
        let values = Array(repeating: Float(0.25), count: 48_000)
        let sample = try values.withUnsafeBufferPointer { buffer in
            try #require(ub_sample_create(buffer.baseAddress, buffer.baseAddress, 48_000, 48_000))
        }
        defer { ub_sample_destroy(sample) }
        ub_track_add_audio_faded(track, sample, 0, 48_000, 0, 12_000, 12_000)
        ub_timeline_begin_render(timeline, 0, 0, 1)
        var left = Array(repeating: Float(0), count: 48_000), right = left
        ub_track_render(track, 0, 48_000, &left, &right)
        #expect(left[0] == 0)
        #expect(abs(left[6_000] - Float(0.25 / sqrt(2))) < 0.00001)
        #expect(left[24_000] == 0.25)
        #expect(left[47_999] == 0)
        var seekLeft = Array(repeating: Float(0), count: 128), seekRight = seekLeft
        ub_track_render(track, 6_000, 128, &seekLeft, &seekRight)
        #expect(abs(seekLeft[0] - left[6_000]) < 0.00001)
    }

    @Test func selectedStemMixKeepsAlignmentAndOriginalLevels() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let sourceA = folder.appendingPathComponent("stem-a.wav"), sourceB = folder.appendingPathComponent("stem-b.wav")
        try tone(sourceA, silentPrefix: 0.25, frequency: 440)
        try tone(sourceB, silentPrefix: 0.5, frequency: 660)
        let first = folder.appendingPathComponent("first.wav"), second = folder.appendingPathComponent("second.wav")
        _ = try ReferenceAudioProcessor.renderSegment(source: sourceA, to: first, startSeconds: 0.125, durationSeconds: 1)
        _ = try ReferenceAudioProcessor.renderSegment(source: sourceB, to: second, startSeconds: 0.125, durationSeconds: 1)
        let mixed = folder.appendingPathComponent("mixed.wav")
        let result = try ReferenceAudioProcessor.renderMix(sources: [sourceA, sourceB], to: mixed,
            startSeconds: 0.125, durationSeconds: 1)
        #expect(result.duration == 1)
        let a = try read(first), b = try read(second), sum = try read(mixed)
        #expect(sum.count == 48_000)
        #expect(sum.indices.allSatisfy { abs(sum[$0] - (a[$0] + b[$0])) < 0.000001 })
        #expect(abs(try #require(sum.firstIndex { abs($0) > 0.01 }) - 6_000) < 10)
        #expect(sum[24_000..<36_000].map { abs($0) }.max()! > 0.4)
        let fast = folder.appendingPathComponent("fast-mix.wav")
        let faster = try ReferenceAudioProcessor.renderMix(sources: [sourceA, sourceB], to: fast,
            startSeconds: 0, durationSeconds: 2, sourceTempo: 120, targetTempo: 180)
        #expect(abs(faster.duration - 4.0 / 3) < 0.0001)
        #expect(try read(fast).contains { abs($0) > 0.1 })
        #expect(throws: AudioError.self) {
            _ = try ReferenceAudioProcessor.renderMix(sources: [sourceA, sourceA], to: mixed,
                startSeconds: 0, durationSeconds: 1)
        }
    }

    @Test func clippingStemMixFailsWithoutPublishingAudio() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.wav"), b = folder.appendingPathComponent("b.wav")
        try tone(a, amplitude: 0.7); try tone(b, amplitude: 0.7)
        let output = folder.appendingPathComponent("clipped.wav")
        #expect(throws: AudioError.self) {
            _ = try ReferenceAudioProcessor.renderMix(sources: [a, b], to: output,
                startSeconds: 0, durationSeconds: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count == 2)
        let result = try ReferenceAudioProcessor.renderMix(sources: [a, b], to: output,
            startSeconds: 0, durationSeconds: 1, gain: 0.5)
        #expect(result.duration == 1)
        let peak = try read(output).map { abs($0) }.max()!
        #expect(abs(peak - 0.7) < 0.0001)
    }

    @Test func offlineRangeUsesOriginalFadeAnchors() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        try tone(source)
        let asset = AudioAsset(fileName: "source.wav", duration: 2, sampleRate: 48_000, channels: 2)
        var clip = Clip(kind: .audio, lengthBeats: 4, assetID: asset.id)
        clip.fadeInBeats = 3; clip.fadeOutBeats = 1
        var song = Song(); song.tempo = 120; song.lengthBars = 1; song.assets = [asset]
        song.tracks = [Track(kind: .audio, volume: 1, parameters: ["reverb": 0, "delay": 0], clips: [clip])]
        let full = folder.appendingPathComponent("full.wav"), prefix = folder.appendingPathComponent("prefix.wav")
        _ = try OfflineRenderer.render(song: song, assets: [asset.id: source], to: full)
        _ = try OfflineRenderer.render(song: song, assets: [asset.id: source], to: prefix, lengthBeats: 2)
        let all = try read(full), selected = try read(prefix)
        #expect(zip(all.prefix(48_000), selected.prefix(48_000)).allSatisfy { abs($0 - $1) < 0.000001 })
        #expect(all[24_000..<48_000].contains { abs($0) > 0.05 })
    }

    @Test func localRhythmReportsInsufficientEvidenceForSilence() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("silence.wav")
        try tone(source, seconds: 2, silentPrefix: 3)
        let result = try ReferenceAudioProcessor.analyze(url: source)
        #expect(result.tempo == nil)
        #expect(result.dropCandidates.isEmpty)
        #expect(!result.warnings.isEmpty)
    }

    @Test func localRhythmMeasuresPulsesAndBassIncrease() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("pulses.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            for offset in stride(from: 0, to: 48_000 * 8, by: 4096) {
                let count = min(4096, 48_000 * 8 - offset); buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count {
                    let time = Double(offset + i) / 48_000, phase = time.truncatingRemainder(dividingBy: 0.5)
                    let envelope = phase < 0.04 ? exp(-phase * 70) : 0
                    let amplitude = time >= 4 ? 0.7 : 0.15
                    let value = Float(sin(2 * .pi * 90 * time) * envelope * amplitude)
                    buffer.floatChannelData![0][i] = value; buffer.floatChannelData![1][i] = -value
                }
                try file.write(from: buffer)
            }
        }
        let result = try ReferenceAudioProcessor.analyze(url: source)
        #expect(abs(try #require(result.tempo) - 120) < 1)
        #expect(result.beatTimesSeconds.count >= 14)
        #expect(result.dropCandidates.contains { abs($0.timeSeconds - 4) <= 0.5 })
    }

    private func sparseWave(_ url: URL, seconds: Int) throws {
        let bytes = seconds * 48_000 * 8
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        append(UInt32(bytes + 36)); data.append(Data("WAVEfmt ".utf8)); append(16)
        append16(3); append16(2); append(48_000); append(48_000 * 8); append16(8); append16(32)
        data.append(Data("data".utf8)); append(UInt32(bytes))
        try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(data.count + bytes))
    }

    @Test func graphPreflightCountsUsedRangesAndDeduplicatesRepeatedAudio() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("long.wav")
        try sparseWave(source, seconds: 600)
        var song = Song(); song.tempo = 120
        let asset = AudioAsset(fileName: "long.wav", duration: 600, sampleRate: 48_000, channels: 2)
        song.assets = [asset]
        song.tracks = [Track(kind: .audio, clips: [
            Clip(kind: .audio, lengthBeats: 2, assetID: asset.id, sourceOffsetSeconds: 100),
            Clip(kind: .audio, startBeat: 4, lengthBeats: 2, assetID: asset.id, sourceOffsetSeconds: 100)])]
        #expect(try AudioMemoryPreflight.validate(song: song, assets: [asset.id: source]) == 48_000 * 8)
        var assets: [UUID: URL] = [:]; song.assets = []; song.tracks = []
        for _ in 0..<3 {
            let id = UUID(); assets[id] = source
            song.assets.append(AudioAsset(id: id, fileName: "long.wav", duration: 600, sampleRate: 48_000, channels: 2))
            song.tracks.append(Track(kind: .audio, clips: [Clip(kind: .audio, lengthBeats: 1200, assetID: id)]))
        }
        #expect(throws: AudioError.self) { try AudioMemoryPreflight.validate(song: song, assets: assets) }
        song.tracks[1].isMuted = true; song.tracks[2].isMuted = true
        #expect(try AudioMemoryPreflight.validate(song: song, assets: assets) == 600 * 48_000 * 8)
    }
}
