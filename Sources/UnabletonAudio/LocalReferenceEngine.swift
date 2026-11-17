import Foundation
import CryptoKit
import Darwin

public struct LocalReferenceArtifact: Sendable, Equatable {
    public let name: String
    public let url: URL
    public init(name: String, url: URL) { self.name = name; self.url = url }
}

public struct LocalReferenceEngineState: Sendable, Equatable {
    public let installed: Bool
    public let message: String
    public init(installed: Bool, message: String) { self.installed = installed; self.message = message }
}

public struct LocalReferenceEngineError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Heavy inference lives in a cancellable, offline helper process, never on an audio thread.
public struct LocalReferenceEngine: Sendable {
    public static let modelIdentity = "demucs-4.0.1-htdemucs_basic-pitch-0.4.0-coreml-v1"
    public static let separationIdentity = "demucs-4.0.1/htdemucs"
    public static let transcriptionIdentity = "basic-pitch-0.4.0/icassp2022"
    public static let defaultRuntimeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Unableton/LocalProcessing", isDirectory: true)
    public let resourcesDirectory: URL
    public let runtimeDirectory: URL
    private let uvURL: URL?
    public static let maximumBytes: Int64 = 4 * 1024 * 1024 * 1024

    public init(resourcesDirectory: URL, runtimeDirectory: URL = Self.defaultRuntimeDirectory, uvURL: URL? = nil) {
        self.resourcesDirectory = resourcesDirectory
        self.runtimeDirectory = runtimeDirectory
        self.uvURL = uvURL
    }

