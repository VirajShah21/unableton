import Foundation
import Combine
import UnabletonCore
import UnabletonAudio
import UnabletonAI

struct TranscriptionRecording: Sendable {
    var url: URL
    var startBeat: Double
    var tempo: Double
    var duration: Double
    var sampleRate: Double
    var channels: Int
}
struct PreparedTranscription {
    var revision: Int
    var options: TranscriptionOptions
    var transcript: PerformanceTranscript
    var commands: [ProjectCommand]
    var song: Song
    var asset: AudioAsset
    var result: TranscriptionArrangementResult?
}

@MainActor
final class TranscriptionSession: ObservableObject {
    enum Phase { case ready, starting, recording, analyzing, review, arranging, inserting }
    weak var project: ProjectSession?
    @Published var mode: TranscriptionMode = .whistle
    @Published var audition: TranscriptionAudition = .accompaniment
    @Published var phase: Phase = .ready
    @Published var transcript: PerformanceTranscript?
    @Published var options = TranscriptionOptions()
    @Published var insertAtRecordedPosition = true
    @Published var status = "Record a clear solo performance, or choose an audio file."
    @Published var error: String?
    @Published var prepared: PreparedTranscription?
    @Published var reviewTab = "Notes"
    @Published var previewReady = false
    @Published var rehearsing = false
    @Published var followPlayhead = true
    var take: TranscriptionRecording?
    var operation: Task<Void, Never>?
    var operationID = UUID()
    var captureTempo: Double = 140
    var recoverySaved = false
    var inserted = false
    var renderedPreviewURL: URL?
    var committedSourceID: UUID?
    var lastInsertedOptions: TranscriptionOptions?
    var lastInsertedTranscript: PerformanceTranscript?
    var lastInsertedTrackIDs = Set<UUID>()
    var lastInsertedSourceURL: URL?
    var recoveryURL = TranscriptionSession.recoveryDirectory
    let arranger: any TranscriptionArranging
    let analyze: @Sendable (URL, TranscriptionMode) async throws -> PerformanceTranscript

