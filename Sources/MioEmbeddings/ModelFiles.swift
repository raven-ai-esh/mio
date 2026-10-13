import Foundation
import CryptoKit
import MioCore

public struct MioModelManifest: Decodable, Sendable {
    public struct File: Decodable, Sendable { public let path: String; public let bytes: Int64; public let sha256: String }
    public let id: String
    public let dimensions: Int
    public let repository: String
    public let revision: String
    public let files: [File]
    public var byteCount: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") ?? Bundle.module.url(forResource: "ModelManifest", withExtension: "json") else { throw MioError("model_manifest_missing", "Model manifest is unavailable") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func valid(_ file: File, in directory: URL) throws -> Bool {
        let url = directory.appendingPathComponent(file.path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.bytes else { return false }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return digest == file.sha256
    }
    public func verify(in directory: URL) throws {
        for file in files { guard try valid(file, in: directory) else { throw MioError("model_missing", "Download or repair the local model: \(file.path)") } }
    }
}

/// Each transfer goes to a temporary file. Only the pinned, verified bytes
/// replace the model file; a failed transfer never changes a working model.
final class ModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var completion: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private let target: URL
    private let progress: @Sendable (Int64) -> Void
    private var session: URLSession?
    private let stateLock = NSLock()
    private var cancelled = false
    init(target: URL, progress: @escaping @Sendable (Int64) -> Void) { self.target = target; self.progress = progress }
    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 900
            let connection = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let aborted = stateLock.withLock { if cancelled { return true }; session=connection;return false }
            if aborted { completion?.resume(throwing:CancellationError());completion=nil;connection.invalidateAndCancel() }
            else { connection.downloadTask(with: url).resume() }
        }
    }
    func cancel() { let connection=stateLock.withLock { cancelled=true;return session };connection?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw MioError("model_download_failed", "Model download returned an unsuccessful HTTP response") }
            try FileManager.default.moveItem(at: location, to: target)
            result = .success(target)
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = result ?? .failure(error ?? MioError("model_download_failed", "Model download did not produce a file"))
        completion?.resume(with: outcome); completion = nil
        session.finishTasksAndInvalidate(); stateLock.withLock { self.session = nil }
    }
}

public enum MioModelFiles {
    public static func download(manifest: MioModelManifest, directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            if try manifest.valid(file, in: directory) { completed += file.bytes; progress(Double(completed) / Double(manifest.byteCount)); continue }
            let target = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".download")
            defer { try? FileManager.default.removeItem(at: partial) }
            let base = completed
            let transfer = ModelTransfer(target: partial) { written in progress(min(0.999, Double(base + min(written, file.bytes)) / Double(manifest.byteCount))) }
            let url = URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(file.path)")!
            do { _ = try await withTaskCancellationHandler(operation:{ try await transfer.run(url) },onCancel:{ transfer.cancel() }) }
            catch { if Task.isCancelled { throw CancellationError() };throw error }
            let temporaryDirectory = directory.appendingPathComponent("verify-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let verifyPath = temporaryDirectory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: verifyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: partial, to: verifyPath)
            guard try manifest.valid(file, in: temporaryDirectory) else { throw MioError("model_checksum_mismatch", "Model checksum differs from the pinned release") }
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: verifyPath) }
            else { try FileManager.default.moveItem(at: verifyPath, to: target) }
            completed += file.bytes; progress(Double(completed) / Double(manifest.byteCount))
        }
        try Task.checkCancellation()
        try manifest.verify(in: directory)
    }
}
