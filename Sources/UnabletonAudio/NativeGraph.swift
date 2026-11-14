import Foundation
@preconcurrency import AVFAudio
import UnabletonCore
import UnabletonDSP

final class NativeTimeline: @unchecked Sendable {
    let pointer: OpaquePointer
    init(song: Song, fromBeat: Double, looping: Bool) {
        pointer = ub_timeline_create(48_000, Int64(fromBeat * 60 / song.tempo * 48_000), looping && song.loopEnabled ? 1 : 0, Int64(song.loopStart * 60 / song.tempo * 48_000), Int64(song.loopEnd * 60 / song.tempo * 48_000))!
    }
    deinit { ub_timeline_destroy(pointer) }
}
final class NativeTrack: @unchecked Sendable {
    let pointer: OpaquePointer
    let timeline: NativeTimeline
    init(timeline: NativeTimeline, parameters: UBSynthParameters, events: [UBEvent]) {
        self.timeline = timeline
        pointer = events.withUnsafeBufferPointer { ub_track_create(timeline.pointer, parameters, $0.baseAddress, UInt32($0.count))! }
    }
    deinit { ub_track_destroy(pointer) }
}
final class NativeSample {
    let pointer: OpaquePointer
    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.length <= 64_000_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioError.unreadableAudio("Audio must contain samples and be shorter than 64 million frames. Split longer recordings before importing.")
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw AudioError.unreadableAudio("Could not decode \(url.lastPathComponent).") }
        pointer = ub_sample_create(data[0], data[buffer.format.channelCount > 1 ? 1 : 0], UInt64(buffer.frameLength), buffer.format.sampleRate)!
    }
    deinit { ub_sample_destroy(pointer) }
}

/// A graph is owned by one controller or one export operation. Rendering never reads Swift song state.
final class NativeGraph {
    let engine = AVAudioEngine()
    let timeline: NativeTimeline
    let tempo: Double
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var scheduler: OpaquePointer?
    private var samples: [UUID: NativeSample] = [:]
    private var nodes: [AVAudioNode] = []
    private let resources: InstrumentResources

    /// A take has a single, unlooped musical clock, including silent takes.
    /// Muting is on the output mixer; it never touches the input recording tap.
    static func transcription(song: Song, assets: [UUID: URL], fromBeat: Double, audition: TranscriptionAudition, resources: InstrumentResources = .empty) throws -> NativeGraph {
        var renderedSong = song
        if audition != .accompaniment { renderedSong.tracks = [] }
        let graph = try NativeGraph(song: renderedSong, assets: assets, fromBeat: fromBeat, looping: false, includeMetronome: audition == .accompaniment, resources: resources)
        graph.engine.mainMixerNode.outputVolume = audition == .accompaniment ? 1 : 0
        return graph
    }

    init(song: Song, assets: [UUID: URL], fromBeat: Double = 0, looping: Bool = false, includeMetronome: Bool = false, resources: InstrumentResources = .empty) throws {
        self.resources = resources
        let missing = InstrumentResources.requiredIDs(in: song).filter { InstrumentCatalog.preset(id: $0)?.isSampler == true && resources.urls[$0] == nil }
        if !missing.isEmpty { throw MissingInstruments(missing) }
        try ProjectEditor.validate(song)
        try InstrumentResources.validatePlayback(in: song)
        guard song.tempo.isFinite, song.tempo > 0, fromBeat.isFinite, fromBeat >= 0 else { throw AudioError.invalidSong("The tempo and playback position must be valid.") }
        timeline = NativeTimeline(song: song, fromBeat: fromBeat, looping: looping)
        tempo = song.tempo
        let mixer = engine.mainMixerNode.auAudioUnit
        scheduler = ub_scheduler_create(Unmanaged.passUnretained(mixer).toOpaque(), timeline.pointer)
        let solo = song.tracks.contains(where: \.isSolo)
        do {
            for track in song.tracks where !track.isMuted && (!solo || track.isSolo) {
                try add(track: track, assets: assets)
            }
            if includeMetronome && song.metronomeEnabled {
                let notes = (0..<Int(song.lengthBeats.rounded(.up))).map { beat in
                    NoteEvent(pitch: beat % song.beatsPerBar == 0 ? 96 : 89, startBeat: Double(beat), duration: 0.08, velocity: beat % song.beatsPerBar == 0 ? 110 : 75)
                }
                let click = Track(name: "Metronome", instrumentID: "synth.lead", volume: 0.45, parameters: ["oscillator": 0, "attack": 0.001, "decay": 0.02, "sustain": 0, "release": 0.01, "cutoff": 20_000, "detune": 0, "drive": 0, "delay": 0, "reverb": 0], clips: [Clip(lengthBeats: song.lengthBeats, notes: notes)])
                try add(track: click, assets: [:])
            }
        } catch {
            if let scheduler { ub_scheduler_destroy(scheduler); self.scheduler = nil }
            throw error
        }
    }
    deinit {
        engine.stop()
        if let scheduler { ub_scheduler_destroy(scheduler) }
    }
    var currentBeat: Double { Double(ub_timeline_current_frame(timeline.pointer)) / 48_000 * tempo / 60 }

