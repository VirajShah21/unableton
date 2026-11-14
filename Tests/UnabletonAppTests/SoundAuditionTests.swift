import Foundation
import Combine
import Testing
import UnabletonCore
import UnabletonAudio
@testable import Unableton

@MainActor
private final class AuditionPlayerFixture: SoundAuditionPlaying {
    var plays: [URL] = []
    var volumes: [Float] = []
    var completion: (@MainActor () -> Void)?
    func play(url: URL, volume: Float, completion: @escaping @MainActor () -> Void) throws {
        plays.append(url); volumes.append(volume); self.completion = completion
    }
    func stop() { completion = nil }
}

@MainActor
private final class AuditionFocusFixture: SoundAuditionFocusing {
    var unavailableReason: String?
    var token: UUID?
    func begin(_ audition: SoundAuditionController) -> UUID? {
        guard unavailableReason == nil else { return nil }
        let token = UUID(); self.token = token; return token
    }
    func owns(_ token: UUID) -> Bool { self.token == token }
    func release(_ token: UUID) { if self.token == token { self.token = nil } }
}

private actor AuditionRenderGate {
    var requests: [(Song, URL, CheckedContinuation<SoundAuditionRender, any Error>)] = []
    func render(_ song: Song, _ url: URL) async throws -> SoundAuditionRender {
        try Data([0]).write(to: url)
        return try await withCheckedThrowingContinuation { requests.append((song, url, $0)) }
    }
    var count: Int { requests.count }
    func finish(_ index: Int) { requests[index].2.resume(returning: .init(peak: 0.25, silent: false)) }
}

private final class ResourceMarker: @unchecked Sendable {}
private final class ResourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var marker: ResourceMarker?
    var isHeld: Bool { lock.withLock { marker != nil } }
    func make() -> InstrumentResources {
        let owner = ResourceMarker(); lock.withLock { marker = owner }
        return .init(urls: [:], owner: owner)
    }
}

@Suite(.serialized) @MainActor
struct SoundAuditionTests {
    private var lead: InstrumentPreset { InstrumentCatalog.preset(id: "synth.lead")! }
    private func wait(_ condition: () async -> Bool) async {
        for _ in 0..<2000 { if await condition() { return }; await Task.yield() }
        Issue.record("Audition did not reach the expected state")
    }

    @Test func everyPatternUsesOnlySupportedAudibleProjectPitches() throws {
        for preset in InstrumentCatalog.presets {
            let song = try SoundAuditionPattern.song(for: preset)
            let notes = song.tracks.flatMap(\.clips).flatMap(\.notes)
            #expect(!notes.isEmpty)
            #expect(song.tempo == 120 && song.lengthBars == 2)
            #expect(song.tracks[0].parameters == preset.defaults)
            #expect(notes.allSatisfy { $0.startBeat >= 0 && $0.startBeat + $0.duration <= 8 })
            #expect(notes.allSatisfy { (preset.minimumPitch...preset.maximumPitch).contains($0.pitch) })
            #expect(notes.allSatisfy { preset.supportedPitches?.contains($0.pitch) ?? true })
            #expect(notes.allSatisfy { !(preset.unrenderablePitches ?? []).contains($0.pitch) })
        }
        let native = try SoundAuditionPattern.song(for: InstrumentCatalog.preset(id: "freepats.synthesizerpercussion")!)
        #expect(Set(native.tracks[0].clips[0].notes.map(\.pitch)) == [48, 50, 52, 54])
        let acoustic = try SoundAuditionPattern.song(for: InstrumentCatalog.preset(id: "sampled.drums")!)
        #expect(Set(acoustic.tracks[0].clips[0].notes.map(\.pitch)).isSubset(of: [35, 36, 37, 38, 39, 40]))
    }

