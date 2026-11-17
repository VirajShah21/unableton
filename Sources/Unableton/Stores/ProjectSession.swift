import Foundation
import SwiftUI
import Combine
import Observation
import UnabletonCore
import UnabletonAudio
import UnabletonAI
import AVFAudio

@MainActor
final class ProjectSession: ObservableObject {
    let document: UnabletonDocument
    var file: ProjectFile {
        get { document.project }
        set {
            let previous = document.project
            objectWillChange.send(); document.project = newValue
            if previous != newValue, previous.song == newValue.song { document.nativeDocument?.updateChangeCount(.changeDone) }
        }
    }
    var assetData: [UUID: Data] {
        get { document.assets }
        set { objectWillChange.send(); document.assets = newValue }
    }
    @Published var selection = ProjectSelection()
    @Published private(set) var mode: WorkspaceMode
    var canEditMusic: Bool { mode == .producer }
    private let modePreferences: UserDefaults
    @Published var selectedNoteID: UUID?
    @Published var arrangementReveal: ArrangementRevealRequest?
    @Published var selectedConversationID: UUID?
    @Published var composer = ""
    @Published var composerAttachments: [UUID: [UUID]] = [:]
    @Published var attachmentImporting = false
    @Published var attachmentStatus: [UUID: String] = [:]
    var attachmentImportTask: Task<Void, Never>?
    var referenceProcessing: ReferenceProcessing?
    var retainedReferenceIDs = Set<UUID>()
    @Published var isGenerating = false
    @Published var generationStatus = ""
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var notice = ""
    @Published var zoom: Double = 24
    @Published var editorVisible = false
    @Published var transcriptionVisible = false
    @Published var chatVisible = true
    @Published var editorTab = "Notes"
    @Published var waveforms: [UUID: [Float]] = [:]
    @Published var queuedCount = 0
    @Published var previewURL: URL?
    var previewPlayer: AVAudioPlayer?
    let audio = AudioController()
    weak var undoManager: UndoManager?
    let cacheURL: URL
    var assetURLs: [UUID: URL] = [:]
    var generationTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var audioPreparation: Task<Void, Never>?
    var audioPreparationID = UUID()
    var draftReviewTasks: [UUID: Task<Void, Never>] = [:]
    var pendingPrompts: [QueuedPrompt] = []
    var recordingTrackID: UUID?
    @Published private(set) var closed = false
    lazy var transcription = TranscriptionSession(project: self)
    let agent: any MusicGenerating
    let keyProvider: @Sendable () throws -> String?
    let draftReviewer: any DraftReviewing
    let reviewKeyProvider: @Sendable () throws -> String?
    let reviewPreferences: UserDefaults
    var selectedTrack: Track? { file.song.track(selection.trackID) }
    var selectedClip: Clip? { file.song.clip(selection.clipID) }
    var currentConversation: Conversation? { file.conversations.first { $0.id == selectedConversationID } }

