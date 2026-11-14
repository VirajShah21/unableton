import Foundation
import Testing
@preconcurrency import AVFAudio
import UnabletonCore
import UnabletonDSP
import Darwin
@testable import UnabletonAudio

/// AVFoundation's Objective-C tap-block alias is not annotated Sendable. Keep
/// the block intact so this test reproduces its real background invocation;
/// PCM buffers and timestamps are created on the invoking thread.
private final class RecordingTapFixture: @unchecked Sendable {
    let callback: AVAudioNodeTapBlock
    init(_ callback: @escaping AVAudioNodeTapBlock) { self.callback = callback }
}

@Suite(.serialized)
struct TranscriptionCaptureTests {
    @MainActor @Test func productionInputTapCanRunOnAnAudioQueueWithoutMainActorIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonTapIsolation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeline = NativeTimeline(song: song(), fromBeat: 7, looping: false)
        let originHostTime = mach_absolute_time()
        ub_timeline_begin_render(timeline.pointer, 0, originHostTime, 512)
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let halfSecondTicks = UInt64(500_000_000 * Double(timebase.denom) / Double(timebase.numer))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let writer = try RecordingWriter(url: directory.appendingPathComponent("tap.wav"), format: format,
                                         startBeat: 7, timeline: timeline, tempo: 120, maximumDuration: 60)
        // Create the exact production block on MainActor, just as input setup
        // does, then invoke its Objective-C bridge from a detached audio queue.
        let tap = RecordingTapFixture(AudioController.recordingTap(writer: writer))
        try await Task.detached {
            #expect(pthread_main_np() == 0)
            let callbackFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: callbackFormat, frameCapacity: 512))
            buffer.frameLength = 512
            buffer.floatChannelData![0].initialize(repeating: 0.125, count: 512)
            buffer.floatChannelData![1].initialize(repeating: 0.375, count: 512)
            let time = AVAudioTime(hostTime: originHostTime + halfSecondTicks)
            #expect(time.isHostTimeValid)
            tap.callback(buffer, time)
            tap.callback(buffer, time)
        }.value
        let (take, error) = writer.finish()
        #expect(error == nil)
        #expect(take.duration == 1024.0 / 48_000 && take.channels == 2)
        #expect(abs(take.startBeat - 8) < 0.0001)
        #expect(writer.progress.frames == 1024 && abs(writer.progress.inputLevel - 0.375) < 0.000_001)
        let file = try AVAudioFile(forReading: take.url)
        #expect(file.length == 1024)
        let captured = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
        try file.read(into: captured)
        #expect(captured.floatChannelData![0][0] == 0.125)
        #expect(captured.floatChannelData![1][1023] == 0.375)
    }

    @MainActor @Test func inputIsPreparedBeforeEngineStartForEmptySongsInBothRecordingPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonCaptureStartup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for transcription in [false, true] {
            var events: [String] = []
            let controller = AudioController(startGraph: { graph in
                #expect(events == ["input prepared"])
                events.append("engine started")
                try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 512)
                try graph.engine.start()
            }, requestRecordPermission: { true }, prepareRecording: { graph, url, maximum in
                #expect(!graph.engine.isRunning)
                events.append("input prepared")
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: transcription ? 2 : 1)!
                let writer = try RecordingWriter(url: url, format: format, startBeat: 0, maximumDuration: maximum)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                buffer.frameLength = 1024
                buffer.floatChannelData![0].initialize(repeating: transcription ? 0 : 0.25, count: 1024)
                if transcription { buffer.floatChannelData![1].initialize(repeating: 0.25, count: 1024) }
                writer.enqueue(buffer)
                return AudioController.RecordingSetup(writer: writer, removeTap: { events.append("input removed") })
            })
            defer { controller.stop() }
            let output = directory.appendingPathComponent(transcription ? "transcription.wav" : "ordinary.wav")
            if transcription {
                try await controller.startTranscriptionCapture(song: Song(), assets: [:], to: output, audition: .visualOnly)
                for _ in 0..<40 {
                    if controller.transcriptionHasInput { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(controller.transcriptionHasInput)
                #expect(abs(controller.transcriptionInputLevel - 0.25) < 0.000_001)
                #expect(controller.transcriptionElapsedSeconds > 0)
            } else { try await controller.startRecording(song: Song(), to: output) }
            let recorded = transcription ? controller.stopTranscriptionCapture() : controller.stopRecording()
            let take = try #require(recorded)
            #expect(take.duration == 1024.0 / 48_000)
            #expect(events == ["input prepared", "engine started", "input removed"])
            #expect(controller.error == nil && !controller.isRecording)
            #expect(try AVAudioFile(forReading: output).length == 1024)
        }
    }

    @MainActor @Test func emptyInputIsNotReturnedAsASuccessfulRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonEmptyCapture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = noInputController()
        defer { controller.stop() }
        try await controller.startTranscriptionCapture(song: Song(), assets: [:], to: directory.appendingPathComponent("empty.wav"), audition: .solo)
        #expect(controller.stopTranscriptionCapture() == nil)
        #expect(controller.error?.contains("No microphone audio reached") == true)
        #expect(!controller.isRecording && !controller.isTranscribingCapture)
        #expect(controller.completedTranscription == nil && controller.interruptedTranscription == nil)
    }

    @MainActor @Test func noInputWatchdogStopsAndReportsTheFailureWithoutAnEmptyTake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonCaptureWatchdog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = noInputController()
        defer { controller.stop() }
        try await controller.startTranscriptionCapture(song: Song(), assets: [:], to: directory.appendingPathComponent("empty.wav"), audition: .solo)
        let deadline = ContinuousClock.now + .seconds(4)
        while controller.isRecording && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isRecording && !controller.isTranscribingCapture)
        #expect(!controller.transcriptionHasInput && controller.transcriptionInputLevel == 0)
        #expect(controller.transcriptionElapsedSeconds >= 2)
        #expect(controller.error?.contains("No microphone audio reached") == true)
        #expect(controller.completedTranscription == nil && controller.interruptedTranscription == nil)
    }

    @MainActor private func noInputController() -> AudioController {
        AudioController(startGraph: { graph in
            try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 512)
            try graph.engine.start()
        }, requestRecordPermission: { true }, prepareRecording: { _, url, maximum in
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let writer = try RecordingWriter(url: url, format: format, startBeat: 0, maximumDuration: maximum)
            return AudioController.RecordingSetup(writer: writer, removeTap: {})
        })
    }

    private func song() -> Song {
        var song = Song()
        song.tempo = 120; song.lengthBars = 1
        song.loopEnabled = true; song.loopStart = 0; song.loopEnd = 1
        song.tracks = [Track(instrumentID: "synth.lead", parameters: ["oscillator": 0, "attack": 0.001, "decay": 0.01, "sustain": 0.7, "release": 0.01, "cutoff": 20_000, "drive": 0, "detune": 0, "reverb": 0, "delay": 0], clips: [Clip(lengthBeats: 4, notes: [NoteEvent(pitch: 69, startBeat: 0, duration: 2)])])]
        return song
    }

    @Test func silentCaptureModesStillRenderAnUnloopedMusicalClock() throws {
        let original = song()
        for audition in TranscriptionAudition.allCases {
            let graph = try NativeGraph.transcription(song: original, assets: [:], fromBeat: 0, audition: audition)
            try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 512)
            try graph.engine.start()
            defer { graph.engine.stop() }
            let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 512)!
            var peak: Float = 0
            for _ in 0..<96 {
                let status = try graph.engine.renderOffline(512, to: buffer)
                #expect(status == .success)
                for sample in UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)) {
                    peak = max(peak, abs(sample))
                }
            }
            #expect(abs(graph.currentBeat - 2.048) < 0.0001, "The capture clock must advance beyond the one-beat loop in every audition mode.")
            if audition == .accompaniment { #expect(peak > 0.001) }
            else { #expect(peak == 0) }
        }
    }

    @Test func takeLengthIsCappedAtTheExactFrameWithoutChangingInputCaptureOrigin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeline = NativeTimeline(song: song(), fromBeat: 7, looping: false)
        let host = mach_absolute_time()
        ub_timeline_begin_render(timeline.pointer, 0, host, 512)
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let halfSecondTicks = UInt64(500_000_000 * Double(timebase.denom) / Double(timebase.numer))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let writer = try RecordingWriter(url: directory.appendingPathComponent("limited.wav"), format: format, startBeat: 7, timeline: timeline, tempo: 120, maximumDuration: 0.015)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        buffer.floatChannelData![0].initialize(repeating: 0.3, count: 1024)
        for _ in 0..<5 { writer.enqueue(buffer, hostTime: host + halfSecondTicks) }
        let (take, error) = writer.finish()
        #expect(error == nil)
        #expect(take.duration == 720.0 / 48_000)
        #expect(abs(take.startBeat - 8) < 0.0001)
        #expect(writer.progress.reachedLimit)
        #expect(writer.progress.duration == take.duration)
        let file = try AVAudioFile(forReading: take.url)
        #expect(file.length == 720)
        let captured = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 720)!
        try file.read(into: captured)
        #expect(captured.floatChannelData![0][0] == 0.3)
    }

    @MainActor @Test func silentRehearsalStaysSilentThroughSeekAndEditsThenNormalPlaybackRestoresSound() throws {
        var graphs: [NativeGraph] = []
        let controller = AudioController { graph in
            try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 512)
            try graph.engine.start()
            graphs.append(graph)
        }
        defer { controller.stop() }
        let original = song()
        try controller.playTranscriptionAudition(song: original, assets: [:], audition: .visualOnly)
        #expect(!controller.isRecording)
        #expect(!controller.isTranscribingCapture)
        #expect(try renderPeak(graphs[0]) == 0)
        controller.seek(to: 1)
        #expect(graphs.count == 2)
        #expect(graphs[1].engine.mainMixerNode.outputVolume == 0)
        #expect(try renderPeak(graphs[1]) == 0)
        var edited = original; edited.tempo = 126
        controller.update(song: edited, assets: [:])
        #expect(graphs.count == 3)
        #expect(graphs[2].engine.mainMixerNode.outputVolume == 0)
        #expect(try renderPeak(graphs[2]) == 0)
        try controller.play(song: original, assets: [:])
        #expect(graphs.count == 4)
        #expect(graphs[3].engine.mainMixerNode.outputVolume == 1)
        #expect(try renderPeak(graphs[3]) > 0.001)
    }

    @MainActor @Test func rehearsalStopsAtTheEndEvenWhenSongLoopIsEnabled() async throws {
        var rendered: NativeGraph?
        let controller = AudioController { graph in
            try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 512)
            try graph.engine.start()
            rendered = graph
        }
        defer { controller.stop() }
        try controller.playTranscriptionAudition(song: song(), assets: [:], audition: .solo)
        let graph = try #require(rendered)
        for _ in 0..<200 { _ = try renderPeak(graph) }
        #expect(graph.currentBeat > 4)
        for _ in 0..<50 {
            if !controller.isPlaying { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isPlaying)
        #expect(controller.currentBeat == 0)
        #expect(!controller.isRecording)
    }

    private func renderPeak(_ graph: NativeGraph) throws -> Float {
        let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 512)!
        #expect(try graph.engine.renderOffline(512, to: buffer) == .success)
        return UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)).map { abs($0) }.max() ?? 0
    }
}
