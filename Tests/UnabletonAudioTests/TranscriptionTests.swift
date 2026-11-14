import Foundation
import Testing
@preconcurrency import AVFAudio
import UnabletonCore
@testable import UnabletonAudio

@Suite(.serialized)
struct TranscriptionTests {
    private func recording(_ samples: [Float], sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonTranscription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("take.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) {
            for index in samples.indices { buffer.floatChannelData![channel][index] = samples[index] }
        }
        try file.write(from: buffer)
        return url
    }

    private func addTone(_ samples: inout [Float], frequency: Double, start: Double, duration: Double, rate: Double = 16_000, harmonics: Bool = false) {
        let lower = Int((start * rate).rounded()), upper = min(samples.count, Int(((start + duration) * rate).rounded()))
        for index in lower..<upper {
            let time = Double(index - lower) / rate
            let envelope = min(1, min(time / 0.005, (duration - time) / 0.005))
            var value = 0.35 * sin(2 * .pi * frequency * time)
            if harmonics { value += 0.15 * sin(4 * .pi * frequency * time) + 0.07 * sin(6 * .pi * frequency * time) }
            samples[index] += Float(envelope * value)
        }
    }

    @Test func secondsToBeatsPreservesTimingAndIdentifiers() throws {
        let event = TranscribedEvent(pitch: 69, startSeconds: 0.317, durationSeconds: 0.613, velocity: 0.7, confidence: 0.9)
        let transcript = PerformanceTranscript(mode: .humming, events: [event], duration: 1.537)
        let note = try #require(transcript.notes(tempo: 137).first)
        #expect(note.id == event.id)
        #expect(note.pitch == 69)
        #expect(abs(note.startBeat - 0.317 * 137 / 60) < 1e-12)
        #expect(abs(note.duration - 0.613 * 137 / 60) < 1e-12)
        #expect(note.velocity == 89)
    }

    @Test func transcriptRejectsInvalidAndDuplicatedEvents() throws {
        let event = TranscribedEvent(pitch: 69, startSeconds: 0.2, durationSeconds: 0.4, velocity: 0.7, confidence: 0.9)
        let repeated = PerformanceTranscript(mode: .singing, events: [event, event], duration: 1)
        #expect(throws: TranscriptionError.self) { try repeated.notes(tempo: 120) }
        var invalid = event; invalid.startSeconds = .nan
        #expect(throws: TranscriptionError.self) { try PerformanceTranscript(mode: .singing, events: [invalid], duration: 1).validate() }
        #expect(throws: TranscriptionError.self) { try PerformanceTranscript(mode: .singing, events: [event], duration: 1).notes(tempo: .infinity) }
    }

    @Test func whistleExtractsActualPitchesAndLeavesRests() async throws {
        var values = [Float](repeating: 0, count: 40_000)
        addTone(&values, frequency: 440, start: 0.215, duration: 0.43)
        addTone(&values, frequency: 523.251, start: 0.81, duration: 0.37)
        addTone(&values, frequency: 659.255, start: 1.54, duration: 0.51)
        let url = try recording(values); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transcript = try await PerformanceTranscriber.transcribe(url: url, mode: .whistle)
        #expect(transcript.events.map(\.pitch) == [69, 72, 76])
        #expect(abs(transcript.events[0].startSeconds - 0.215) < 0.035)
        #expect(abs(transcript.events[0].durationSeconds - 0.43) < 0.05)
        #expect(abs(transcript.events[1].startSeconds - 0.81) < 0.035)
        #expect(transcript.events[1].startSeconds > transcript.events[0].startSeconds + transcript.events[0].durationSeconds + 0.1)
        #expect(transcript.events.allSatisfy { $0.confidence > 0.75 })
    }

    @Test func hummingRetainsRepeatedNotesSeparatedBySilence() async throws {
        var values = [Float](repeating: 0, count: 26_000)
        addTone(&values, frequency: 146.832, start: 0.173, duration: 0.64, harmonics: true)
        addTone(&values, frequency: 146.832, start: 0.93, duration: 0.45, harmonics: true)
        let url = try recording(values); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transcript = try await PerformanceTranscriber.transcribe(url: url, mode: .humming)
        #expect(transcript.events.map(\.pitch) == [50, 50])
        #expect(abs(transcript.events[0].startSeconds - 0.173) < 0.04)
        #expect(transcript.events[1].startSeconds - transcript.events[0].startSeconds - transcript.events[0].durationSeconds > 0.05)
    }

