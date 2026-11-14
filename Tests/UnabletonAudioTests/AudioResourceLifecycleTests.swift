import Foundation
import Testing
@preconcurrency import AVFAudio
import UnabletonCore
@testable import UnabletonAudio

private final class ResourceOwner: Sendable {}
private final class WeakResourceOwner {
    weak var value: ResourceOwner?
    init(_ value: ResourceOwner?) { self.value = value }
}

@MainActor
struct AudioResourceLifecycleTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UnabletonResourceLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func controller(failStart: Bool = false, permission: Bool = true, failInput: Bool = false) -> AudioController {
        AudioController(startGraph: { _ in
            if failStart { throw AudioError.render("Fixture engine failure") }
        }, requestRecordPermission: { permission }, prepareRecording: { graph, url, _ in
            if failInput { throw AudioError.recording("Fixture input failure") }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let writer = try RecordingWriter(url: url, format: format, startBeat: graph.currentBeat)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            buffer.frameLength = 128; buffer.floatChannelData![0].initialize(repeating: 0.2, count: 128)
            writer.enqueue(buffer)
            return .init(writer: writer, removeTap: {})
        })
    }

    @Test func failedPlaybackConstructionAndActivationReleaseResources() throws {
        for failStart in [false, true] {
            let audio = controller(failStart: failStart)
            var owner: ResourceOwner? = ResourceOwner()
            let observed = WeakResourceOwner(owner)
            var song = Song()
            if !failStart { song.tempo = 0 }
            #expect(throws: (any Error).self) {
                try audio.play(song: song, assets: [:], resources: .init(urls: [:], owner: owner))
            }
            owner = nil
            #expect(observed.value == nil)
            #expect(!audio.isPlaying && !audio.isRecording)
        }
    }

    @Test func deniedMicrophoneDoesNotRetainNewResourcesOrInterruptPlayback() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let audio = controller(permission: false)
        var playingOwner: ResourceOwner? = ResourceOwner()
        let playingObserved = WeakResourceOwner(playingOwner)
        try audio.play(song: Song(), assets: [:], resources: .init(urls: [:], owner: playingOwner))
        playingOwner = nil
        #expect(playingObserved.value != nil)
        for transcription in [false, true] {
            let resources = InstrumentResources.empty
            do {
                if transcription {
                    try await audio.startTranscriptionCapture(song: Song(), assets: [:], to: directory.appendingPathComponent("denied.wav"), audition: .solo, resources: resources)
                } else {
                    try await audio.startRecording(song: Song(), to: directory.appendingPathComponent("denied.wav"), resources: resources)
                }
                Issue.record("Expected denied microphone")
            } catch let error as AudioError {
                if case .permissionDenied = error {} else { Issue.record("Unexpected error: \(error)") }
            }
            #expect(audio.isPlaying && !audio.isRecording)
            #expect(playingObserved.value != nil)
        }
        audio.pause()
        #expect(playingObserved.value == nil)
    }

    @Test func deniedCaptureReleasesPassedSnapshotAfterCall() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let audio = controller(permission: false)
        for transcription in [false, true] {
            var owner: ResourceOwner? = ResourceOwner()
            let observed = WeakResourceOwner(owner)
            do {
                if transcription {
                    try await audio.startTranscriptionCapture(song: Song(), assets: [:], to: directory.appendingPathComponent("take.wav"), audition: .solo, resources: .init(urls: [:], owner: owner))
                } else {
                    try await audio.startRecording(song: Song(), to: directory.appendingPathComponent("take.wav"), resources: .init(urls: [:], owner: owner))
                }
                Issue.record("Expected denied microphone")
            } catch {}
            owner = nil
            #expect(observed.value == nil)
        }
    }

    @Test func captureSetupFailuresReleaseResourcesAndRetainPartialFrames() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        for failInput in [false, true] {
            for transcription in [false, true] {
                let audio = controller(failStart: !failInput, failInput: failInput)
                var owner: ResourceOwner? = ResourceOwner()
                let observed = WeakResourceOwner(owner)
                do {
                    let url = directory.appendingPathComponent("\(failInput)-\(transcription).wav")
                    if transcription {
                        try await audio.startTranscriptionCapture(song: Song(), assets: [:], to: url, audition: .solo, resources: .init(urls: [:], owner: owner))
                    } else {
                        try await audio.startRecording(song: Song(), to: url, resources: .init(urls: [:], owner: owner))
                    }
                    Issue.record("Expected capture startup failure")
                } catch {}
                owner = nil
                #expect(observed.value == nil)
                #expect(!audio.isPlaying && !audio.isRecording && !audio.isTranscribingCapture)
                let partial = transcription ? audio.takeInterruptedTranscription() : audio.takeInterruptedRecording()
                if failInput { #expect(partial == nil) }
                else { #expect(try #require(partial).duration > 0) }
            }
        }
    }

    @Test func ignoredCallsDuringRecordingDoNotReplaceOwnedResources() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let audio = controller()
        var owner: ResourceOwner? = ResourceOwner()
        let observed = WeakResourceOwner(owner)
        try await audio.startRecording(song: Song(), to: directory.appendingPathComponent("take.wav"), resources: .init(urls: [:], owner: owner))
        owner = nil
        #expect(observed.value != nil)
        var rejected: ResourceOwner? = ResourceOwner()
        let rejectedObserved = WeakResourceOwner(rejected)
        try audio.play(song: Song(), assets: [:], resources: .init(urls: [:], owner: rejected))
        audio.update(song: Song(), assets: [:], resources: .init(urls: [:], owner: rejected))
        #expect(throws: AudioError.self) {
            try audio.playTranscriptionAudition(song: Song(), assets: [:], audition: .solo, resources: .init(urls: [:], owner: rejected))
        }
        rejected = nil
        #expect(rejectedObserved.value == nil)
        #expect(observed.value != nil && audio.isRecording)
        audio.stop()
        #expect(observed.value == nil)
    }
}
