import Foundation
import Darwin
import MioCore

private let bridgeProtocolVersion = 1
private let requestByteLimit = 33_554_432
private let responseByteLimit = 8_388_608

private func socketAddress(_ url: URL) throws -> sockaddr_un {
    let bytes = Array(url.path.utf8)
    var address = sockaddr_un()
    guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw BridgeError("invalid_endpoint", "The local socket path is too long or invalid.")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes + [0])
    }
    return address
}

private func withAddress<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = try socketAddress(url)
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func configureSocket(_ fd: Int32, timeout: TimeInterval) {
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

private func writeFrame(_ value: JSONValue, fd: Int32, limit: Int) throws {
    var bytes = try value.encoded()
    guard bytes.count <= limit else { throw BridgeError("frame_too_large", "The local response exceeds its byte limit.") }
    bytes.append(10)
    try bytes.withUnsafeBytes { buffer in
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError("connection_lost", "Cannot write to the local service.") }
            sent += count
        }
    }
}

private func readFrame(fd: Int32, limit: Int) throws -> JSONValue {
    var bytes = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = Darwin.recv(fd, &chunk, chunk.count, 0)
        if count < 0 && errno == EINTR { continue }
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            throw BridgeError("timeout", "The local service did not reply before the timeout.")
        }
        guard count > 0 else { throw BridgeError("connection_lost", "The local connection ended before a complete frame.") }
        let received = Data(chunk.prefix(count))
        if let newline = received.firstIndex(of: 10) {
            bytes.append(received.prefix(upTo: newline))
            guard bytes.count <= limit else { throw BridgeError("frame_too_large", "The local frame exceeds its byte limit.") }
            // A connection carries one request only; reject trailing requests instead of silently consuming them.
            guard received.dropFirst(newline + 1).allSatisfy({ $0 == 13 || $0 == 10 || $0 == 32 }) else {
                throw BridgeError("invalid_frame", "Only one request is allowed per local connection.")
            }
            do { return try JSONValue.decode(bytes) }
            catch { throw BridgeError("invalid_json", "The local frame is not valid JSON.") }
        }
        bytes.append(received)
        guard bytes.count <= limit else { throw BridgeError("frame_too_large", "The local frame exceeds its byte limit.") }
    }
}

private func secureEqual(_ first: String, _ second: String) -> Bool {
    let a = Array(first.utf8), b = Array(second.utf8)
    var delta = a.count ^ b.count
    for i in 0..<max(a.count, b.count) { delta |= Int((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)) }
    return delta == 0
}