    @Test func stereoSampleRateConversionKeepsPitchAndOnset() async throws {
        var values = [Float](repeating: 0, count: 44_100)
        addTone(&values, frequency: 1479.978, start: 0.231, duration: 0.54, rate: 44_100)
        let url = try recording(values, sampleRate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transcript = try await PerformanceTranscriber.transcribe(url: url, mode: .whistle)
        #expect(transcript.events.count == 1)
        #expect(transcript.events.first?.pitch == 90)
        #expect(abs(try #require(transcript.events.first).startSeconds - 0.231) < 0.035)
    }

    @Test func repeatedPitchAttacksWithoutCompleteSilenceRemainSeparate() async throws {
        var values = [Float](repeating: 0, count: 20_000)
        addTone(&values, frequency: 440, start: 0.2, duration: 0.8)
        for index in Int(0.58 * 16_000)..<Int(0.6 * 16_000) { values[index] *= 0.08 }
        let url = try recording(values); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transcript = try await PerformanceTranscriber.transcribe(url: url, mode: .humming)
        #expect(transcript.events.map(\.pitch) == [69, 69])
        #expect(abs(transcript.events[1].startSeconds - 0.6) < 0.025)
    }

    @Test func singingReportsMelodyRatherThanWords() async throws {
        var values = [Float](repeating: 0, count: 16_000)
        addTone(&values, frequency: 246.942, start: 0.1, duration: 0.7, harmonics: true)
        let url = try recording(values); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transcript = try await PerformanceTranscriber.transcribe(url: url, mode: .singing)
        #expect(transcript.events.map(\.pitch) == [59])
        #expect(transcript.warnings.contains { $0.contains("not lyrics") })
    }

    @Test func outOfRangePitchIsNotClampedIntoInventedNote() async throws {
        var values = [Float](repeating: 0, count: 16_000)
        addTone(&values, frequency: 50, start: 0.1, duration: 0.7)
        let url = try recording(values); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await #expect(throws: TranscriptionError.self) { try await PerformanceTranscriber.transcribe(url: url, mode: .humming) }
    }

    @Test func beatboxingFindsHitsAndReviewableDrumLabels() async throws {
        var values = [Float](repeating: 0, count: 32_000)
        for (start, frequency) in [(0.2, 80.0), (0.8, 1500.0), (1.4, 6200.0)] {
            for frame in 0..<3200 {
                let time = Double(frame) / 16_000
                values[Int(start * 16_000) + frame] += Float(0.7 * exp(-time * 32) * sin(2 * .pi * frequency * time))
            }
        }
        let url = try recording(values); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transcript = try await PerformanceTranscriber.transcribe(url: url, mode: .beatboxing)
        #expect(transcript.events.map(\.pitch) == [36, 38, 42])
        #expect(zip(transcript.events, [0.2, 0.8, 1.4]).allSatisfy { abs($0.0.startSeconds - $0.1) < 0.011 })
        #expect(transcript.warnings.contains { $0.contains("estimated") && $0.contains("Review") })
    }

    @Test func silenceAndUnpitchedNoiseDoNotProduceInventedMelody() async throws {
        let silent = try recording([Float](repeating: 0, count: 8000))
        defer { try? FileManager.default.removeItem(at: silent.deletingLastPathComponent()) }
        await #expect(throws: TranscriptionError.self) { try await PerformanceTranscriber.transcribe(url: silent, mode: .humming) }
        var state: UInt64 = 1
        let noise: [Float] = (0..<8000).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) - 0.5) * 0.4
        }
        let noisy = try recording(noise); defer { try? FileManager.default.removeItem(at: noisy.deletingLastPathComponent()) }
        await #expect(throws: TranscriptionError.self) { try await PerformanceTranscriber.transcribe(url: noisy, mode: .humming) }
    }

    @Test func durationLimitAndCancellationAreEnforced() async throws {
        let long = try recording([Float](repeating: 0, count: 960_016))
        defer { try? FileManager.default.removeItem(at: long.deletingLastPathComponent()) }
        await #expect(throws: TranscriptionError.self) { try await PerformanceTranscriber.transcribe(url: long, mode: .singing) }
        var values = [Float](repeating: 0, count: 16_000)
        addTone(&values, frequency: 440, start: 0, duration: 1)
        let url = try recording(values); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let task = Task { try await PerformanceTranscriber.transcribe(url: url, mode: .humming) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