    private func add(track: Track, assets: [UUID: URL]) throws {
        let parameters = track.effectiveParameters
        let events = try Self.events(for: track, tempo: tempo)
        if track.instrumentID == "sampled.bass", events.contains(where: { $0.on == 1 && !(26...45).contains(Int($0.pitch)) }) {
            throw AudioError.invalidSong("Bass guitar supports MIDI notes 26–45. Move its notes into that range or choose a synthesizer bass.")
        }
        let source: AVAudioNode
        if track.kind == .instrument, let preset = InstrumentCatalog.preset(id: track.instrumentID), preset.isSampler {
            let sampler = AVAudioUnitSampler()
            guard let url = resources.urls[preset.id] else { throw MissingInstruments([preset.id]) }
            let program = preset.program, bankNumber = preset.bank
            try sampler.loadSoundBankInstrument(at: url, program: program, bankMSB: bankNumber >= 128 ? 0x78 : 0x79, bankLSB: UInt8(bankNumber & 127))
            engine.attach(sampler)
            guard let scheduler, events.withUnsafeBufferPointer({ ub_scheduler_add_sampler(scheduler, Unmanaged.passUnretained(sampler.auAudioUnit).toOpaque(), $0.baseAddress, UInt32($0.count)) }) == 1 else {
                throw AudioError.render("The sampler does not support scheduled MIDI.")
            }
            source = sampler
        } else {
            if track.kind == .instrument, InstrumentCatalog.preset(id: track.instrumentID) == nil { throw AudioError.missingInstrument(track.instrumentID) }
            var p = UBSynthParameters()
            p.mode = track.instrumentID == "drums.electronic" ? 1 : 0
            p.waveform = Int32(parameters["oscillator", default: 1])
            p.attack = parameters["attack", default: 0.01]; p.decay = parameters["decay", default: 0.2]
            p.sustain = parameters["sustain", default: 0.65]; p.release = parameters["release", default: 0.3]
            p.cutoff = parameters["cutoff", default: 6000]; p.resonance = parameters["resonance", default: 0.15]
            p.detune = parameters["detune", default: 7]; p.lfoRate = parameters["lfoRate", default: 1] * tempo / 60
            p.lfoDepth = parameters["lfoDepth", default: 0]; p.drive = parameters["drive", default: 0.05]
            let native = NativeTrack(timeline: timeline, parameters: p, events: track.kind == .instrument ? events : [])
            for clip in track.clips where clip.kind == .audio {
                guard let id = clip.assetID, let url = assets[id] else { throw AudioError.missingAsset(clip.assetID ?? UUID()) }
                if samples[id] == nil { samples[id] = try NativeSample(url: url) }
                ub_track_add_audio(native.pointer, samples[id]!.pointer, frame(clip.startBeat), frame(clip.startBeat + clip.lengthBeats), clip.sourceOffsetSeconds)
            }
            let node = AVAudioSourceNode(format: format) { _, time, count, output in
                let buffers = UnsafeMutableAudioBufferListPointer(output)
                guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self), let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return -50 }
                ub_track_render(native.pointer, time.pointee.mSampleTime, count, left, right)
                return 0
            }
            engine.attach(node)
            source = node
        }
        nodes.append(source)
        let mixer = AVAudioMixerNode()
        mixer.outputVolume = Float(min(1, max(0, track.volume)))
        mixer.pan = Float(min(1, max(-1, track.pan)))
        var previous = source
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .lowPass; eq.bands[0].frequency = Float(parameters["cutoff", default: 6000]); eq.bands[0].bypass = false
        let delay = AVAudioUnitDelay(); delay.delayTime = 60 / tempo * 0.5; delay.feedback = 26; delay.wetDryMix = Float(parameters["delay", default: 0] * 45)
        let reverb = AVAudioUnitReverb(); reverb.loadFactoryPreset(.mediumHall); reverb.wetDryMix = Float(parameters["reverb", default: 0.12] * 55)
        var effects: [AVAudioNode] = [eq, delay, reverb]
        if track.instrumentID.hasPrefix("sampled."), parameters["drive", default: 0] > 0 {
            let distortion = AVAudioUnitDistortion(); distortion.loadFactoryPreset(.multiBrokenSpeaker); distortion.wetDryMix = Float(parameters["drive", default: 0] * 35)
            effects.insert(distortion, at: 1)
        }
        if track.volume > 1 {
            let gain = AVAudioUnitEQ(numberOfBands: 0)
            gain.globalGain = Float(20 * log10(track.volume))
            effects.append(gain)
        }
        for node in effects + [mixer] {
            engine.attach(node)
            engine.connect(previous, to: node, format: format)
            nodes.append(node); previous = node
        }
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
    }
    private func frame(_ beat: Double) -> Int64 { Int64((beat * 60 / tempo * 48_000).rounded()) }
    private static func events(for track: Track, tempo: Double) throws -> [UBEvent] {
        var result: [UBEvent] = []
        var identifier: UInt64 = 0
        for clip in track.clips where clip.kind == .notes {
            for note in clip.notes where note.duration > 0 && note.startBeat < clip.lengthBeats {
                identifier += 1
                let start = clip.startBeat + max(0, note.startBeat)
                let end = clip.startBeat + min(clip.lengthBeats, note.startBeat + note.duration)
                guard end > start else { continue }
                let mapping = InstrumentCatalog.preset(id: track.instrumentID)?.pitchMap
                let mappedPitch = mapping.map { $0[note.pitch] ?? -1 } ?? note.pitch
                guard mappedPitch >= 0 else { throw AudioError.invalidSong("Acoustic drums do not include GM note \(note.pitch). Choose a kick, snare, hi-hat, cymbal, or tom note, or use electronic drums.") }
                let pitch = UInt8(clamping: mappedPitch), velocity = UInt8(clamping: note.velocity)
                result.append(UBEvent(frame: Int64((start * 60 / tempo * 48_000).rounded()), note: identifier, pitch: min(127, pitch), velocity: min(127, velocity), on: 1))
                result.append(UBEvent(frame: Int64((end * 60 / tempo * 48_000).rounded()), note: identifier, pitch: min(127, pitch), velocity: 0, on: 0))
            }
        }
        return result.sorted { $0.frame == $1.frame ? $0.on < $1.on : $0.frame < $1.frame }
    }
}
