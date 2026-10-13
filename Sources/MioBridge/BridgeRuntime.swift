import Foundation
import Darwin
import Security
import CryptoKit

public struct BridgeError: Error, LocalizedError {
    public let code: String
    public let message: String
    public let details: JSONValue
    public init(_ code: String, _ message: String, details: JSONValue = .null) {
        self.code = code; self.message = message; self.details = details
    }
    public var errorDescription: String? { "\(code): \(message)" }
}

import MioCore

public enum BridgeCredential {
    case owner(String)
    case agent(String)
    var value: String { switch self { case .owner(let v), .agent(let v): return v } }
    var kind: String { switch self { case .owner: return "owner"; case .agent: return "agent" } }
}

/// No paths are compiled from the developer's environment. Each install owns its runtime directory.
public struct BridgeRuntime {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.mio.memory/Runtime", isDirectory: true)
    }
    public var socketURL: URL {
        let normal = directory.appendingPathComponent("bridge.sock")
        if normal.path.utf8.count < 104 { return normal }
        // Darwin sockaddr_un has only 104 bytes. Long home paths get a private deterministic endpoint.
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mio-\(getuid())-\(digest)", isDirectory: true)
            .appendingPathComponent("bridge.sock")
    }
    public var ownerCredentialURL: URL { directory.appendingPathComponent("owner.key") }

    public func prepare() throws {
        for folder in Set([directory, socketURL.deletingLastPathComponent()]) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    /// A local owner credential is not an agent profile. Keep this file out of profile configuration.
    public func ownerToken() throws -> String {
        try prepare()
        // flock is shared across processes and separately opened descriptors in this process.
        // The credential itself is published only after a complete, fsynced private file exists.
        let lockURL = directory.appendingPathComponent("owner.lock")
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw BridgeError("credential_lock_failed", "Cannot open the owner credential lock.") }
        defer { close(lockFD) }
        while flock(lockFD, LOCK_EX) != 0 {
            guard errno == EINTR else { throw BridgeError("credential_lock_failed", "Cannot acquire the owner credential lock.") }
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        var existing = stat()
        if lstat(ownerCredentialURL.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == geteuid(), existing.st_size <= 512 else {
                throw BridgeError("invalid_credential", "Owner credential must be a private regular file owned by this user.")
            }
            let data = try Data(contentsOf: ownerCredentialURL)
            guard let token = String(data: data, encoding: .utf8), token.count == 64,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw BridgeError("invalid_credential", "Owner credential is invalid; repair it explicitly instead of replacing it.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerCredentialURL.path)
            return token
        }
        guard errno == ENOENT else { throw BridgeError("credential_read_failed", "Cannot inspect the owner credential.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeError("credential_generation_failed", "macOS could not generate a local credential.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let temporary = directory.appendingPathComponent(".owner-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BridgeError("credential_write_failed", "Cannot create a private owner credential file.") }
        defer { close(fd); _ = unlink(temporary.path) }
        let data = Data(token.utf8)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let wrote = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if wrote < 0 && errno == EINTR { continue }
                guard wrote > 0 else { throw BridgeError("credential_write_failed", "Cannot write the owner credential.") }
                offset += wrote
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, ownerCredentialURL.path) == 0 else {
            throw BridgeError("credential_write_failed", "Cannot atomically publish the owner credential.")
        }
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
        return token
    }
}