    convenience init(file: ProjectFile = ProjectFile(), assets: [UUID: Data] = [:], agent: any MusicGenerating = MusicAgent(), keyProvider: @escaping @Sendable () throws -> String? = { try CredentialStore.load() }, mode: WorkspaceMode? = nil, modePreferences: UserDefaults = .standard, draftReviewer: any DraftReviewing = JevDraftReviewer(), reviewKeyProvider: @escaping @Sendable () throws -> String? = { try CredentialStore.load(provider: "typesafe") }, reviewPreferences: UserDefaults = .standard) {
        self.init(document: UnabletonDocument(project: file, assets: assets), agent: agent, keyProvider: keyProvider, mode: mode, modePreferences: modePreferences, draftReviewer: draftReviewer, reviewKeyProvider: reviewKeyProvider, reviewPreferences: reviewPreferences)
    }
    init(document: UnabletonDocument, agent: any MusicGenerating = MusicAgent(), keyProvider: @escaping @Sendable () throws -> String? = { try CredentialStore.load() }, mode: WorkspaceMode? = nil, modePreferences: UserDefaults = .standard, draftReviewer: any DraftReviewing = JevDraftReviewer(), reviewKeyProvider: @escaping @Sendable () throws -> String? = { try CredentialStore.load(provider: "typesafe") }, reviewPreferences: UserDefaults = .standard) {
        self.document = document; self.agent = agent; self.keyProvider = keyProvider
        self.draftReviewer = draftReviewer; self.reviewKeyProvider = reviewKeyProvider; self.reviewPreferences = reviewPreferences
        self.modePreferences = modePreferences; self.mode = mode ?? WorkspaceMode.lastUsed(in: modePreferences)
        undoManager = document.editingUndoManager
        self.selectedConversationID = document.project.conversations.last?.id
        composerAttachments = Dictionary(uniqueKeysWithValues: document.project.conversations.map { ($0.id, $0.draftAttachmentIDs ?? []) })
        retainedReferenceIDs = Set((document.project.attachments ?? []).map(\.id) + document.project.song.assets.filter { $0.referenceDerivation != nil }.map(\.id))
        // A persisted pending observation cannot resume after its window closes.
        for index in document.project.generations.indices where document.project.generations[index].observation?.status == .pending {
            document.project.generations[index].observation?.status = .unavailable
            document.project.generations[index].observation?.message = "Review interrupted when the project closed."
        }
        cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            for (id, url) in document.blobURLs {
                assetURLs[id] = url
                if file.song.assets.contains(where: { $0.id == id }), let source = try? AVAudioFile(forReading: url) { waveforms[id] = Self.waveform(file: source) }
            }
            if let failure = document.storageError { throw ProjectError(failure) }
        } catch { errorMessage = error.localizedDescription }
        audio.update(song: file.song, assets: assetURLs)
    }
    func close() {
        guard !closed else { return }
        transcription.prepareForClose()
        if audio.isRecording { finishRecording() }
        closed = true; generationTask?.cancel(); attachmentImportTask?.cancel(); audioPreparation?.cancel(); exportTask?.cancel(); audio.stop(); previewPlayer?.stop()
        PlaybackFocus.release(self)
        for (id, task) in draftReviewTasks {
            task.cancel()
            if let index = file.generations.firstIndex(where: { $0.id == id }) {
                file.generations[index].observation?.status = .canceled
                file.generations[index].observation?.message = "Review canceled when the project closed."
            }
        }
        draftReviewTasks.removeAll()
        if transcription.take == nil || transcription.takeIsInProject || transcription.recoverySaved {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }
    func setMode(_ next: WorkspaceMode, remember: Bool = true) {
        // Publish the capability first. Disappearing editing views must not be
        // able to commit a text-field draft or drag after entering Superhuman.
        mode = next
        if remember { modePreferences.set(next.rawValue, forKey: WorkspaceMode.lastUsedPreferenceKey) }
    }
    func perform(_ commands: [ProjectCommand], name: String) {
        guard canEditMusic, !closed else { return }
        applyCommands(commands, name: name)
    }
    private func applyCommands(_ commands: [ProjectCommand], name: String) {
        guard !closed else { return }
        do {
            let before = file.song
            var after = before
            try ProjectEditor.apply(commands, to: &after)
            var comparable = after; comparable.revision = before.revision
            guard comparable != before else { return }
            commit(after, replacing: before, name: name)
        } catch { errorMessage = error.localizedDescription }
    }
    func commit(_ song: Song, replacing previous: Song, name: String, generationID: UUID? = nil, project metadata: ProjectFile? = nil) {
        var updated = song; updated.revision = file.song.revision + 1
        var project = metadata ?? file; project.song = updated
        file = project
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous, name: name, generationID: generationID, undone: generationID != nil)
        }
        undoManager?.setActionName(name)
        synchronizeAudio()
        repairSelection()
    }
    func restore(_ song: Song, name: String, generationID: UUID?, undone: Bool) {
        let current = file.song
        var restored = song; restored.revision = current.revision + 1
        file.song = restored
        if let id = generationID, let index = file.generations.firstIndex(where: { $0.id == id }) {
            file.generations[index].isUndone = undone
        }
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(current, name: name, generationID: generationID, undone: !undone)
        }
        undoManager?.setActionName(name)
        synchronizeAudio(); repairSelection()
    }
    func synchronizeAudio() {
        audioPreparation?.cancel(); audioPreparation = nil
        if audio.isRecording { return }
        let playing = audio.isPlaying
        let audition: TranscriptionAudition? = transcription.rehearsing ? transcription.audition : nil
        if playing { audio.pause() }
        audio.update(song: file.song, assets: assetURLs)
        if playing { preparePlayback(audition: audition) }
    }
    func repairSelection() {
        if file.song.track(selection.trackID) == nil { selection.trackID = nil }
        if let clipID = selection.clipID {
            if let owner = file.song.tracks.first(where: { $0.clips.contains(where: { $0.id == clipID }) }) {
                selection.trackID = owner.id
            } else {
                selection.clipID = nil; selectedNoteID = nil
            }
        }
    }
    func select(track: UUID, clip: UUID? = nil) {
        selection.trackID = track; selection.clipID = clip; selectedNoteID = nil
        if clip != nil { editorVisible = true; editorTab = "Notes" }
    }
    func addInstrumentTrack(instrumentID: String = "synth.lead") {
        guard canEditMusic else { return }
        let track = Track(name: "Instrument \(file.song.tracks.count + 1)", instrumentID: instrumentID, colorIndex: file.song.tracks.count)
        perform([ProjectCommand(op: .addTrack, track: track)], name: "Add Track")
        if file.song.track(track.id) != nil { select(track: track.id); editorTab = "Instrument" }
    }
    func addAudioTrack() {
        guard canEditMusic else { return }
        let track = Track(name: "Audio \(file.song.tracks.count + 1)", kind: .audio, colorIndex: file.song.tracks.count)
        perform([ProjectCommand(op: .addTrack, track: track)], name: "Add Audio Track")
        if file.song.track(track.id) != nil { select(track: track.id) }
    }
    func addNoteClip(at beat: Double? = nil, trackID: UUID? = nil) {
        guard canEditMusic else { return }
        var target = trackID ?? selection.trackID
        if file.song.track(target)?.kind != .instrument { addInstrumentTrack(); target = selection.trackID }
        guard let target else { return }
        let clip = Clip(name: "Notes", startBeat: max(0, beat ?? floor(audio.currentBeat / 4) * 4), lengthBeats: 16)
        perform([ProjectCommand(op: .addClip, trackID: target, clip: clip)], name: "Add Note Clip")
        if file.song.clip(clip.id) != nil { select(track: target, clip: clip.id) }
    }
    func duplicateSelection() {
        if let clip = selection.clipID { perform([ProjectCommand(op: .duplicateClip, clipID: clip)], name: "Duplicate Clip") }
        else if let track = selection.trackID { perform([ProjectCommand(op: .duplicateTrack, trackID: track)], name: "Duplicate Track") }
    }
    func deleteSelection() {
        if let clip = selection.clipID { perform([ProjectCommand(op: .deleteClip, clipID: clip)], name: "Delete Clip") }
        else if let track = selection.trackID { perform([ProjectCommand(op: .deleteTrack, trackID: track)], name: "Delete Track") }
    }
    func setTrackFlag(_ op: CommandOperation, track: Track, enabled: Bool) {
        perform([ProjectCommand(op: op, trackID: track.id, value: enabled ? 1 : 0)], name: "Change Track")
    }
    func parameter(_ key: String, value: Double, track: Track) {
        perform([ProjectCommand(op: .setParameter, trackID: track.id, value: value, text: key)], name: "Change \(key)")
    }
    func setTempo(_ value: Double) { perform([ProjectCommand(op: .setTempo, value: value)], name: "Change Tempo") }
    func setKey(_ value: String) { perform([ProjectCommand(op: .setKey, text: value)], name: "Change Key") }
    func toggleLoop() {
        // Playback navigation is allowed in both modes; range editing still
        // enters through perform(), which requires Producer.
        applyCommands([ProjectCommand(op: .setLoop, value: file.song.loopEnabled ? 0 : 1, startBeat: file.song.loopStart, lengthBeats: file.song.loopEnd - file.song.loopStart)], name: "Change Loop")
    }
    func toggleMetronome() { perform([ProjectCommand(op: .setMetronome, value: file.song.metronomeEnabled ? 0 : 1)], name: "Change Metronome") }
    func togglePlayback() {
        previewPlayer?.stop()
        if audio.isRecording { return }
        if audio.isPlaying { audio.pause(); transcription.rehearsing = false; return }
        if transcriptionVisible { transcription.rehearse(); return }
        PlaybackFocus.claim(self); preparePlayback()
    }
    func playPreview() {
        guard !audio.isRecording, !transcription.isCapturing else { return }
        PlaybackFocus.claim(self)
        guard let previewURL else { return }
        do {
            audio.pause()
            previewPlayer?.stop()
            previewPlayer = try AVAudioPlayer(contentsOf: previewURL)
            previewPlayer?.play()
        } catch { errorMessage = error.localizedDescription }
    }
    func stop() {
        audioPreparation?.cancel(); audioPreparation = nil; audioPreparationID = UUID()
        previewPlayer?.stop()
        transcription.rehearsing = false
        if transcription.isCapturing { transcription.finishCapture() }
        if audio.isRecording { finishRecording() }
        audio.stop()
    }
    func showTranscription() { transcriptionVisible = true }
    func hasActiveClip(_ track: Track) -> Bool {
        guard audio.isPlaying, !track.isMuted,
              !file.song.tracks.contains(where: \.isSolo) || track.isSolo,
              !((audio.isTranscribingCapture || transcription.rehearsing) && transcription.audition == .solo) else { return false }
        return track.clips.contains { audio.currentBeat >= $0.startBeat && audio.currentBeat < $0.startBeat + $0.lengthBeats }
    }
    func newConversation() {
        let conversation = Conversation()
        file.conversations.append(conversation); selectedConversationID = conversation.id
    }
    func deleteNote() {
        guard canEditMusic else { return }
        guard let clipID = selection.clipID, let noteID = selectedNoteID else { return }
        perform([ProjectCommand(op: .deleteNote, clipID: clipID, noteID: noteID)], name: "Delete Note")
        selectedNoteID = nil
    }
}

