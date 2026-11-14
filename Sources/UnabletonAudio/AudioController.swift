import Foundation
import Observation
@preconcurrency import AVFAudio
import UnabletonCore

@MainActor @Observable
public final class AudioController {
    public private(set) var isPlaying = false
    public private(set) var isRecording = false
    public private(set) var currentBeat: Double = 0
    public private(set) var status = "Ready"
    public private(set) var error: String?
    public private(set) var interruptedRecording: RecordedAudio?
    public private(set) var isTranscribingCapture = false
    public private(set) var transcriptionElapsedSeconds: Double = 0
    public private(set) var transcriptionInputLevel: Double = 0
    public private(set) var transcriptionHasInput = false
    public private(set) var completedTranscription: RecordedAudio?
    public private(set) var interruptedTranscription: RecordedAudio?
    public static let maximumTranscriptionDuration: Double = 60
    @ObservationIgnored private var graph: NativeGraph?
    @ObservationIgnored private var song: Song?
    @ObservationIgnored private var assets: [UUID: URL] = [:]
    @ObservationIgnored private var resources: InstrumentResources = .empty
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var recorder: RecordingWriter?
    @ObservationIgnored private var configurationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var configurationGeneration = 0
    @ObservationIgnored private var recordingRequest: UUID?
    @ObservationIgnored private var transcriptionRequest: UUID?
    @ObservationIgnored private var captureStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var activeAudition: TranscriptionAudition?
    @ObservationIgnored private let startGraph: @MainActor (NativeGraph) throws -> Void
    @ObservationIgnored private let requestRecordPermission: @Sendable () async -> Bool
    @ObservationIgnored private let prepareRecording: @MainActor (NativeGraph, URL, Double?) throws -> RecordingSetup
    @ObservationIgnored private var removeRecordingTap: (() -> Void)?

    struct RecordingSetup {
        let writer: RecordingWriter
        let removeTap: () -> Void
    }

    public convenience init() { self.init(startGraph: { try $0.engine.start() }) }
    /// Allows hardware-free rendering checks without changing the production graph.
    convenience init(startGraph: @escaping @MainActor (NativeGraph) throws -> Void) {
        self.init(startGraph: startGraph,
                  requestRecordPermission: { await AVAudioApplication.requestRecordPermission() },
                  prepareRecording: Self.prepareInputRecording)
    }
    /// Tests replace only permission/input setup; graph activation and capture
    /// lifecycle still follow the production path without opening a device.
    init(startGraph: @escaping @MainActor (NativeGraph) throws -> Void,
         requestRecordPermission: @escaping @Sendable () async -> Bool,
         prepareRecording: @escaping @MainActor (NativeGraph, URL, Double?) throws -> RecordingSetup) {
        self.startGraph = startGraph; self.requestRecordPermission = requestRecordPermission
        self.prepareRecording = prepareRecording
    }
    public func play(song: Song, assets: [UUID: URL], resources: InstrumentResources = .empty) throws {
        guard !isRecording else { return }
        self.resources = resources
        try begin(song: song, assets: assets, fromBeat: currentBeat)
    }
    /// Rehearse the chosen accompaniment without opening the microphone.
    public func playTranscriptionAudition(song: Song, assets: [UUID: URL], audition: TranscriptionAudition, resources: InstrumentResources = .empty) throws {
        guard !isRecording, recordingRequest == nil else { throw AudioError.recording("Finish the current recording before rehearsing a transcription.") }
        self.resources = resources
        try begin(song: song, assets: assets, fromBeat: graph?.currentBeat ?? currentBeat, audition: audition)
    }
    private func begin(song: Song, assets: [UUID: URL], fromBeat: Double, audition: TranscriptionAudition? = nil, startImmediately: Bool = true) throws {
        clockTask?.cancel(); removeConfigurationObserver(); graph?.engine.stop(); graph = nil; isPlaying = false
        activeAudition = nil
        self.song = song; self.assets = assets
        let origin = min(max(0, fromBeat), song.lengthBeats)
        do {
            let next: NativeGraph
            if let audition { next = try NativeGraph.transcription(song: song, assets: assets, fromBeat: origin, audition: audition, resources: resources) }
            else { next = try NativeGraph(song: song, assets: assets, fromBeat: origin, looping: true, includeMetronome: true, resources: resources) }
            graph = next; activeAudition = audition
            if startImmediately { try activate(next) }
        } catch {
            clockTask?.cancel(); clockTask = nil; removeConfigurationObserver()
            graph?.engine.stop(); graph = nil
            activeAudition = nil; resources = .empty; isPlaying = false; currentBeat = origin
            throw error
        }
    }

