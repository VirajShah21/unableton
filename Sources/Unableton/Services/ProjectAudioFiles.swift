import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFAudio
import UnabletonCore
import UnabletonAudio

extension ProjectSession {
    func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Import a recording or vocal into this song."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try insertAudio(url: url, at: audio.currentBeat, trackID: selectedTrack?.kind == .audio ? selectedTrack?.id : nil) }
        catch { errorMessage = error.localizedDescription }
    }
    func insertAudio(url: URL, at beat: Double, trackID: UUID?, recorded: RecordedAudio? = nil) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = try AVAudioFile(forReading: url)
        let duration = Double(source.length) / source.processingFormat.sampleRate
        guard duration > 0 else { throw ProjectError("The audio file is empty.") }
        let asset = AudioAsset(fileName: url.lastPathComponent, duration: duration, sampleRate: source.processingFormat.sampleRate, channels: Int(source.processingFormat.channelCount))
        let data = try Data(contentsOf: url)
        let destination = cacheURL.appendingPathComponent("\(asset.id)-\(url.lastPathComponent)")
        try data.write(to: destination, options: .atomic)
        var commands: [ProjectCommand] = []
        let target: UUID
        if let trackID, file.song.track(trackID)?.kind == .audio { target = trackID }
        else {
            let track = Track(name: url.deletingPathExtension().lastPathComponent, kind: .audio, colorIndex: file.song.tracks.count)
            target = track.id; commands.append(ProjectCommand(op: .addTrack, track: track))
        }
        let clip = Clip(name: url.deletingPathExtension().lastPathComponent, kind: .audio, startBeat: max(0, beat), lengthBeats: duration * file.song.tempo / 60, assetID: asset.id)
        commands.append(ProjectCommand(op: .addClip, trackID: target, clip: clip, asset: asset))
        var draft = file.song
        try ProjectEditor.apply(commands, to: &draft)
        assetData[asset.id] = data; assetURLs[asset.id] = destination
        waveforms[asset.id] = Self.waveform(file: source)
        commit(draft, replacing: file.song, name: recorded == nil ? "Import Audio" : "Record Audio")
        select(track: target, clip: clip.id)
    }
    nonisolated static func waveform(file: AVAudioFile) -> [Float] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return [] }
        var result = [Float](repeating: 0, count: 256)
        file.framePosition = 0
        var frame: Int64 = 0
        while frame < file.length {
            do { try file.read(into: buffer, frameCount: 4096) } catch { break }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for i in 0..<Int(buffer.frameLength) {
                let bucket = min(255, Int((frame + Int64(i)) * 256 / max(1, file.length)))
                result[bucket] = max(result[bucket], abs(channels[0][i]))
            }
            frame += Int64(buffer.frameLength)
        }
        return result
    }
    func toggleRecording() {
        if transcription.isCapturing { transcription.finishCapture(); return }
        if audio.isRecording { finishRecording(); return }
        if transcriptionVisible { transcription.startCapture(); return }
        PlaybackFocus.claim(self)
        var target = selectedTrack?.kind == .audio ? selectedTrack?.id : nil
        if let armed = file.song.tracks.first(where: { $0.kind == .audio && $0.isArmed }) { target = armed.id }
        // A new destination is created with the captured audio at commit time.
        // Recording is an allowed input in either mode, independent of manual
        // Add Track, and permission denial must not leave an empty track.
        recordingTrackID = target
        let destination = cacheURL.appendingPathComponent("Recording-\(UUID().uuidString).wav")
        audioPreparation?.cancel()
        let capturePreparation = PlaybackFocus.beginCapturePreparation(self)
        let token = UUID(); audioPreparationID = token
        audioPreparation = Task {
            defer {
                PlaybackFocus.endCapturePreparation(capturePreparation)
                if audioPreparationID == token { audioPreparation = nil }
            }
            do {
                let song = file.song, revision = file.song.revision
                let ids = InstrumentResources.requiredIDs(in: song)
                let resources: InstrumentResources
                let withoutAccompaniment: Bool
                do { resources = try await SoundLibraryStore.shared.existingResources(for: ids); withoutAccompaniment = false }
                catch let missing as MissingInstruments {
                    withoutAccompaniment = try await recordWithoutAccompanimentIfNeeded(missing)
                    resources = withoutAccompaniment ? .empty : try await SoundLibraryStore.shared.resources(for: ids)
                }
                try Task.checkCancellation()
                guard !closed, file.song.revision == revision, PlaybackFocus.current === self else { return }
                try await audio.startRecording(song: song, to: destination, resources: resources, withoutAccompaniment: withoutAccompaniment)
                if PlaybackFocus.current !== self { stop() }
            }
            catch is CancellationError { if audioPreparationID == token { recordingTrackID = nil } }
            catch { if audioPreparationID == token, !closed { recordingTrackID = nil; errorMessage = error.localizedDescription } }
        }
    }
    func finishRecording() {
        if audio.isTranscribingCapture || transcription.isCapturing { transcription.finishCapture(); return }
        guard let recorded = audio.stopRecording() else { recordingTrackID = nil; return }
        do { try insertAudio(url: recorded.url, at: recorded.startBeat, trackID: recordingTrackID, recorded: recorded) }
        catch { errorMessage = error.localizedDescription }
        recordingTrackID = nil
    }
    func recoverInterruptedRecording() {
        guard let recorded = audio.takeInterruptedRecording() else { return }
        do { try insertAudio(url: recorded.url, at: recorded.startBeat, trackID: recordingTrackID, recorded: recorded) }
        catch { errorMessage = error.localizedDescription }
        recordingTrackID = nil
    }
    func exportWAV() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(file.song.title).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let song = file.song; let assets = assetURLs
        isExporting = true; notice = "Exporting audio…"
        exportTask?.cancel()
        exportTask = Task {
            do {
                let resources = try await SoundLibraryStore.shared.resources(for: InstrumentResources.requiredIDs(in: song))
                try Task.checkCancellation()
                guard !closed else { return }
                let render = Task.detached(priority: .userInitiated) {
                    try OfflineRenderer.render(song: song, assets: assets, to: url, resources: resources)
                }
                let report = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
                try Task.checkCancellation()
                guard !closed else { return }
                notice = "Exported \(Int(report.duration)) seconds of audio."
            } catch is CancellationError { notice = "" }
            catch { if !closed { errorMessage = error.localizedDescription; notice = "" } }
            isExporting = false; exportTask = nil
        }
    }
    func exportMIDI() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = "\(file.song.title).mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MIDIExporter.data(for: file.song).write(to: url, options: .atomic); notice = "Exported note tracks as MIDI." }
        catch { errorMessage = error.localizedDescription }
    }
}