    @Test func builtInPatternsRenderNonSilentWithoutDownloads() async throws {
        let presets = InstrumentCatalog.presets.filter { !$0.isSampler }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Audition-render-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            for preset in presets {
                let song = try SoundAuditionPattern.song(for: preset)
                let report = try OfflineRenderer.render(song: song, assets: [:], to: directory.appendingPathComponent(preset.id + ".wav"), lengthBeats: 8)
                #expect(!report.silent, "\(preset.id) should be audible")
                #expect(report.peak.isFinite && report.rms > 0)
            }
        }.value
    }

    @Test func canceledLateRenderCannotStartOrReplaceNewerPreview() async throws {
        let gate = AuditionRenderGate(), player = AuditionPlayerFixture(), focus = AuditionFocusFixture()
        let controller = SoundAuditionController(resourceProvider: { _ in .empty }, renderer: { song, url, _ in try await gate.render(song, url) }, player: player, focus: focus)
        defer { controller.stop() }
        controller.preview(lead)
        await wait { await gate.count == 1 }
        controller.preview(InstrumentCatalog.preset(id: "synth.pluck")!)
        await wait { await gate.count == 2 }
        await gate.finish(1)
        await wait { controller.phase == .playing }
        #expect(controller.instrumentID == "synth.pluck" && player.plays.count == 1)
        await gate.finish(0)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.instrumentID == "synth.pluck" && player.plays.count == 1)
    }

    @Test func resourceLeaseSurvivesRenderingAndPlaybackThenReleases() async {
        let probe = ResourceProbe(), gate = AuditionRenderGate(), player = AuditionPlayerFixture()
        let controller = SoundAuditionController(resourceProvider: { _ in probe.make() }, renderer: { song, url, _ in try await gate.render(song, url) }, player: player, focus: AuditionFocusFixture())
        defer { controller.stop() }
        controller.preview(lead)
        await wait { await gate.count == 1 }
        #expect(probe.isHeld)
        await gate.finish(0)
        await wait { controller.phase == .playing }
        #expect(probe.isHeld)
        player.completion?()
        #expect(controller.phase == .idle)
        await wait { !probe.isHeld }
    }

    @Test func cachedPreviewStillAcquiresResourcesAndDoesNotRenderAgain() async {
        let gate = AuditionRenderGate(), player = AuditionPlayerFixture()
        let controller = SoundAuditionController(resourceProvider: { _ in .empty }, renderer: { song, url, _ in try await gate.render(song, url) }, player: player, focus: AuditionFocusFixture())
        defer { controller.stop() }
        controller.preview(lead)
        await wait { await gate.count == 1 }; await gate.finish(0)
        await wait { controller.phase == .playing }
        controller.stop(); controller.preview(lead)
        await wait { player.plays.count == 2 }
        #expect(await gate.count == 1)
    }

    @Test func missingResourcesOrBlockedCaptureCannotStartPlayer() async {
        let player = AuditionPlayerFixture(), focus = AuditionFocusFixture()
        let controller = SoundAuditionController(resourceProvider: { _ in throw MissingInstruments(["sampled.piano"]) }, player: player, focus: focus)
        defer { controller.stop() }
        focus.unavailableReason = "Finish recording before previewing a sound."
        controller.preview(lead)
        #expect(controller.phase == .idle && controller.error == focus.unavailableReason)
        #expect(player.plays.isEmpty)
        focus.unavailableReason = nil
        controller.preview(lead)
        await wait { controller.error != nil }
        #expect(controller.phase == .idle && player.plays.isEmpty)
    }

    @Test func shutdownRemovesOnlyOwnedPreviewsFromAnInjectedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Audition-injected-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sentinel)
        let gate = AuditionRenderGate(), player = AuditionPlayerFixture()
        let controller = SoundAuditionController(directory: directory, resourceProvider: { _ in .empty }, renderer: { song, url, _ in try await gate.render(song, url) }, player: player, focus: AuditionFocusFixture())
        controller.preview(lead)
        await wait { await gate.count == 1 }; await gate.finish(0)
        await wait { controller.phase == .playing }
        let preview = try #require(player.plays.first)
        controller.shutdown()
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(controller.phase == .idle)
    }

    @Test func focusPreservesPositionAndProtectsPendingCapture() {
        let session = ProjectSession(mode: .superhuman)
        defer { session.close() }
        PlaybackFocus.claim(session); session.audio.seek(to: 7.5)
        let before = session.file.song, selection = session.selection
        let controller = SoundAuditionController(player: AuditionPlayerFixture())
        defer { controller.stop() }
        let token = PlaybackFocus.beginLibraryAudition(controller)
        #expect(token != nil)
        #expect(session.audio.currentBeat == 7.5)
        #expect(session.file.song == before && session.selection == selection)
        let capture = PlaybackFocus.beginCapturePreparation(session)
        #expect(!PlaybackFocus.ownsLibraryAudition(token!))
        #expect(PlaybackFocus.beginLibraryAudition(controller) == nil)
        #expect(session.audio.currentBeat == 7.5)
        PlaybackFocus.endCapturePreparation(capture)
        #expect(PlaybackFocus.beginLibraryAudition(controller) != nil)
    }

    @Test func availabilityNotifiesLibraryAfterPendingAndTranscriptionCaptureChanges() async {
        let session = ProjectSession(mode: .superhuman)
        let controller = SoundAuditionController(player: AuditionPlayerFixture())
        defer { controller.stop(); session.close() }
        PlaybackFocus.claim(session)
        var notifications = 0
        let observation = controller.objectWillChange.sink { notifications += 1 }
        defer { withExtendedLifetime(observation) {} }
        let beforePending = notifications
        let pending = PlaybackFocus.beginCapturePreparation(session)
        #expect(controller.unavailableReason != nil && notifications > beforePending)
        let duringPending = notifications
        PlaybackFocus.endCapturePreparation(pending)
        #expect(controller.unavailableReason == nil && notifications > duringPending)
        session.transcription.phase = .starting
        await wait { controller.unavailableReason != nil && notifications > duringPending + 1 }
        let duringCapture = notifications
        session.transcription.phase = .review
        await wait { controller.unavailableReason == nil && notifications > duringCapture }
        let beforeClose = notifications
        session.close()
        #expect(controller.unavailableReason == nil && notifications > beforeClose)
    }
}
