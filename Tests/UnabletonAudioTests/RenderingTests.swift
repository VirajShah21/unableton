import Foundation
import Testing
@preconcurrency import AVFAudio
import UnabletonCore
import UnabletonDSP
import Darwin
@testable import UnabletonAudio

@Suite(.serialized)
struct RenderingTests {
    private func song(start: Double = 0) -> Song {
        var song = Song(); song.tempo = 120; song.lengthBars = 1
        song.tracks = [Track(instrumentID: "synth.lead", parameters: ["oscillator": 0, "attack": 0.001, "decay": 0.01, "sustain": 0.7, "release": 0.01, "cutoff": 20_000, "drive": 0, "detune": 0, "reverb": 0, "delay": 0], clips: [Clip(lengthBeats: 4, notes: [NoteEvent(pitch: 69, startBeat: start, duration: 0.5)])])]
        return song
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test func synthExportsRealStereoAudioWithTails() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("synth.wav")
        let report = try OfflineRenderer.render(song: song(), assets: [:], to: output)
        #expect(report.peak > 0.01)
        #expect(report.rms > 0.001)
        #expect(!report.silent)
        #expect(report.clippedSamples == 0)
        let file = try AVAudioFile(forReading: output)
        #expect(file.processingFormat.channelCount == 2)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(report.duration > 4)
    }