@MainActor
enum PlaybackFocus {
    static weak var current: ProjectSession? {
        didSet {
            captureObservationID = UUID()
            transcriptionObservation = nil
            if let current {
                observeAudioCapture(current, id: captureObservationID)
                let id = captureObservationID
                transcriptionObservation = current.transcription.$phase.sink { [weak current] _ in
                    // Published sends before the property changes; notify the
                    // library on the next main-actor turn, after it changes.
                    Task { @MainActor in
                        guard current != nil, captureObservationID == id else { return }
                        availabilityChanges.send()
                    }
                }
            }
            availabilityChanges.send()
        }
    }
    static let availabilityChanges = PassthroughSubject<Void, Never>()
    private static var captureObservationID = UUID()
    private static var transcriptionObservation: AnyCancellable?
    private static weak var libraryAudition: SoundAuditionController?
    private static var libraryToken: UUID?
    private final class CapturePreparation {
        weak var session: ProjectSession?
        init(_ session: ProjectSession) { self.session = session }
    }
    private static var capturePreparations: [UUID: CapturePreparation] = [:]

    static func claim(_ session: ProjectSession) {
        stopLibraryAudition()
        if current !== session { current?.stop(); current = session }
    }
    static func release(_ session: ProjectSession) {
        capturePreparations = capturePreparations.filter { $0.value.session != nil && $0.value.session !== session }
        if current === session { current = nil }
        availabilityChanges.send()
    }
    /// Register before any async microphone permission/resource preparation.
    /// A nil destination track is still a pending ordinary recording.
    static func beginCapturePreparation(_ session: ProjectSession) -> UUID {
        claim(session)
        let token = UUID(); capturePreparations[token] = CapturePreparation(session)
        availabilityChanges.send()
        return token
    }
    static func endCapturePreparation(_ token: UUID) {
        capturePreparations.removeValue(forKey: token)
        availabilityChanges.send()
    }
    static var libraryAuditionUnavailableReason: String? {
        capturePreparations = capturePreparations.filter { $0.value.session != nil && $0.value.session?.closed == false }
        if !capturePreparations.isEmpty || current?.audio.isRecording == true || current?.audio.isTranscribingCapture == true || current?.transcription.isCapturing == true {
            return "Finish recording before previewing a sound."
        }
        return nil
    }
    static func beginLibraryAudition(_ audition: SoundAuditionController) -> UUID? {
        guard libraryAuditionUnavailableReason == nil else { return nil }
        stopLibraryAudition()
        // Pause retains the musical position. Do not use ProjectSession.stop,
        // which resets transport and can finalize a microphone take.
        if let current {
            current.audioPreparation?.cancel(); current.audioPreparation = nil; current.audioPreparationID = UUID()
            current.previewPlayer?.stop(); current.transcription.rehearsing = false
            current.audio.pause()
        }
        let token = UUID(); libraryToken = token; libraryAudition = audition
        return token
    }
    static func ownsLibraryAudition(_ token: UUID) -> Bool { libraryToken == token }
    static func releaseLibraryAudition(_ token: UUID) {
        guard libraryToken == token else { return }
        libraryToken = nil; libraryAudition = nil
    }
    static func stopLibraryAudition() {
        let audition = libraryAudition
        libraryToken = nil; libraryAudition = nil
        audition?.stop()
    }
    private static func observeAudioCapture(_ session: ProjectSession, id: UUID) {
        withObservationTracking {
            _ = session.audio.isRecording
            _ = session.audio.isTranscribingCapture
        } onChange: { [weak session] in
            Task { @MainActor in
                guard let session, captureObservationID == id, current === session else { return }
                observeAudioCapture(session, id: id)
                availabilityChanges.send()
            }
        }
    }
}