    init(project: ProjectSession, arranger: any TranscriptionArranging = TranscriptionArranger(),
         analyze: @escaping @Sendable (URL, TranscriptionMode) async throws -> PerformanceTranscript = { try await PerformanceTranscriber.transcribe(url: $0, mode: $1) }) {
        self.project = project; self.arranger = arranger; self.analyze = analyze
    }
    var isWorking: Bool { [.starting, .analyzing, .arranging, .inserting].contains(phase) }
    var isCapturing: Bool { phase == .starting || phase == .recording }
    var effectiveOptions: TranscriptionOptions {
        var value = options
        if insertAtRecordedPosition { value.insertionBeat = take?.startBeat ?? project?.audio.currentBeat ?? 0 }
        return value
    }
    var isPrepared: Bool {
        guard let prepared, let transcript, let project else { return false }
        return prepared.revision == project.file.song.revision && prepared.options == effectiveOptions && prepared.transcript == transcript
    }
    var availableTracks: Int { max(0, 64 - (project?.file.song.tracks.count ?? 0)) }
    var performanceLayerCount: Int { options.layers.filter { $0.role == .performance }.count }
    var alreadyInserted: Bool {
        guard let project, let take, lastInsertedSourceURL == take.url,
              lastInsertedOptions == effectiveOptions, lastInsertedTranscript == transcript,
              !lastInsertedTrackIDs.isEmpty else { return false }
        return lastInsertedTrackIDs.isSubset(of: Set(project.file.song.tracks.map(\.id)))
    }
    var takeIsInProject: Bool {
        guard let project, let take, lastInsertedSourceURL == take.url,
              let committedSourceID, let transcript else { return false }
        return project.file.song.assets.contains {
            $0.id == committedSourceID && $0.transcriptionTake?.transcript == transcript
        }
    }
    func configureMode(_ mode: TranscriptionMode) {
        self.mode = mode
        options.layers = [TranscriptionLayer(name: mode == .beatboxing ? "Transcribed drums" : "Transcribed melody", instrumentID: mode == .beatboxing ? "drums.electronic" : "synth.lead")]
    }
    func addLayer(_ role: TranscriptionLayerRole) {
        guard options.layers.count < availableTracks else { return }
        let instrument = role == .drums || (role == .performance && mode == .beatboxing) ? "drums.electronic" : role == .bass ? "synth.bass" : role == .harmony ? "synth.pad" : "synth.lead"
        options.layers.append(TranscriptionLayer(name: role.displayName, instrumentID: instrument, role: role))
    }
    func removeLayer(_ id: UUID) {
        guard let layer = options.layers.first(where: { $0.id == id }), layer.role != .performance || performanceLayerCount > 1 else { return }
        options.layers.removeAll { $0.id == id }
    }
    func setPerformanceLayerCount(_ count: Int) {
        while performanceLayerCount < count, options.layers.count < availableTracks { addLayer(.performance) }
        while performanceLayerCount > max(1, count), let last = options.layers.last(where: { $0.role == .performance }) { removeLayer(last.id) }
    }
    func updateEvent(_ id: UUID, pitch: Int? = nil, start: Double? = nil, duration: Double? = nil) {
        guard project?.canEditMusic == true else { return }
        guard var value = transcript, let index = value.events.firstIndex(where: { $0.id == id }) else { return }
        if let pitch { value.events[index].pitch = pitch }
        if let start { value.events[index].startSeconds = start }
        if let duration { value.events[index].durationSeconds = duration }
        do {
            try value.validate()
            guard value != transcript else { return }
            transcript = value; prepared = nil; previewReady = false; inserted = false; error = nil
        }
        catch { self.error = error.localizedDescription }
    }
    func cancelWork() {
        operationID = UUID(); operation?.cancel(); operation = nil
        if isCapturing { project?.audio.cancelTranscriptionCapture() }
        phase = transcript == nil ? .ready : .review
        status = "Canceled. The song was kept unchanged."
    }
    func captureFailed(_ message: String) {
        guard isCapturing, project?.audio.isTranscribingCapture != true else { return }
        operationID = UUID(); operation?.cancel(); operation = nil
        phase = .ready; error = message
        status = "Recording stopped because no audio could be captured. Check the input and try again."
        project?.showTranscription()
    }
    func prepareForClose() {
        operationID = UUID(); operation?.cancel(); operation = nil
        if let project, let recording = project.audio.stopTranscriptionCapture() {
            take = TranscriptionRecording(url: recording.url, startBeat: recording.startBeat, tempo: captureTempo, duration: recording.duration, sampleRate: recording.sampleRate, channels: recording.channels)
        } else { project?.audio.cancelTranscriptionCapture() }
        rehearsing = false
        phase = transcript == nil ? .ready : .review
        preserveRecovery()
    }
    static var recoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Unableton/RecoveredTakes", isDirectory: true)
    }
    func preserveRecovery() {
        guard !takeIsInProject, !recoverySaved, let take, FileManager.default.fileExists(atPath: take.url.path) else { return }
        do {
            let directory = recoveryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(mode.displayName)-\(UUID()).\(take.url.pathExtension)")
            try FileManager.default.copyItem(at: take.url, to: destination)
            struct Recovery: Codable { var mode: TranscriptionMode; var tempo: Double; var startBeat: Double; var transcript: PerformanceTranscript? }
            let metadata = Recovery(mode: mode, tempo: take.tempo, startBeat: take.startBeat, transcript: transcript)
            try JSONEncoder().encode(metadata).write(to: destination.appendingPathExtension("json"), options: .atomic)
            recoverySaved = true
            project?.notice = "Uninserted take kept in Application Support/Unableton/RecoveredTakes."
        } catch { project?.errorMessage = "Could not copy the take into recovery: \(error.localizedDescription). The original remains at \(take.url.path)." }
    }
}
