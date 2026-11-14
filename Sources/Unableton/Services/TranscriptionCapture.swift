import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFAudio
import UnabletonCore
import UnabletonAudio

extension TranscriptionSession {
    func startCapture() {
        guard let project, !isWorking, !isCapturing, !project.audio.isRecording, !project.isGenerating else { return }
        preserveRecovery()
        operation?.cancel(); operationID = UUID(); let id = operationID
        take = nil; transcript = nil; prepared = nil; previewReady = false; inserted = false; recoverySaved = false
        error = nil; phase = .starting; rehearsing = false; status = "Preparing microphone…"
        captureTempo = project.file.song.tempo
        let song = project.file.song, assets = project.assetURLs, audition = audition
        let destination = project.cacheURL.appendingPathComponent("Transcribe-\(UUID()).wav")
        PlaybackFocus.claim(project); project.previewPlayer?.stop()
        let capturePreparation = PlaybackFocus.beginCapturePreparation(project)
        operation = Task { [weak self, weak project] in
            defer { PlaybackFocus.endCapturePreparation(capturePreparation) }
            guard let self, let project else { return }
            do {
                let ids = audition == .accompaniment ? InstrumentResources.requiredIDs(in: song) : []
                let resources = try await SoundLibraryStore.shared.resources(for: ids)
                try Task.checkCancellation()
                guard operationID == id, !project.closed, project.file.song.revision == song.revision else { throw CancellationError() }
                try await project.audio.startTranscriptionCapture(song: song, assets: assets, to: destination, audition: audition, resources: resources)
                guard operationID == id, !Task.isCancelled, !project.closed, PlaybackFocus.current === project else {
                    project.audio.cancelTranscriptionCapture(); return
                }
                phase = .recording; status = "Recording up to 60 seconds. Monitoring is off."; operation = nil
            } catch {
                guard operationID == id else { return }
                phase = .ready; operation = nil; self.error = error.localizedDescription; status = "Ready to record another take."
            }
        }
    }
    func finishCapture() {
        guard let project else { return }
        if phase == .starting { cancelWork(); return }
        guard let recorded = project.audio.stopTranscriptionCapture() else {
            captureFailed(project.audio.error ?? "No audio samples were captured. Check your microphone input in macOS Sound settings and record again.")
            return
        }
        receive(recorded)
    }
    func receive(_ recorded: RecordedAudio, interrupted: Bool = false) {
        project?.showTranscription()
        take = TranscriptionRecording(url: recorded.url, startBeat: recorded.startBeat, tempo: captureTempo,
                                      duration: recorded.duration, sampleRate: recorded.sampleRate, channels: recorded.channels)
        analyzeTake(interrupted: interrupted)
    }
    func chooseAudioFile() {
        guard !isWorking, !isCapturing, let project, !project.audio.isRecording else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Choose a solo whistle, humming, singing, or beatboxing take, up to 60 seconds."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importTake(url: url)
    }
    func importTake(url: URL, at startBeat: Double? = nil, recordedTempo: Double? = nil) {
        guard let project, !isWorking, !isCapturing else { return }
        preserveRecovery(); operationID = UUID(); let id = operationID
        let tempo = recordedTempo ?? project.file.song.tempo, beat = startBeat ?? project.audio.currentBeat
        let destination = project.cacheURL.appendingPathComponent("Transcribe-\(UUID()).\(url.pathExtension)")
        error = nil; phase = .analyzing; status = "Reading the take…"; prepared = nil; previewReady = false
        operation = Task { [weak self, weak project] in
            guard let self, let project else { return }
            do {
                let recording = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw TranscriptionError.invalidAudio("Choose an audio file smaller than 32 MiB.") }
                    let file = try AVAudioFile(forReading: url)
                    let duration = Double(file.length) / file.processingFormat.sampleRate
                    guard duration > 0 else { throw TranscriptionError.invalidAudio("This recording contains no audio samples. Check the microphone input and record another take.") }
                    guard duration <= 60.0001 else { throw TranscriptionError.durationLimit }
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(at: url, to: destination)
                    return TranscriptionRecording(url: destination, startBeat: beat, tempo: tempo, duration: duration, sampleRate: file.processingFormat.sampleRate, channels: Int(file.processingFormat.channelCount))
                }.value
                guard operationID == id, !Task.isCancelled, !project.closed else { return }
                take = recording; inserted = false; recoverySaved = false
                analyzeTake()
            } catch {
                guard operationID == id else { return }
                phase = transcript == nil ? .ready : .review; self.error = error.localizedDescription; operation = nil
                status = "Could not open this recording. \(take == nil ? "Record a new take or choose another file." : "Your previous take is still available.")"
            }
        }
    }
    func analyzeTake(interrupted: Bool = false) {
        guard let take, let project else { return }
        operation?.cancel(); operationID = UUID(); let id = operationID
        transcript = nil; prepared = nil; previewReady = false
        phase = .analyzing; error = nil; status = "Detecting notes and onsets on this Mac…"
        let mode = mode, analyze = analyze
        operation = Task { [weak self, weak project] in
            guard let self, let project else { return }
            do {
                let value = try await analyze(take.url, mode)
                try Task.checkCancellation()
                guard operationID == id, !project.closed else { return }
                transcript = value; prepared = nil; previewReady = false
                let beats = value.duration * project.file.song.tempo / 60
                options.targetLengthBeats = max(Double(project.file.song.beatsPerBar), ceil(beats / Double(project.file.song.beatsPerBar)) * Double(project.file.song.beatsPerBar))
                options.insertionBeat = take.startBeat
                phase = .review; reviewTab = "Notes"; operation = nil
                status = "Found \(value.events.count) notes. \(interrupted ? "The interrupted take was recovered. " : "")Preview the instrument or choose Add to Song. Nothing has been added yet."
            } catch {
                guard operationID == id else { return }
                phase = .ready; operation = nil; self.error = error.localizedDescription
                status = "Couldn't transcribe this take. Listen to the recording, retry, or record again. Nothing was added to the song."
            }
        }
    }
    func playOriginal() {
        guard let project, let take, !isWorking, !isCapturing else { return }
        project.previewURL = take.url; project.playPreview()
    }
    func rehearse() {
        guard let project, !isWorking, !isCapturing, !project.audio.isRecording else { return }
        if rehearsing, project.audio.isPlaying { project.audio.pause(); rehearsing = false; return }
        PlaybackFocus.claim(project); project.previewPlayer?.stop()
        project.preparePlayback(audition: audition)
        error = nil
    }
    func saveOriginal() {
        guard let take else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(mode.displayName)-take.\(take.url.pathExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: take.url); try data.write(to: destination, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
