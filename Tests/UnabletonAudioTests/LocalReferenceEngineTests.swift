import Foundation
import CryptoKit
import Darwin
import Testing
@preconcurrency import AVFAudio
import UnabletonCore
@testable import UnabletonAudio

@Suite(.serialized)
struct LocalReferenceEngineTests {
    /// IPC fixtures exercise the production process boundary; they are not model accuracy tests.
    private func fixture(script: String) throws -> (URL, LocalReferenceEngine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalReferenceEngineTests-\(UUID())")
        let resources = root.appendingPathComponent("resources")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("environment/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("models/demucs"), withIntermediateDirectories: true)
        let launcher = runtime.appendingPathComponent("environment/bin/python")
        try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let model = Data([1, 2, 3, 4])
        try model.write(to: runtime.appendingPathComponent("models/demucs/test.th"))
        let lock = Data("IPC fixture lock".utf8)
        try lock.write(to: resources.appendingPathComponent("requirements.lock"))
        let hash = SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined()
        let basic = runtime.appendingPathComponent("environment/lib/python3.10/site-packages/basic_pitch/saved_models/icassp_2022/nmp.mlpackage")
        for member in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
            let file = basic.appendingPathComponent(member)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        let manifest: [String: Any] = ["profile": LocalReferenceEngine.modelIdentity, "demucs": ["file": "test.th", "bytes": 4], "basic_pitch": ["model": "icassp_2022/nmp.mlpackage"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: resources.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["profile": LocalReferenceEngine.modelIdentity, "requirements_sha256": hash])
            .write(to: runtime.appendingPathComponent("ready.json"))
        try Data(script.utf8).write(to: resources.appendingPathComponent("worker.py"))
        return (root, LocalReferenceEngine(resourcesDirectory: resources, runtimeDirectory: runtime))
    }

    @Test func missingOrChangedInstallationIsActionable() throws {
        let (root, engine) = try fixture(script: "")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(engine.state().installed)
        try Data("modified".utf8).write(to: engine.resourcesDirectory.appendingPathComponent("requirements.lock"))
        #expect(!engine.state().installed)
        try FileManager.default.removeItem(at: engine.runtimeDirectory.appendingPathComponent("ready.json"))
        #expect(!engine.state().installed)
        #expect(!engine.state().message.isEmpty)
    }

    @Test func untrustedArtifactPathsFailAndRemovePartialOutput() async throws {
        let script = """
        import json,os,sys
        try: os.setsid()
        except PermissionError: pass
        print(json.dumps({'result':{'artifacts':[{'name':'bass','file':'../outside.mid'}]}}),flush=True)
        """
        let (root, engine) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        do {
            _ = try await engine.transcribe(stems: [.init(name: "bass", url: root.appendingPathComponent("source.wav"))], into: output)
            Issue.record("An escaping artifact path was accepted.")
        } catch let error as LocalReferenceEngineError {
            #expect(error.message.contains("invalid artifact path"))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func boundedDiagnosticsCannotDeadlockTheWorker() async throws {
        let script = """
        import json,os,sys
        try: os.setsid()
        except PermissionError: pass
        sys.stderr.write('x'*262144)
        sys.stderr.flush()
        print(json.dumps({'result':{'artifacts':[]}}),flush=True)
        """
        let (root, engine) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: root) }
        let results = try await engine.transcribe(stems: [.init(name: "drums", url: root.appendingPathComponent("drums.wav"))], into: root.appendingPathComponent("output"))
        #expect(results.isEmpty)
    }

    @Test func vocalTranscriptionRequiresExplicitHostFlagAndDoesNotLeakIntoDefaultInputs() async throws {
        let script = """
        import json,os,pathlib,sys
        try: os.setsid()
        except PermissionError: pass
        inputs=json.loads(pathlib.Path(sys.argv[sys.argv.index('--inputs')+1]).read_text())
        include='--include-vocals' in sys.argv
        assert [v['name'] for v in inputs] == (['bass','vocals'] if include else ['bass'])
        output=pathlib.Path(sys.argv[sys.argv.index('--output')+1])
        (output/'bass.mid').write_bytes(b'MThd')
        print(json.dumps({'result':{'artifacts':[{'name':'bass','file':'bass.mid'}]}}),flush=True)
        """
        let (root, engine) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: root) }
        let stems: [LocalReferenceArtifact] = [.init(name: "bass", url: root.appendingPathComponent("bass.wav")),
            .init(name: "vocals", url: root.appendingPathComponent("vocals.wav"))]
        let normal = try await engine.transcribe(stems: stems, into: root.appendingPathComponent("normal"))
        let explicit = try await engine.transcribe(stems: stems, into: root.appendingPathComponent("explicit"), includeVocals: true)
        #expect(normal.map(\.name) == ["bass"] && explicit.map(\.name) == ["bass"])
        let vocalsOnly = try await engine.transcribe(stems: [stems[1]], into: root.appendingPathComponent("no-work"))
        #expect(vocalsOnly.isEmpty && !FileManager.default.fileExists(atPath: root.appendingPathComponent("no-work").path))
    }

    @Test func reconstructionUsesExactRangeAndAcceptsOnlyItsNamedScore() async throws {
        let script = """
        import json,os,pathlib,sys
        try: os.setsid()
        except PermissionError: pass
        assert 'reconstruct' in sys.argv
        assert float(sys.argv[sys.argv.index('--start-seconds')+1]) == 1.5
        assert float(sys.argv[sys.argv.index('--end-seconds')+1]) == 4
        output=pathlib.Path(sys.argv[sys.argv.index('--output')+1])
        (output/'reconstruction.json').write_text('{"profile":"fixture"}')
        print(json.dumps({'result':{'artifacts':[{'name':'reconstruction','file':'reconstruction.json'}]}}),flush=True)
        """
        let (root, engine) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: root) }
        let score = try await engine.reconstruct(stems: [.init(name: "bass", url: root.appendingPathComponent("bass.wav"))],
            startSeconds: 1.5, endSeconds: 4, into: root.appendingPathComponent("output"))
        #expect(score.lastPathComponent == "reconstruction.json")
        #expect(try String(contentsOf: score, encoding: .utf8) == "{\"profile\":\"fixture\"}")
        await #expect(throws: LocalReferenceEngineError.self) {
            _ = try await engine.reconstruct(stems: [.init(name: "bass", url: root.appendingPathComponent("bass.wav"))],
                startSeconds: 4, endSeconds: 1.5, into: root.appendingPathComponent("invalid"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("invalid").path))
    }

    @Test func cancellationStopsTheOwnedProcessGroup() async throws {
        let script = """
        import json,os,pathlib,subprocess,sys,time
        try: os.setsid()
        except PermissionError: pass
        root=pathlib.Path(sys.argv[sys.argv.index('--root')+1])
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
        (root/'pids.json').write_text(json.dumps([os.getpid(),child.pid]))
        print(json.dumps({'status':'running'}),flush=True)
        time.sleep(30)
        """
        let (root, engine) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        let task = Task { try await engine.transcribe(stems: [.init(name: "bass", url: root.appendingPathComponent("source.wav"))], into: output) }
        let pidsFile = engine.runtimeDirectory.appendingPathComponent("pids.json")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidsFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let data = try? Data(contentsOf: pidsFile), let pids = try? JSONDecoder().decode([Int32].self, from: data), pids.count == 2 else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The owned helper did not start.")
            return
        }
        defer { for pid in pids where Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) } }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled processing succeeded.") }
        catch is CancellationError { }
        for _ in 0..<100 {
            if pids.allSatisfy({ Darwin.kill($0, 0) != 0 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pids.allSatisfy { Darwin.kill($0, 0) != 0 })
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNABLETON_TEST_LOCAL_MODELS"] == "1"))
    func installedModelsSeparateAndTranscribeOffline() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = LocalReferenceEngine(resourcesDirectory: repository.appendingPathComponent("Resources/LocalProcessing"))
        #expect(engine.state().installed)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalReferenceRealModels-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 176_400))
            buffer.frameLength = 176_400
            for frame in 0..<176_400 {
                let time = Double(frame) / 44_100
                let value = Float(0.15 * sin(2 * .pi * 220 * time) + 0.1 * sin(2 * .pi * 440 * time))
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            try file.write(from: buffer)
        }
        let stems = try await engine.separate(source: source, into: root.appendingPathComponent("stems"))
        #expect(Set(stems.map(\.name)) == Set(["drums", "bass", "other", "vocals"]))
        for stem in stems {
            let metadata = try ReferenceAudioProcessor.inspectDerived(url: stem.url)
            #expect(abs(metadata.duration - 4) < 0.0001)
            #expect(metadata.sampleRate == 44_100)
            #expect(metadata.channels == 2)
        }
        let vocals = try #require(stems.first(where: { $0.name == "vocals" })?.url)
        let notes = try await engine.transcribe(stems: stems, into: root.appendingPathComponent("midi"), vocalReference: vocals)
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0.name != "drums" && $0.name != "vocals" })
        for artifact in notes {
            let parsed = try MIDIImporter.parse(Data(contentsOf: artifact.url), maximumDuration: 4)
            try parsed.validate(maximumDuration: 4)
        }
        let reconstructionURL = try await engine.reconstruct(stems: stems, startSeconds: 0, endSeconds: 4,
            into: root.appendingPathComponent("reconstruction"))
        let reconstruction = try JSONDecoder().decode(ReferenceReconstruction.self, from: Data(contentsOf: reconstructionURL))
        try reconstruction.validate(maximumDuration: 4)
        #expect(reconstruction.profile == ReferenceReconstruction.currentProfile)
        #expect(reconstruction.sourceStartSeconds == 0 && reconstruction.sourceEndSeconds == 4)
        #expect(reconstruction.parts.allSatisfy { $0.role != "vocals" })
    }
}