public final class LocalBridgeServer {
    public typealias Handler = (String, [String: JSONValue], AccessContext) throws -> JSONValue
    /// Trusted server observations describe socket delivery, never client consumption.
    public struct DeliveryObservation {
        public let metadata: JSONValue
        public let peerPID: Int32
        public let state: String
        public let errorCode: String?
    }
    public typealias DeliveryObserver = (DeliveryObservation, AccessContext) throws -> Void
    public let socketURL: URL
    private let ownerToken: String
    private let handler: Handler
    private let onDelivery: DeliveryObserver?
    private var descriptor: Int32 = -1
    private var endpointInode: ino_t = 0
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "mio.bridge.accept")
    private let requestQueue = DispatchQueue(label: "mio.bridge.requests", attributes: .concurrent)
    private let connections = DispatchSemaphore(value: 16)

    public init(socketURL: URL, ownerToken: String, onDelivery: DeliveryObserver? = nil, handler: @escaping Handler) {
        self.socketURL = socketURL; self.ownerToken = ownerToken; self.onDelivery = onDelivery; self.handler = handler
    }
    deinit { stop() }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor == -1 else { return }
        guard ownerToken.count >= 32 else { throw BridgeError("invalid_credential", "Owner credential must have at least 32 characters.") }
        let folder = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        // Never remove a live service endpoint. Only stale sockets owned by this user are replaced.
        if FileManager.default.fileExists(atPath: socketURL.path) {
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                configureSocket(probe, timeout: 1)
                let connected = try withAddress(socketURL) { Darwin.connect(probe, $0, $1) }
                close(probe)
                if connected == 0 { throw BridgeError("service_already_running", "Another Mio service already owns this endpoint.") }
            }
            var statbuf = stat()
            guard lstat(socketURL.path, &statbuf) == 0, statbuf.st_uid == geteuid(),
                  (statbuf.st_mode & S_IFMT) == S_IFSOCK else {
                throw BridgeError("unsafe_endpoint", "The existing local endpoint is not a socket owned by this user.")
            }
            guard unlink(socketURL.path) == 0 else { throw BridgeError("endpoint_unavailable", "Cannot remove the stale local endpoint.") }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("endpoint_unavailable", "Cannot create the local service socket.") }
        configureSocket(fd, timeout: 10)
        do {
            let result = try withAddress(socketURL) { Darwin.bind(fd, $0, $1) }
            guard result == 0, chmod(socketURL.path, 0o600) == 0, listen(fd, 16) == 0 else {
                throw BridgeError("endpoint_unavailable", "Cannot listen on the local endpoint: \(String(cString: strerror(errno))).")
            }
        } catch { close(fd); throw error }
        descriptor = fd
        var endpointStat = stat()
        if lstat(socketURL.path, &endpointStat) == 0 { endpointInode = endpointStat.st_ino }
        acceptQueue.async { [weak self] in self?.acceptConnections(fd: fd) }
    }

    public func stop() {
        lock.lock()
        let fd = descriptor, inode = endpointInode; descriptor = -1; endpointInode = 0
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR); close(fd)
            var endpointStat = stat()
            // Another process may already have replaced a closed socket while this instance stops.
            if lstat(socketURL.path, &endpointStat) == 0, endpointStat.st_ino == inode { unlink(socketURL.path) }
        }
    }

    private func acceptConnections(fd: Int32) {
        while true {
            lock.lock(); let running = descriptor == fd; lock.unlock()
            guard running else { return }
            let peer = Darwin.accept(fd, nil, nil)
            if peer < 0 {
                if errno == EINTR { continue }
                return
            }
            configureSocket(peer, timeout: 10)
            guard connections.wait(timeout: .now()) == .success else { close(peer); continue }
            requestQueue.async { [weak self] in
                defer { close(peer); self?.connections.signal() }
                self?.serve(peer)
            }
        }
    }

    private func serve(_ peer: Int32) {
        var requestID: JSONValue = .null
        var deliveryAttempt: (JSONValue, AccessContext, pid_t)?
        var responseDeliveryFailed = false
        func observe(_ state: String, errorCode: String? = nil) {
            guard let (metadata, context, peerPID) = deliveryAttempt else { return }
            // Observation persistence must not replace or invalidate a committed operation.
            try? onDelivery?(.init(metadata: metadata, peerPID: peerPID, state: state, errorCode: errorCode), context)
        }
        func writeObserved(_ response: JSONValue) throws {
            do {
                try writeFrame(response, fd: peer, limit: responseByteLimit)
                observe("socket_written")
            } catch {
                responseDeliveryFailed = true
                let code = (error as? BridgeError)?.code ?? "serialization_failed"
                observe(code == "frame_too_large" ? "frame_too_large" : "socket_write_failed", errorCode: code)
                throw error
            }
        }
        do {
            var peerUID: uid_t = 0, peerGID: gid_t = 0
            guard getpeereid(peer, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                throw BridgeError("unauthorized", "Local service access requires the same macOS user.")
            }
            let request = try readFrame(fd: peer, limit: requestByteLimit)
            requestID = request["id"]
            guard request["protocol_version"] == .number(Double(bridgeProtocolVersion)) else {
                throw BridgeError("protocol_mismatch", "The client and Mio service use different protocol versions.")
            }
            guard let token = request["credential"]["token"].stringValue, !token.isEmpty else {
                throw BridgeError("unauthorized", "A local owner credential or agent profile token is required.")
            }
            let context: AccessContext
            switch request["credential"]["kind"].stringValue {
            case "owner":
                guard secureEqual(token, ownerToken) else { throw BridgeError("unauthorized", "The local owner credential is invalid.") }
                context = .human
            case "agent": context = .agent(token: token)
            default: throw BridgeError("unauthorized", "The local credential kind is invalid.")
            }
            guard let method = request["method"].stringValue, !method.isEmpty,
                  case .object(let params) = request["params"] else {
                throw BridgeError("invalid_request", "A method and object parameters are required.")
            }
            var stampedParams = params
            var peerPID: pid_t = 0
            var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
            if getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) != 0 { peerPID = 0 }
            if case .object(var metadata) = params["_mio_interaction"] {
                metadata.removeValue(forKey: "adapter_pid")
                if peerPID > 0 {
                    metadata["adapter_pid"] = .number(Double(peerPID))
                }
                stampedParams["_mio_interaction"] = .object(metadata)
                if ["search", "read", "note.create", "note.update", "link.create", "interaction.call.reject"].contains(method) {
                    deliveryAttempt = (.object(metadata), context, peerPID)
                }
            }
            let result = try handler(method, stampedParams, context)
            try writeObserved(.object(["id": requestID, "protocol_version": .number(Double(bridgeProtocolVersion)), "result": result]))
        } catch {
            let code: String, message: String, details: JSONValue
            if let failure = error as? BridgeError { code = failure.code; message = failure.message; details = failure.details }
            else if let failure = error as? MioError { code = failure.code; message = failure.message; details = failure.details }
            else { code = "service_error"; message = error.localizedDescription; details = .null }
            let response: JSONValue = .object(["id": requestID, "protocol_version": .number(Double(bridgeProtocolVersion)),
                "error": .object(["code": .string(code), "message": .string(message), "details": details])])
            if responseDeliveryFailed {
                // A smaller error frame must not overwrite the failed original response.
                try? writeFrame(response, fd: peer, limit: responseByteLimit)
            } else { try? writeObserved(response) }
        }
    }
}

