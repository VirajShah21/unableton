import CryptoKit
import Foundation
import UnabletonCore

struct BankFileStamp: Sendable, Equatable {
    let size: Int64
    let modified: Date
    let inode: UInt64
    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw SoundLibraryError.validation("The installed sound file is unavailable.")
        }
        self.size = size.int64Value; self.modified = modified; self.inode = inode.uint64Value
    }
}

enum BankFileValidation {
    static func verifiedStamp(_ url: URL, bytes: Int64, hash: String) throws -> BankFileStamp {
        let before = try BankFileStamp(url: url)
        try verify(url, bytes: bytes, hash: hash)
        let after = try BankFileStamp(url: url)
        guard before == after else { throw SoundLibraryError.validation("The sound file changed while it was being verified.") }
        return after
    }
    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
        value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+ ").contains($0) }
    }
    static func validate(_ bank: SoundBank) throws {
        let components = bank.member.split(separator: "/", omittingEmptySubsequences: false)
        guard validComponent(bank.id), validComponent(bank.version), validComponent(bank.fileName),
              bank.member.utf8.count < 4096, !bank.member.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
              bank.installedBytes > 0, bank.downloadBytes > 0,
              bank.sha256.count == 64, bank.archiveSHA256.count == 64,
              bank.sha256.allSatisfy(\.isHexDigit), bank.archiveSHA256.allSatisfy(\.isHexDigit) else {
            throw SoundLibraryError.validation("The sound-bank catalog contains invalid file metadata.")
        }
    }
    static func hash(_ url: URL, expectedBytes: Int64) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else {
            throw SoundLibraryError.validation("The sound file has an unexpected type or size.")
        }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while true {
            // FileHandle bridges autoreleased NSData. A worker that hashes a
            // large bank without draining a pool can retain every chunk until
            // the whole operation completes, despite the bounded read size.
            let hasChunk = try autoreleasepool { () throws -> Bool in
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty else { return false }
                digest.update(data: chunk)
                return true
            }
            if !hasChunk { break }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verify(_ url: URL, bytes: Int64, hash: String) throws {
        guard try self.hash(url, expectedBytes: bytes) == hash.lowercased() else {
            throw SoundLibraryError.validation("The sound file failed checksum verification. Retry the download.")
        }
    }
}

/// Only the pinned member is streamed out of tar. No archive paths are installed,
/// and expansion is stopped before it can exceed the declared uncompressed size.
public struct TarBankExtractor: SoundBankExtracting {
    public init() {}
    public func extract(_ bank: SoundBank, archive: URL, to destination: URL) async throws {
        try BankFileValidation.validate(bank)
        let runner = ExtractionProcess()
        let task = Task.detached(priority: .utility) {
            try runner.run(bank: bank, archive: archive, destination: destination)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel(); runner.cancel() }
    }
}

private final class ExtractionProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var canceled = false
    func cancel() {
        let process = lock.withLock { canceled = true; return self.process }
        if process?.isRunning == true { process?.terminate() }
    }
    func run(bank: SoundBank, archive: URL, destination: URL) throws {
        try Task.checkCancellation()
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SoundLibraryError.validation("Unable to create the sound installation file.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let pipe = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOf", archive.path, "--", bank.member]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try lock.withLock {
            guard !canceled else { throw CancellationError() }
            try process.run(); self.process = process
        }
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            lock.withLock { self.process = nil }
        }
        var written: Int64 = 0
        while true {
            // Drain the Foundation read/write bridging objects for each chunk,
            // rather than retaining an uncompressed bank's worth of memory.
            let hasChunk = try autoreleasepool { () throws -> Bool in
                try Task.checkCancellation()
                guard let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty else { return false }
                try Task.checkCancellation()
                guard Int64(chunk.count) <= bank.installedBytes - written else {
                    throw SoundLibraryError.validation("The extracted sound exceeded its pinned size.")
                }
                try output.write(contentsOf: chunk); written += Int64(chunk.count)
                return true
            }
            if !hasChunk { break }
        }
        try Task.checkCancellation()
        process.waitUntilExit()
        guard process.terminationStatus == 0, written == bank.installedBytes else {
            throw SoundLibraryError.validation("Unable to extract the expected sound-bank file.")
        }
    }
}
