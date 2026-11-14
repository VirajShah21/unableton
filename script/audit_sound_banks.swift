// Explicit native SF2 audit. Run after audit_freepats.py; not a normal build step.
import Foundation
import AVFAudio

func renderPitch(path: String, program: Int, bank: Int, pitch: Int) throws -> Float {
    let engine = AVAudioEngine()
    let sampler = AVAudioUnitSampler()
    try sampler.loadSoundBankInstrument(at: URL(fileURLWithPath: path), program: UInt8(program), bankMSB: bank >= 128 ? 0x78 : 0x79, bankLSB: UInt8(bank & 127))
    engine.attach(sampler)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    engine.connect(sampler, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    var sent = false
    let send = sampler.auAudioUnit.scheduleMIDIEventBlock!
    // Match production scheduling: send from the mixer pre-render observer.
    let token = engine.mainMixerNode.auAudioUnit.token(byAddingRenderObserver: { flags, _, _, _ in
        guard flags.contains(.unitRenderAction_PreRender), !sent else { return }
        sent = true
        let message: [UInt8] = [0x90, UInt8(pitch), 100]
        message.withUnsafeBufferPointer { send(AUEventSampleTimeImmediate, 0, 3, $0.baseAddress!) }
    })
    defer { engine.mainMixerNode.auAudioUnit.removeRenderObserver(token); engine.stop() }
    try engine.start()
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    var peak: Float = 0
    var frames = 0, stalled = 0
    while frames < 48_000 {
        let status = try engine.renderOffline(1024, to: buffer)
        if status == .success {
            frames += Int(buffer.frameLength)
            if let samples = buffer.floatChannelData {
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) {
                        guard samples[channel][frame].isFinite else { throw NSError(domain: "SF2 audit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nonfinite sample"]) }
                        peak = max(peak, abs(samples[channel][frame]))
                    }
                }
            }
        } else {
            stalled += 1
            if stalled > 128 { throw NSError(domain: "SF2 audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Render stalled"]) }
        }
    }
    return peak
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let auditURL = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appendingPathComponent(".cache/catalog-audit/audit.json")
var audit = try JSONSerialization.jsonObject(with: Data(contentsOf: auditURL)) as! [String: Any]
var banks = audit["banks"] as! [[String: Any]]
for index in banks.indices {
    guard let localPath = banks[index]["localPath"] as? String,
          var presets = banks[index]["presets"] as? [[String: Any]], banks[index]["error"] == nil else { continue }
    banks[index].removeValue(forKey: "nativeError")
    banks[index].removeValue(forKey: "nativeValidated")
    do {
        for presetIndex in presets.indices {
            let program = presets[presetIndex]["program"] as! Int
            let bank = presets[presetIndex]["bank"] as! Int
            var pitches = presets[presetIndex]["pitches"] as! [Int]
            let legacyDrums = banks[index]["name"] as? String == "MuldjordKit"
            if legacyDrums {
                // The legacy project descriptor exposes these mapped GM targets,
                // not every extra key present in the original source bank.
                pitches = [48,50,51,52,53,54,55,58,60,61,62,63,64]
            }
            var results: [[String: Any]] = []
            var silent: [Int] = []
            let tested = legacyDrums ? pitches : Array(Set([pitches.first!, pitches[pitches.count / 2], pitches.last!])).sorted()
            for pitch in tested {
                let peak = try renderPitch(path: localPath, program: program, bank: bank, pitch: pitch)
                results.append(["pitch": pitch, "peak": peak])
                if peak <= 0.00001 && legacyDrums { silent.append(pitch); continue }
                guard peak > 0.00001 else { throw NSError(domain: "SF2 audit", code: 3, userInfo: [NSLocalizedDescriptionKey: "AVAudioUnitSampler renders advertised pitch \(pitch) silently (peak \(peak))"]) }
            }
            presets[presetIndex]["nativeRender"] = results
            if !silent.isEmpty { banks[index]["nativeSilentPitches"] = silent; banks[index]["nativeError"] = "Legacy bank renders some mapped keys silently: \(silent)" }
        }
        banks[index]["presets"] = presets
        banks[index]["nativeValidated"] = banks[index]["nativeSilentPitches"] == nil
        print("Rendered \(banks[index]["name"]!)")
    } catch {
        banks[index]["nativeError"] = error.localizedDescription
        print("FAILED \(banks[index]["name"]!): \(error)")
    }
}
audit["banks"] = banks
let outputURL = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : root.appendingPathComponent(".cache/catalog-audit/native-audit.json")
try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL, options: .atomic)