    @Test func notePlacementAndSeekUseSampleFrames() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("offset.wav")
        _ = try OfflineRenderer.render(song: song(start: 1), assets: [:], to: output)
        let values = try read(output)
        let first = try #require(values.firstIndex(where: { abs($0) > 0.0001 }))
        #expect(first >= 24_000)
        #expect(first < 24_100)
        let seek = directory.appendingPathComponent("seek.wav")
        _ = try OfflineRenderer.render(song: song(start: 1), assets: [:], to: seek, fromBeat: 1, lengthBeats: 1)
        let seekValues = try read(seek)
        #expect(try #require(seekValues.firstIndex(where: { abs($0) > 0.0001 })) < 100)
    }

    @Test func audioImpulsesMixAtExactClipPositions() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("impulse.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
            buffer.floatChannelData![1].initialize(repeating: 0, count: 4800)
            buffer.floatChannelData![0][0] = 0.5; buffer.floatChannelData![1][0] = 0.5
            try file.write(from: buffer)
        }
        let asset = UUID()
        var song = Song(); song.tempo = 120; song.lengthBars = 1
        song.assets = [AudioAsset(id: asset, fileName: "impulse.wav", duration: 0.1, sampleRate: 48_000, channels: 2)]
        song.tracks = [Track(name: "Audio", kind: .audio, volume: 1, parameters: ["cutoff": 20_000, "reverb": 0, "delay": 0], clips: [Clip(kind: .audio, startBeat: 1, lengthBeats: 1, assetID: asset)])]
        let output = directory.appendingPathComponent("mixed.wav")
        let report = try OfflineRenderer.render(song: song, assets: [asset: source], to: output)
        #expect(!report.silent)
        let samples = try read(output)
        let first = try #require(samples.firstIndex(where: { abs($0) > 0.0001 }))
        #expect(first == 24_000)
    }

    @Test func rangeExportExcludesLaterNotesFromEffectTail() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let report = try OfflineRenderer.render(song: song(start: 2), assets: [:], to: directory.appendingPathComponent("range.wav"), fromBeat: 0, lengthBeats: 1)
        #expect(report.silent)
    }

    @Test func muteAndMissingAssetsAreExplicit() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var muted = song(); muted.tracks[0].isMuted = true
        #expect(try OfflineRenderer.render(song: muted, assets: [:], to: directory.appendingPathComponent("muted.wav")).silent)
        let asset = UUID()
        var missing = song(); missing.assets = [AudioAsset(id: asset, fileName: "missing.wav", duration: 1, sampleRate: 48_000, channels: 2)]
        missing.tracks = [Track(kind: .audio, clips: [Clip(kind: .audio, assetID: asset)])]
        #expect(throws: AudioError.self) { try OfflineRenderer.render(song: missing, assets: [:], to: directory.appendingPathComponent("missing.wav")) }
    }

    @Test func samplerUsesExplicitResourceSnapshotWithoutInstalledFactoryFiles() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bank = directory.appendingPathComponent("fixture.sf2")
        try SoundFontFixture.write(to: bank)
        var sampled = song(start: 1); sampled.tracks[0].instrumentID = "sampled.piano"
        sampled.tracks[0].parameters = ["cutoff": 20_000, "drive": 0, "reverb": 0, "delay": 0]
        let output = directory.appendingPathComponent("sampled.wav")
        let report = try OfflineRenderer.render(song: sampled, assets: [:], to: output,
            resources: InstrumentResources(urls: ["sampled.piano": bank]))
        #expect(!report.silent)
        #expect(report.peak > 0.001)
        let values = try read(output)
        let first = try #require(values.firstIndex(where: { abs($0) > 0.0001 }))
        #expect(first >= 24_000)
        #expect(first < 24_500)
        // Resource discovery must not fall back to a checkout cache or bundle.
        #expect(throws: MissingInstruments.self) {
            try OfflineRenderer.render(song: sampled, assets: [:], to: directory.appendingPathComponent("missing.wav"))
        }
    }

    @Test func samplerDriveAppliesToCatalogBanksRegardlessOfIdentifierPrefix() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bank = directory.appendingPathComponent("fixture.sf2")
        try SoundFontFixture.write(to: bank)
        let ids = ["sampled.piano", "freepats.synthbasslead"]
        let resources = InstrumentResources(urls: Dictionary(uniqueKeysWithValues: ids.map { ($0, bank) }))
        var rendered: [String: [Float]] = [:]
        for id in ids {
            for drive in [0.0, 1.0] {
                var sampled = song()
                sampled.tracks[0].instrumentID = id
                sampled.tracks[0].parameters = ["cutoff": 20_000, "drive": drive, "reverb": 0, "delay": 0]
                let key = "\(id)-\(drive)"
                let output = directory.appendingPathComponent(key + ".wav")
                let report = try OfflineRenderer.render(song: sampled, assets: [:], to: output, resources: resources)
                #expect(!report.silent && report.clippedSamples == 0)
                rendered[key] = try read(output)
            }
        }
        func difference(_ lhs: String, _ rhs: String) throws -> Double {
            let a = try #require(rendered[lhs]), b = try #require(rendered[rhs])
            #expect(a.count == b.count)
            return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        }
        #expect(try difference("freepats.synthbasslead-0.0", "freepats.synthbasslead-1.0") > 0.0001)
        #expect(try difference("sampled.piano-0.0", "sampled.piano-1.0") > 0.0001)
        // The fixture is identical. A label must not decide whether its drive works.
        #expect(try difference("sampled.piano-1.0", "freepats.synthbasslead-1.0") < 0.00001)
    }

    @Test func missingSoundPreflightReportsAllAudibleDependenciesTogether() throws {
        var missing = song()
        missing.tracks[0].instrumentID = "sampled.piano"
        missing.tracks[0].parameters = [:]
        missing.tracks.append(Track(instrumentID: "sampled.guitar"))
        missing.tracks.append(Track(instrumentID: "sampled.piano"))
        do {
            _ = try NativeGraph(song: missing, assets: [:])
            Issue.record("Expected missing sound dependencies")
        } catch let failure as MissingInstruments {
            #expect(failure.ids == ["sampled.piano", "sampled.guitar"])
        }
        missing.tracks[0].isMuted = true
        missing.tracks[1].isMuted = true
        missing.tracks[2].isMuted = true
        _ = try NativeGraph(song: missing, assets: [:])
        missing.tracks[0].isMuted = false
        var solo = Track(instrumentID: "synth.lead"); solo.isSolo = true
        missing.tracks.append(solo)
        #expect(InstrumentResources.requiredIDs(in: missing) == ["synth.lead"])
        _ = try NativeGraph(song: missing, assets: [:])
    }

    @Test func silentTimelineAndSoloDoNotResolveMissingAccompaniment() throws {
        var missing = song(); missing.tracks[0].instrumentID = "sampled.piano"; missing.tracks[0].parameters = [:]
        for audition in [TranscriptionAudition.visualOnly, .solo] {
            let graph = try NativeGraph.transcription(song: missing, assets: [:], fromBeat: 2, audition: audition)
            #expect(graph.currentBeat == 2)
            #expect(graph.engine.mainMixerNode.outputVolume == 0)
        }
        #expect(throws: MissingInstruments.self) {
            try NativeGraph.transcription(song: missing, assets: [:], fromBeat: 2, audition: .accompaniment)
        }
    }

    @Test func samplerSynthAndAudioShareFrameScheduleAcrossBufferSizes() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bank = directory.appendingPathComponent("fixture.sf2")
        try SoundFontFixture.write(to: bank)
        let source = directory.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for frame in 0..<4800 {
                let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.3)
                buffer.floatChannelData![0][frame] = value; buffer.floatChannelData![1][frame] = value
            }
            try file.write(from: buffer)
        }
        let asset = AudioAsset(fileName: "tone.wav", duration: 0.1, sampleRate: 48_000, channels: 2)
        var combined = song(start: 1)
        combined.tracks[0].clips[0].notes[0].duration = 0.1
        combined.tracks.append(Track(instrumentID: "sampled.piano", parameters: ["cutoff": 20_000, "drive": 0, "reverb": 0, "delay": 0],
            clips: [Clip(lengthBeats: 4, notes: [NoteEvent(pitch: 69, startBeat: 2, duration: 0.1)])]))
        combined.assets = [asset]
        combined.tracks.append(Track(kind: .audio, parameters: ["cutoff": 20_000, "drive": 0, "reverb": 0, "delay": 0],
            clips: [Clip(kind: .audio, startBeat: 3, lengthBeats: 0.2, assetID: asset.id)]))
        for count in [64, 257, 1024] {
            let graph = try NativeGraph(song: combined, assets: [asset.id: source], resources: InstrumentResources(urls: ["sampled.piano": bank]))
            try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: AVAudioFrameCount(count))
            try graph.engine.start()
            defer { graph.engine.stop() }
            let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: AVAudioFrameCount(count))!
            var values: [Float] = []
            while values.count < 80_000 {
                let status = try graph.engine.renderOffline(AVAudioFrameCount(count), to: buffer)
                #expect(status == .success)
                guard status == .success else { break }
                values.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            #expect(values.count >= 80_000)
            guard values.count >= 80_000 else { continue }
            for (kind, frame) in [("synth", 24_000), ("sampler", 48_000), ("audio", 72_000)] {
                #expect(values[(frame - 1024)..<frame].allSatisfy { abs($0) < 0.0001 }, "\(kind), buffer \(count): no early onset")
                let first = try #require(values[frame..<(frame + 500)].firstIndex { abs($0) > 0.0001 })
                #expect(first - frame < 100, "\(kind), buffer \(count): onset aligns to the shared schedule")
            }
        }
    }

    @Test func loopedNotesRepeatAtStableFramePositions() throws {
        var song = song(start: 0.25); song.loopEnabled = true; song.loopStart = 0; song.loopEnd = 1
        let graph = try NativeGraph(song: song, assets: [:], looping: true)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 512)
        try graph.engine.start(); defer { graph.engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 512)!
        var samples: [Float] = []
        for _ in 0..<96 {
            _ = try graph.engine.renderOffline(512, to: buffer)
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let first = try #require(samples[0..<24_000].firstIndex { abs($0) > 0.0001 })
        let second = try #require(samples[24_000..<48_000].firstIndex { abs($0) > 0.0001 })
        #expect(second - first == 24_000)
    }

    @Test func recordingRingStopsAtOverflowWithoutCondensingTime() throws {
        let ring = try #require(ub_record_ring_create(1, 4, 2)); defer { ub_record_ring_destroy(ring) }
        var one: [Float] = [1, 2, 3, 4], two: [Float] = [5, 6, 7, 8]
        one.withUnsafeBufferPointer { #expect(ub_record_ring_push(ring, $0.baseAddress, $0.baseAddress, 4) == 1) }
        two.withUnsafeBufferPointer { #expect(ub_record_ring_push(ring, $0.baseAddress, $0.baseAddress, 4) == 1) }
        one.withUnsafeBufferPointer { #expect(ub_record_ring_push(ring, $0.baseAddress, $0.baseAddress, 4) == 0) }
        #expect(ub_record_ring_overflowed(ring) == 1)
        var count: UInt32 = 0
        one.withUnsafeMutableBufferPointer { #expect(ub_record_ring_pop(ring, $0.baseAddress, $0.baseAddress, &count) == 1) }
        two.withUnsafeMutableBufferPointer { #expect(ub_record_ring_pop(ring, $0.baseAddress, $0.baseAddress, &count) == 1) }
        #expect(one == [1, 2, 3, 4]); #expect(two == [5, 6, 7, 8])
        one.withUnsafeBufferPointer { #expect(ub_record_ring_push(ring, $0.baseAddress, $0.baseAddress, 4) == 0) }
    }

    @Test func recordingWriterFlushesCapturedFramesAndMetadata() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let writer = try RecordingWriter(url: directory.appendingPathComponent("recording.wav"), format: format, startBeat: 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0.25, count: 1024)
        for _ in 0..<10 { writer.enqueue(buffer) }
        let (audio, error) = writer.finish()
        #expect(error == nil); #expect(audio.startBeat == 3)
        #expect(audio.duration == Double(10_240) / 48_000)
        let file = try AVAudioFile(forReading: audio.url)
        #expect(file.length == 10_240)
    }

    @Test func liveMetronomeProducesClicksButExportExcludesThem() throws {
        var song = Song(); song.tempo = 120; song.lengthBars = 1; song.metronomeEnabled = true
        let graph = try NativeGraph(song: song, assets: [:], includeMetronome: true)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 1024)
        try graph.engine.start(); defer { graph.engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 1024)!
        _ = try graph.engine.renderOffline(1024, to: buffer)
        let values = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        #expect(values.contains { abs($0) > 0.001 })
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try OfflineRenderer.render(song: song, assets: [:], to: directory.appendingPathComponent("no-click.wav")).silent)
    }

    @Test func recordedStartUsesFirstCaptureHostTimestamp() throws {
        var song = Song(); song.tempo = 120
        let timeline = NativeTimeline(song: song, fromBeat: 2, looping: false)
        let host = mach_absolute_time()
        ub_timeline_begin_render(timeline.pointer, 0, host, 1024)
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let halfSecondTicks = UInt64(500_000_000 * Double(timebase.denom) / Double(timebase.numer))
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let writer = try RecordingWriter(url: directory.appendingPathComponent("timed.wav"), format: format, startBeat: 2, timeline: timeline, tempo: 120)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024; buffer.floatChannelData![0].initialize(repeating: 0.25, count: 1024)
        writer.enqueue(buffer, hostTime: host + halfSecondTicks)
        writer.enqueue(buffer, hostTime: host + halfSecondTicks * 2)
        let (audio, error) = writer.finish()
        #expect(error == nil)
        #expect(abs(audio.startBeat - 3) < 0.0001)
    }

    @Test func mixerGainAboveUnityMatchesTheModel() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var song = song(); song.tracks[0].volume = 1
        let unity = try OfflineRenderer.render(song: song, assets: [:], to: directory.appendingPathComponent("unity.wav"))
        song.tracks[0].volume = 1.5
        let boosted = try OfflineRenderer.render(song: song, assets: [:], to: directory.appendingPathComponent("boosted.wav"))
        #expect(abs(boosted.peak / unity.peak - 1.5) < 0.01)
    }

    @Test func trackVolumeAndPanSurviveGraphInitializationForSynthAndAudio() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.wav")
        var sourceSong = song(); sourceSong.tracks[0].volume = 1
        _ = try OfflineRenderer.render(song: sourceSong, assets: [:], to: sourceURL)
        let metadata = try ReferenceAudioProcessor.inspectDerived(url: sourceURL)
        let asset = AudioAsset(fileName: "source.wav", duration: metadata.duration, sampleRate: metadata.sampleRate, channels: metadata.channels)
        var audioSong = Song(); audioSong.tempo = 120; audioSong.lengthBars = 1; audioSong.assets = [asset]
        audioSong.tracks = [Track(kind: .audio, volume: 1, parameters: ["cutoff": 20_000, "delay": 0, "reverb": 0],
            clips: [Clip(kind: .audio, lengthBeats: 4, assetID: asset.id)])]
        for (kind, base, assets) in [("synth", sourceSong, [UUID: URL]()), ("audio", audioSong, [asset.id: sourceURL])] {
            var draft = base
            let unity = try OfflineRenderer.render(song: draft, assets: assets, to: directory.appendingPathComponent("\(kind)-unity.wav"), lengthBeats: 4)
            for gain in [0.0, 0.3, 0.4] {
                draft.tracks[0].volume = gain
                let report = try OfflineRenderer.render(song: draft, assets: assets, to: directory.appendingPathComponent("\(kind)-\(gain).wav"), lengthBeats: 4)
                #expect(abs(report.rms / unity.rms - gain) < 0.002)
                #expect(gain != 0 || report.silent)
            }
            draft.tracks[0].volume = 0.4; draft.tracks[0].pan = -1
            let panned = directory.appendingPathComponent("\(kind)-left.wav")
            _ = try OfflineRenderer.render(song: draft, assets: assets, to: panned, lengthBeats: 4)
            let file = try AVAudioFile(forReading: panned)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let values = try #require(buffer.floatChannelData)
            var left = 0.0, right = 0.0
            for frame in 0..<Int(buffer.frameLength) {
                left += Double(values[0][frame] * values[0][frame])
                right += Double(values[1][frame] * values[1][frame])
            }
            #expect(left > 0.0001)
            #expect(right < left * 0.0001)
        }
    }
}