    private func activate(_ next: NativeGraph) throws {
        try startGraph(next)
        isPlaying = true; error = nil; status = isTranscribingCapture ? "Recording transcription" : isRecording ? "Recording" : "Playing"
        observeConfiguration(of: next)
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self, let graph = self.graph else { return }
                self.currentBeat = graph.currentBeat
                if self.recorder?.isInterrupted == true { self.handleInputInterruption(); return }
                if self.isTranscribingCapture, let recorder = self.recorder {
                    let progress = recorder.progress
                    let elapsed = self.captureStartedAt.map { $0.duration(to: .now) } ?? .zero
                    self.transcriptionElapsedSeconds = min(Self.maximumTranscriptionDuration, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                    self.transcriptionHasInput = progress.frames > 0
                    self.transcriptionInputLevel = progress.inputLevel
                    if !self.transcriptionHasInput, elapsed >= .seconds(2) {
                        _ = self.stopTranscriptionCapture()
                        self.status = "No microphone audio received"
                        return
                    }
                    if progress.reachedLimit || self.captureStartedAt.map({ $0.duration(to: .now) >= .seconds(Self.maximumTranscriptionDuration) }) == true {
                        self.completedTranscription = self.stopTranscriptionCapture()
                        self.status = "Take ready (60-second limit)"
                        return
                    }
                }
                if let song = self.song, (self.activeAudition != nil || !song.loopEnabled), self.currentBeat >= song.lengthBeats, !self.isRecording {
                    self.pause(); self.currentBeat = 0; return
                }
            }
        }
    }
    public func stop() {
        recordingRequest = nil; transcriptionRequest = nil
        if isTranscribingCapture { completedTranscription = stopTranscriptionCapture() }
        else if isRecording { _ = stopRecording() }
        clockTask?.cancel(); clockTask = nil; removeConfigurationObserver(); graph?.engine.stop(); graph = nil
        activeAudition = nil; resources = .empty; isPlaying = false; currentBeat = 0; status = "Stopped"
    }
    public func pause() {
        guard !isRecording else { return }
        if let graph { currentBeat = graph.currentBeat }
        clockTask?.cancel(); clockTask = nil; removeConfigurationObserver(); graph?.engine.stop(); graph = nil
        isPlaying = false; resources = .empty; status = "Paused"
    }
    public func seek(to beat: Double) {
        guard beat.isFinite, !isRecording else { return }
        currentBeat = max(0, min(song?.lengthBeats ?? max(0, beat), beat))
        if isPlaying, let song {
            do { try begin(song: song, assets: assets, fromBeat: currentBeat, audition: activeAudition) }
            catch { self.error = error.localizedDescription; status = "Playback failed" }
        }
    }
    public func update(song: Song, assets: [UUID: URL], resources: InstrumentResources? = nil) {
        guard !isRecording else { return }
        if let resources { self.resources = resources }
        self.song = song; self.assets = assets
        if isPlaying {
            let beat = graph?.currentBeat ?? currentBeat
            do { try begin(song: song, assets: assets, fromBeat: beat, audition: activeAudition) }
            catch { self.error = error.localizedDescription; status = "Playback failed" }
        }
    }
    public func startRecording(song: Song, to url: URL, resources: InstrumentResources = .empty, withoutAccompaniment: Bool = false) async throws {
        guard !isRecording, recordingRequest == nil else { return }
        let request = UUID(); recordingRequest = request
        defer { if recordingRequest == request { recordingRequest = nil } }
        guard await requestRecordPermission() else { throw AudioError.permissionDenied }
        try Task.checkCancellation()
        guard recordingRequest == request else { throw CancellationError() }
        self.resources = resources
        do {
            try begin(song: song, assets: assets, fromBeat: graph?.currentBeat ?? currentBeat, audition: withoutAccompaniment ? .visualOnly : nil, startImmediately: false)
            guard let graph else { throw AudioError.recording("The audio engine could not start.") }
            let setup = try prepareRecording(graph, url, nil)
            recorder = setup.writer; removeRecordingTap = setup.removeTap
            isRecording = true; status = "Recording"; error = nil
            try activate(graph)
        } catch {
            interruptedRecording = stopRecording()
            pause()
            throw error
        }
    }
    /// Capture to a temporary file. The caller decides whether and where to
    /// insert the take; this controller never changes project tracks or assets.
    public func startTranscriptionCapture(song: Song, assets: [UUID: URL], to url: URL, audition: TranscriptionAudition, resources: InstrumentResources = .empty) async throws {
        guard !isRecording, recordingRequest == nil else { throw AudioError.recording("Finish the current recording before starting a transcription.") }
        let request = UUID(); recordingRequest = request; transcriptionRequest = request
        defer {
            if recordingRequest == request { recordingRequest = nil }
            if transcriptionRequest == request { transcriptionRequest = nil }
        }
        guard await requestRecordPermission() else { throw AudioError.permissionDenied }
        try Task.checkCancellation()
        guard recordingRequest == request else { throw CancellationError() }
        self.resources = resources

        let origin = graph?.currentBeat ?? currentBeat
        completedTranscription = nil; interruptedTranscription = nil
        transcriptionElapsedSeconds = 0
        transcriptionInputLevel = 0; transcriptionHasInput = false
        do {
            // AVAudioEngine creates input I/O lazily. Configure the input/tap
            // before the first start, including songs with no output tracks.
            try begin(song: song, assets: assets, fromBeat: origin, audition: audition, startImmediately: false)
            guard let graph else { throw AudioError.recording("The audio engine could not start.") }
            let setup = try prepareRecording(graph, url, Self.maximumTranscriptionDuration)
            recorder = setup.writer; removeRecordingTap = setup.removeTap
            isRecording = true; isTranscribingCapture = true
            status = "Recording transcription"; error = nil
            try activate(graph)
            captureStartedAt = .now
        } catch {
            if isTranscribingCapture { interruptedTranscription = stopTranscriptionCapture() }
            else { pause() }
            throw error
        }
    }
    public func stopRecording() -> RecordedAudio? {
        // A take must enter the Transcribe review, never ordinary recording's
        // automatic audio-track insertion path.
        guard !isTranscribingCapture else { return nil }
        return finishRecorder()
    }
    private func finishRecorder() -> RecordedAudio? {
        guard let recorder else { return nil }
        removeRecordingTap?(); removeRecordingTap = nil
        let (recording, problem) = recorder.finish()
        self.recorder = nil; isRecording = false
        error = problem; status = problem == nil ? "Recording saved" : "Recording interrupted"
        return recording.duration > 0 ? recording : nil
    }
    public func stopTranscriptionCapture() -> RecordedAudio? {
        guard isTranscribingCapture else { return nil }
        let beat = graph?.currentBeat ?? currentBeat
        let recording = finishRecorder()
        isTranscribingCapture = false; captureStartedAt = nil
        clockTask?.cancel(); clockTask = nil; removeConfigurationObserver(); graph?.engine.stop(); graph = nil
        activeAudition = nil; resources = .empty; isPlaying = false; currentBeat = beat
        transcriptionElapsedSeconds = recording?.duration ?? transcriptionElapsedSeconds
        transcriptionInputLevel = 0
        status = error == nil ? "Take ready" : "Take interrupted"
        return recording
    }
    public func cancelTranscriptionCapture() {
        let wasActive = isTranscribingCapture || transcriptionRequest != nil
        if let request = transcriptionRequest, recordingRequest == request { recordingRequest = nil }
        transcriptionRequest = nil
        _ = stopTranscriptionCapture()
        completedTranscription = nil; interruptedTranscription = nil
        transcriptionElapsedSeconds = 0
        transcriptionInputLevel = 0; transcriptionHasInput = false
        if wasActive { status = "Transcription cancelled" }
    }
    public func takeCompletedTranscription() -> RecordedAudio? {
        defer { completedTranscription = nil }
        return completedTranscription
    }
    public func takeInterruptedTranscription() -> RecordedAudio? {
        defer { interruptedTranscription = nil }
        return interruptedTranscription
    }
    public func takeInterruptedRecording() -> RecordedAudio? {
        defer { interruptedRecording = nil }
        return interruptedRecording
    }
    private func removeConfigurationObserver() {
        configurationGeneration += 1
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }
    private func observeConfiguration(of graph: NativeGraph) {
        removeConfigurationObserver()
        let generation = configurationGeneration
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph.engine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.configurationGeneration == generation else { return }
                if self.isRecording { self.handleInputInterruption() }
                else if self.graph?.engine.isRunning == false { self.pause(); self.status = "Audio device changed" }
            }
        }
    }
    private func handleInputInterruption() {
        if isTranscribingCapture { interruptedTranscription = stopTranscriptionCapture() }
        else { interruptedRecording = stopRecording(); pause() }
        status = "Recording interrupted"
        error = error ?? "The audio input changed. Audio captured before the interruption was saved."
    }
    private static func prepareInputRecording(_ graph: NativeGraph, to url: URL, maximumDuration: Double?) throws -> RecordingSetup {
        let input = graph.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.recording("No audio input is available.") }
        let writer = try RecordingWriter(url: url, format: format, startBeat: graph.currentBeat, timeline: graph.timeline, tempo: graph.tempo, maximumDuration: maximumDuration)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: recordingTap(writer: writer))
        return RecordingSetup(writer: writer, removeTap: { input.removeTap(onBus: 0) })
    }
    // AVAudioNodeTapBlock predates Swift concurrency and does not require a
    // Sendable closure. Constructing it in a MainActor method implicitly binds
    // it to that actor, which traps when Core Audio delivers the first buffer.
    // This callback must only enqueue into the preallocated recording ring.
    nonisolated static func recordingTap(writer: RecordingWriter) -> AVAudioNodeTapBlock {
        { @Sendable buffer, time in
            writer.enqueue(buffer, hostTime: time.isHostTimeValid ? time.hostTime : 0)
        }
    }
}