public final class LocalBridgeClient {
    public let socketURL: URL
    private let credential: BridgeCredential
    private let autoLaunch: (() throws -> Void)?
    private let timeout: TimeInterval
    var isAgent: Bool { if case .agent = credential { return true }; return false }
    public init(socketURL: URL, credential: BridgeCredential, timeout: TimeInterval = 15, autoLaunch: (() throws -> Void)? = nil) {
        self.socketURL = socketURL; self.credential = credential; self.timeout = max(0.1, timeout); self.autoLaunch = autoLaunch
    }

    public func call(_ method: String, params: [String: JSONValue] = [:]) throws -> JSONValue {
        guard !credential.value.isEmpty else { throw BridgeError("unauthorized", "An explicit local credential is required.") }
        var fd = try connectSocket()
        if fd < 0, let launch = autoLaunch {
            try launch()
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                Thread.sleep(forTimeInterval: 0.1)
                fd = try connectSocket()
            } while fd < 0 && Date() < deadline
        }
        guard fd >= 0 else { throw BridgeError("service_unavailable", "Mio is not running or could not be started.") }
        defer { close(fd) }
        let id = UUID().uuidString
        let request: JSONValue = .object([
            "protocol_version": .number(Double(bridgeProtocolVersion)), "id": .string(id),
            "credential": .object(["kind": .string(credential.kind), "token": .string(credential.value)]),
            "method": .string(method), "params": .object(params)
        ])
        try writeFrame(request, fd: fd, limit: requestByteLimit)
        let response = try readFrame(fd: fd, limit: responseByteLimit)
        guard response["protocol_version"] == .number(Double(bridgeProtocolVersion)) else {
            throw BridgeError("protocol_mismatch", "The running Mio service has a different protocol version.")
        }
        guard response["id"].stringValue == id else { throw BridgeError("invalid_response", "The local response does not match this request.") }
        if case .object(let error) = response["error"] {
            throw BridgeError(error["code"]?.stringValue ?? "service_error", error["message"]?.stringValue ?? "Local request failed.", details: error["details"] ?? .null)
        }
        guard response.objectValue["result"] != nil else { throw BridgeError("invalid_response", "The local service omitted its result.") }
        return response["result"]
    }

    private func connectSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("endpoint_unavailable", "Cannot create a local client socket.") }
        configureSocket(fd, timeout: timeout)
        let connected: Int32
        do { connected = try withAddress(socketURL) { Darwin.connect(fd, $0, $1) } }
        catch { close(fd); throw error }
        if connected != 0 { close(fd); return -1 }
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            close(fd); throw BridgeError("unauthorized", "The local service is not owned by this macOS user.")
        }
        return fd
    }
}