    /// Cheap installation checks; the helper verifies both full model hashes before every operation.
    public func state() -> LocalReferenceEngineState {
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resourcesDirectory.appendingPathComponent("manifest.json")))
            let marker = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: runtimeDirectory.appendingPathComponent("ready.json")))
            let lock = try Data(contentsOf: resourcesDirectory.appendingPathComponent("requirements.lock"))
            guard manifest.profile == Self.modelIdentity, marker.profile == manifest.profile,
                  marker.requirements_sha256 == SHA256.hash(data: lock).map({ String(format: "%02x", $0) }).joined(),
                  FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
                return .init(installed: false, message: "Run Setup Local Processing for this app version.")
            }
            let model = runtimeDirectory.appendingPathComponent("models/demucs/\(manifest.demucs.file)")
            let values = try model.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? 0) == manifest.demucs.bytes else {
                return .init(installed: false, message: "The local model is missing or incomplete. Run setup again.")
            }
            let basic = runtimeDirectory.appendingPathComponent("environment/lib/python3.10/site-packages/basic_pitch/saved_models/\(manifest.basic_pitch.model)")
            for member in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
                let values = try basic.appendingPathComponent(member).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                    return .init(installed: false, message: "The Basic Pitch model is missing. Run setup again.")
                }
            }
            return .init(installed: true, message: "Demucs and Basic Pitch are installed. Song processing stays on this Mac.")
        } catch {
            return .init(installed: false, message: "Set up Demucs and Basic Pitch to process song attachments locally.")
        }
    }

    public func install(status: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let candidates = [uvURL, URL(fileURLWithPath: "/opt/homebrew/bin/uv"), URL(fileURLWithPath: "/usr/local/bin/uv"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv")].compactMap { $0 }
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw LocalReferenceEngineError("Install uv from https://docs.astral.sh/uv/getting-started/installation/ and run Setup Local Processing again.")
        }
        _ = try await run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-u", resourcesDirectory.appendingPathComponent("setup.py").path,
            "--root", runtimeDirectory.path, "--resources", resourcesDirectory.path, "--uv", uv.path], timeout: 1800, status: status)
        guard state().installed else { throw LocalReferenceEngineError("Local processing setup did not finish. Run setup again.") }
    }

    public func separate(source: URL, into directory: URL, maximumOutputBytes: Int64 = Self.maximumBytes,
                         status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [LocalReferenceArtifact] {
        try await operation("separate", arguments: ["--source", source.path], into: directory,
                            maximumOutputBytes: maximumOutputBytes, status: status)
    }

    public func transcribe(stems: [LocalReferenceArtifact], into directory: URL, includeVocals: Bool = false, vocalReference: URL? = nil, maximumOutputBytes: Int64 = Self.maximumBytes,
                           status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [LocalReferenceArtifact] {
        guard !stems.isEmpty, stems.count <= 4, Set(stems.map(\.name)).count == stems.count,
              stems.allSatisfy({ ["drums", "bass", "other", "vocals"].contains($0.name) }) else {
            throw LocalReferenceEngineError("Choose the separated stems from this song.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-LocalInputs-\(UUID().uuidString).json")
        let selected = stems.filter { includeVocals || $0.name != "vocals" }
        guard !selected.isEmpty else { return [] }
        let input = selected.map { ["name": $0.name, "path": $0.url.path] }
        try JSONSerialization.data(withJSONObject: input).write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await operation("transcribe", arguments: ["--inputs", temporary.path] + (includeVocals ? ["--include-vocals"] : []) + (vocalReference.map { ["--vocal-reference", $0.path] } ?? []), into: directory,
                                   maximumOutputBytes: maximumOutputBytes, status: status)
    }

    public func reconstruct(stems: [LocalReferenceArtifact], startSeconds: Double, endSeconds: Double,
                            into directory: URL, maximumOutputBytes: Int64 = Self.maximumBytes,
                            status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              endSeconds > startSeconds, endSeconds <= 600,
              maximumOutputBytes > 0, maximumOutputBytes <= Self.maximumBytes,
              !stems.isEmpty, stems.count <= 4, Set(stems.map(\.name)).count == stems.count,
              stems.allSatisfy({ ["drums", "bass", "other", "vocals"].contains($0.name) }) else {
            throw LocalReferenceEngineError("Choose a valid source range and the separated stems from this song.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Unableton-ReconstructionInputs-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: stems.map { ["name": $0.name, "path": $0.url.path] })
            .write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let results = try await operation("reconstruct", arguments: ["--inputs", temporary.path,
            "--start-seconds", String(startSeconds), "--end-seconds", String(endSeconds)], into: directory,
            maximumOutputBytes: min(maximumOutputBytes, 16 * 1024 * 1024), status: status)
        guard let result = results.first else { throw LocalReferenceEngineError("Local reconstruction returned no score.") }
        return result.url
    }

    private var pythonURL: URL { runtimeDirectory.appendingPathComponent("environment/bin/python") }

    private func operation(_ name: String, arguments: [String], into directory: URL, maximumOutputBytes: Int64,
                           status: @escaping @Sendable (String) -> Void) async throws -> [LocalReferenceArtifact] {
        guard state().installed else { throw LocalReferenceEngineError("Open Settings → Song Attachments and run Setup Local Processing first.") }
        guard maximumOutputBytes > 0, maximumOutputBytes <= Self.maximumBytes else {
            throw LocalReferenceEngineError("The local processing storage allowance is invalid.")
        }
        if FileManager.default.fileExists(atPath: directory.path),
           try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw LocalReferenceEngineError("The processing destination cannot be a symbolic link.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw LocalReferenceEngineError("The local processing destination must be empty.")
        }
        do {
            let response = try await run(executable: pythonURL, arguments: ["-I", "-B", "-u", resourcesDirectory.appendingPathComponent("worker.py").path,
                name, "--root", runtimeDirectory.path, "--resources", resourcesDirectory.path,
                "--output", directory.path, "--maximum-bytes", String(maximumOutputBytes)] + arguments,
                timeout: 1800, status: status)
            let artifacts = try validate(response: response, operation: name, directory: directory, maximumBytes: maximumOutputBytes)
            return artifacts
        } catch {
            // Only this operation's empty-at-entry output directory is owned here.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func validate(response: HelperResult, operation: String, directory: URL, maximumBytes: Int64) throws -> [LocalReferenceArtifact] {
        guard response.artifacts.count <= 4, Set(response.artifacts.map(\.name)).count == response.artifacts.count else {
            throw LocalReferenceEngineError("The local helper returned too many or duplicate artifacts.")
        }
        let expected = operation == "separate" ? Set(["drums", "bass", "other", "vocals"])
            : operation == "reconstruct" ? Set(["reconstruction"]) : Set(["bass", "other", "vocals"])
        if operation == "separate", Set(response.artifacts.map(\.name)) != expected {
            throw LocalReferenceEngineError("Demucs did not return all four stems.")
        }
        if operation == "reconstruct", Set(response.artifacts.map(\.name)) != expected {
            throw LocalReferenceEngineError("Local reconstruction did not return its measured score.")
        }
        var total: Int64 = 0
        return try response.artifacts.map { artifact in
            let suffix = operation == "separate" ? ".wav" : operation == "reconstruct" ? ".json" : ".mid"
            guard expected.contains(artifact.name), artifact.file == artifact.name + suffix else {
                throw LocalReferenceEngineError("The local helper returned an invalid artifact path.")
            }
            let url = directory.appendingPathComponent(artifact.file)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes > 0 else {
                throw LocalReferenceEngineError("The local helper returned a missing or empty file.")
            }
            total += Int64(bytes)
            guard total <= maximumBytes else { throw LocalReferenceEngineError("The local artifacts exceed the storage allowance.") }
            if operation == "separate" { _ = try ReferenceAudioProcessor.inspectDerived(url: url) }
            return LocalReferenceArtifact(name: artifact.name, url: url)
        }
    }

    private struct Manifest: Decodable {
        let profile: String
        let demucs: Model
        let basic_pitch: BasicModel
        struct Model: Decodable { let file: String; let bytes: Int64 }
        struct BasicModel: Decodable { let model: String }
    }
    private struct Ready: Decodable { let profile: String; let requirements_sha256: String }
    private struct HelperArtifact: Decodable { let name: String; let file: String }
    private struct HelperResult: Decodable { let artifacts: [HelperArtifact] }
    private struct Message: Decodable { let status: String?; let error: String?; let result: HelperResult? }

    private func runSynchronously(executable: URL, arguments: [String], timeout: TimeInterval,
                                  status: @escaping @Sendable (String) -> Void, control: LocalProcessControl) throws -> HelperResult {
        let process = Process()
        let output = Pipe(), diagnostics = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = diagnostics
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LC_ALL": "en_US.UTF-8", "PYTHONUNBUFFERED": "1"]
        try control.start(process)
        defer { control.finish() }
        let stderr = LocalProcessDiagnostics()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.leave() }
            while true {
                let data = diagnostics.fileHandleForReading.availableData
                if data.isEmpty { break }
                stderr.append(data)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { control.cancel(timedOut: true) }
        var pending = Data(), total = 0
        var result: HelperResult?, helperError: String?
        var protocolError = false
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            total += data.count
            if total > 512 * 1024 { protocolError = true; control.cancel(); break }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard !line.isEmpty, let message = try? JSONDecoder().decode(Message.self, from: Data(line)) else {
                    protocolError = true; continue
                }
                if let progress = message.status { status(String(progress.prefix(500))) }
                if let error = message.error { helperError = String(error.prefix(1200)) }
                if let value = message.result { result = value }
            }
        }
        process.waitUntilExit()
        drained.wait()
        if control.wasTimedOut { throw LocalReferenceEngineError("Local processing reached its 30-minute limit. Try a shorter selection.") }
        if control.wasCancelled { throw CancellationError() }
        if let helperError { throw LocalReferenceEngineError(helperError) }
        guard process.terminationStatus == 0, !protocolError, pending.isEmpty, let result else {
            let detail = stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalReferenceEngineError("Local processing failed. Run setup again if needed.\(detail.isEmpty ? "" : " " + String(detail.suffix(1200)))")
        }
        return result
    }

    private func run(executable: URL, arguments: [String], timeout: TimeInterval,
                     status: @escaping @Sendable (String) -> Void) async throws -> HelperResult {
        let control = LocalProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runSynchronously(executable: executable, arguments: arguments, timeout: timeout, status: status, control: control)
            }.value
        } onCancel: { control.cancel() }
    }
}

private final class LocalProcessDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.withLock { data.append(value); if data.count > 8192 { data = data.suffix(8192) } } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

private final class LocalProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var finished = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var wasTimedOut: Bool { lock.withLock { timedOut } }
    func start(_ value: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            process = value
            try value.run()
        }
    }
    func finish() { lock.withLock { finished = true; process = nil } }
    func cancel(timedOut: Bool = false) {
        let running: Process? = lock.withLock {
            guard !finished else { return nil }
            cancelled = true
            self.timedOut = self.timedOut || timedOut
            return process
        }
        guard let running, running.isRunning else { return }
        let pid = running.processIdentifier
        // Python starts its own session before spawning children. Never signal the app's group.
        if Darwin.getpgid(pid) == pid { _ = Darwin.kill(-pid, SIGTERM) }
        else { _ = Darwin.kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard running.isRunning else { return }
            if Darwin.getpgid(pid) == pid { _ = Darwin.kill(-pid, SIGKILL) }
            else { _ = Darwin.kill(pid, SIGKILL) }
        }
    }
}
