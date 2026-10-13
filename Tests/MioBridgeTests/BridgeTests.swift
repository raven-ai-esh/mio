import XCTest
import Foundation
import Darwin
import MioCore
@testable import MioBridge

final class BridgeTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []; super.tearDown()
    }
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mio-bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url); return url
    }
    private var owner: String { String(repeating: "a", count: 64) }
    private func rawCall(endpoint: URL, bytes: Data) throws -> JSONValue {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("test_socket", "Cannot create test socket.") }
        defer { close(fd) }
        var noSignal: Int32 = 1, interval = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(endpoint.path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw BridgeError("test_socket", "Cannot connect test socket.") }
        var frame = bytes; frame.append(10)
        let sent = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(sent, frame.count)
        var response = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = Darwin.recv(fd, &chunk, chunk.count, 0)
            guard read > 0 else { throw BridgeError("test_socket", "Test service did not respond.") }
            response.append(contentsOf: chunk.prefix(read))
            if let nl = response.firstIndex(of: 10) { return try JSONValue.decode(response.prefix(upTo: nl)) }
        }
    }

    func testRuntimeCredentialsArePersistentAndPrivate() throws {
        let runtime = BridgeRuntime(directory: try folder())
        let token = try runtime.ownerToken()
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(try runtime.ownerToken(), token)
        let attributes = try FileManager.default.attributesOfItem(atPath: runtime.ownerCredentialURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let long = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(String(repeating: "long", count: 30))
        XCTAssertLessThan(BridgeRuntime(directory: long).socketURL.path.utf8.count, 104)
    }

    func testDefaultRuntimeUsesMemoryAppNamespaceWithoutPreparingLegacyDirectory() {
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.mio.memory/Runtime", isDirectory: true)
        XCTAssertEqual(BridgeRuntime.defaultDirectory, expected)
        XCTAssertFalse(BridgeRuntime.defaultDirectory.path.hasSuffix("/Mio/Runtime"))
    }

    func testConcurrentFirstOwnerCredentialPublicationNeverExposesPartialKey() throws {
        for _ in 0..<10 {
            let runtime = BridgeRuntime(directory: try folder())
            let results = ConcurrentOwnerResults()
            DispatchQueue.concurrentPerform(iterations: 20) { _ in
                do { results.add(.success(try runtime.ownerToken())) }
                catch { results.add(.failure(error)) }
            }
            XCTAssertEqual(results.errors, [], "Concurrent creators must observe the complete winning key.")
            XCTAssertEqual(results.tokens.count, 20)
            XCTAssertEqual(Set(results.tokens).count, 1)
            XCTAssertEqual(try String(contentsOf: runtime.ownerCredentialURL, encoding: .utf8).count, 64)
            let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: runtime.directory.path).filter { $0.hasSuffix(".tmp") }
            XCTAssertTrue(temporaryFiles.isEmpty)
        }
    }

    func testMalformedExistingOwnerCredentialIsPreservedAndExplicit() throws {
        let runtime = BridgeRuntime(directory: try folder())
        try runtime.prepare()
        let invalid = Data("partial-key".utf8)
        try invalid.write(to: runtime.ownerCredentialURL)
        XCTAssertThrowsError(try runtime.ownerToken()) { XCTAssertEqual(($0 as? BridgeError)?.code, "invalid_credential") }
        XCTAssertEqual(try Data(contentsOf: runtime.ownerCredentialURL), invalid)
    }

    func testRealIPCAuthenticatesOwnerAndAgentAndNeverTreatsMissingTokenAsHuman() throws {
        let runtime = BridgeRuntime(directory: try folder())
        let server = LocalBridgeServer(socketURL: runtime.socketURL, ownerToken: owner) { method, params, context in
            switch context {
            case .human: return .object(["actor": .string("human"), "method": .string(method), "params": .object(params)])
            case .agent(let token):
                guard token == "selected-profile" else { throw MioError("unauthorized", "Profile invalid or revoked.") }
                return .object(["actor": .string("agent")])
            }
        }
        try server.start(); defer { server.stop() }
        let human = LocalBridgeClient(socketURL: runtime.socketURL, credential: .owner(owner))
        XCTAssertEqual(try human.call("echo", params: ["context": .string("agent")])["actor"], .string("human"))
        let agent = LocalBridgeClient(socketURL: runtime.socketURL, credential: .agent("selected-profile"))
        XCTAssertEqual(try agent.call("echo", params: ["context": .string("human")])["actor"], .string("agent"))
        for credential in [BridgeCredential.owner(""), .owner("wrong"), .agent(""), .agent("revoked")] {
            XCTAssertThrowsError(try LocalBridgeClient(socketURL: runtime.socketURL, credential: credential).call("echo")) {
                XCTAssertEqual(($0 as? BridgeError)?.code, "unauthorized")
            }
        }
    }

    func testIPCDetailsSurviveAndSecondServiceCannotReplaceActiveSocket() throws {
        let endpoint = BridgeRuntime(directory: try folder()).socketURL
        let server = LocalBridgeServer(socketURL: endpoint, ownerToken: owner) { _, _, _ in
            throw MioError("revision_conflict", "Draft preserved.", details: .object(["revision_id": .string("draft")]))
        }
        try server.start(); defer { server.stop() }
        let other = LocalBridgeServer(socketURL: endpoint, ownerToken: owner) { _, _, _ in .null }
        XCTAssertThrowsError(try other.start()) { XCTAssertEqual(($0 as? BridgeError)?.code, "service_already_running") }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .owner(owner))
        XCTAssertThrowsError(try client.call("note.update")) {
            XCTAssertEqual(($0 as? BridgeError)?.details["revision_id"], .string("draft"))
        }
    }

    func testRawIPCRejectsMissingCredentialsMalformedFramesAndProtocolMismatchBeforeHandler() throws {
        let endpoint = BridgeRuntime(directory: try folder()).socketURL
        let server = LocalBridgeServer(socketURL: endpoint, ownerToken: owner) { _, _, _ in
            XCTFail("Unauthorized or malformed frame reached the core handler."); return .null
        }
        try server.start(); defer { server.stop() }
        let absent: JSONValue = .object(["protocol_version": .number(1), "id": .string("test"), "method": .string("snapshot"), "params": .object([:])])
        XCTAssertEqual(try rawCall(endpoint: endpoint, bytes: absent.encoded())["error"]["code"], .string("unauthorized"))
        var mismatch = absent.objectValue; mismatch["protocol_version"] = .number(2)
        XCTAssertEqual(try rawCall(endpoint: endpoint, bytes: JSONValue.object(mismatch).encoded())["error"]["code"], .string("protocol_mismatch"))
        mismatch["protocol_version"] = .number(1.5)
        XCTAssertEqual(try rawCall(endpoint: endpoint, bytes: JSONValue.object(mismatch).encoded())["error"]["code"], .string("protocol_mismatch"))
        XCTAssertEqual(try rawCall(endpoint: endpoint, bytes: Data("{invalid".utf8))["error"]["code"], .string("invalid_json"))
        var pipelined = try absent.encoded(); pipelined.append(contentsOf: Data("\n{}".utf8))
        XCTAssertEqual(try rawCall(endpoint: endpoint, bytes: pipelined)["error"]["code"], .string("invalid_frame"))
    }

    func testIPCAutoLaunchAndOversizeRequestError() throws {
        let endpoint = BridgeRuntime(directory: try folder()).socketURL
        let server = LocalBridgeServer(socketURL: endpoint, ownerToken: owner) { _, _, _ in .object(["ok": .bool(true)]) }
        defer { server.stop() }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .owner(owner), timeout: 1) { try server.start() }
        XCTAssertEqual(try client.call("ping")["ok"], .bool(true))
        XCTAssertThrowsError(try client.call("capture", params: ["body": .string(String(repeating: "x", count: 34_000_000))])) {
            XCTAssertEqual(($0 as? BridgeError)?.code, "frame_too_large")
        }
        let unavailable = LocalBridgeClient(socketURL: endpoint.deletingLastPathComponent().appendingPathComponent("missing.sock"), credential: .owner(owner), timeout: 0.1)
        XCTAssertThrowsError(try unavailable.call("ping")) { XCTAssertEqual(($0 as? BridgeError)?.code, "service_unavailable") }
    }

    func testMCPStdioOnlyExposesScopedToolsAndPreservesErrorSemantics() throws {
        let root = try folder(), endpoint = BridgeRuntime(directory: root).socketURL
        let server = LocalBridgeServer(socketURL: endpoint, ownerToken: owner) { method, _, context in
            guard case .agent(let token) = context, token == "selected" else { throw MioError("unauthorized", "Invalid profile.") }
            if method == "note.update" { throw MioError("revision_conflict", "Draft preserved.", details: .object(["revision_id": .string("draft")])) }
            return .object(["method": .string(method), "committed": .bool(method == "note.create")])
        }
        try server.start(); defer { server.stop() }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capture","arguments":{"space_id":"s","title":"Title","body":"Body","idempotency_key":"k"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"revise","arguments":{"note_id":"n","expected_revision":"r","title":"Title","body":"Body","idempotency_key":"k2"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"profile.create","arguments":{}}}"#,
            "{invalid-json"
        ]
        let inputURL = root.appendingPathComponent("input"), outputURL = root.appendingPathComponent("output")
        try Data((requests.joined(separator: "\n") + "\n").utf8).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
        defer { try? input.close(); try? output.close() }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .agent("selected"))
        try MCPRunner.run(client: client, input: input, output: output)
        let replies = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        XCTAssertEqual(replies.count, 6) // no response to notification and no stdout diagnostics
        XCTAssertEqual(replies[1]["result"]["tools"].arrayValue.map { $0["name"].stringValue! }, MCPRunner.toolNames)
        let readSchema = replies[1]["result"]["tools"].arrayValue.first { $0["name"].stringValue == "read" }!["inputSchema"]
        XCTAssertTrue(readSchema["properties"]["kind"]["enum"].arrayValue.contains(.string("source")))
        XCTAssertFalse(replies[2]["result"]["isError"].boolValue)
        XCTAssertEqual(replies[2]["result"]["structuredContent"]["method"], .string("note.create"))
        XCTAssertTrue(replies[3]["result"]["isError"].boolValue)
        XCTAssertEqual(replies[3]["result"]["structuredContent"]["details"]["revision_id"], .string("draft"))
        XCTAssertEqual(replies[4]["error"]["code"].intValue, -32602)
        XCTAssertEqual(replies[5]["error"]["code"].intValue, -32700)
        XCTAssertThrowsError(try MCPRunner.run(client: .init(socketURL: endpoint, credential: .owner(owner)), input: input, output: output)) {
            XCTAssertEqual(($0 as? BridgeError)?.code, "invalid_mcp_profile")
        }
    }

    func testBoundedLineReaderRecoversAfterOversizeFrame() throws {
        let path = try folder().appendingPathComponent("frames")
        try Data((String(repeating: "x", count: 30_000) + "\n{}\n[]\n{\"кириллица\":true}\n").utf8).write(to: path)
        let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
        let reader = BoundedLineReader(handle: handle, limit: 100)
        XCTAssertThrowsError(try reader.next()) { XCTAssertEqual(($0 as? BridgeError)?.code, "frame_too_large") }
        XCTAssertEqual(try reader.next(), Data("{}".utf8))
        XCTAssertEqual(try reader.next(), Data("[]".utf8))
        XCTAssertEqual(try reader.next(), Data("{\"кириллица\":true}".utf8))
        XCTAssertNil(try reader.next())
    }

    func testCoreThroughRealIPCEnforcesOneHopScopeRevocationAndDurableCommit() throws {
        let root = try folder(), endpoint = BridgeRuntime(directory: root.appendingPathComponent("runtime")).socketURL
        let store = try MioStore(directory: root.appendingPathComponent("db"))
        let server = LocalBridgeServer(socketURL: endpoint, ownerToken: owner) { try store.execute($0, params: $1, context: $2) }
        try server.start(); defer { server.stop() }
        let human = LocalBridgeClient(socketURL: endpoint, credential: .owner(owner))
        let a = try human.call("space.create", params: ["name": .string("A")])["id"].stringValue!
        let b = try human.call("space.create", params: ["name": .string("B")])["id"].stringValue!
        let c = try human.call("space.create", params: ["name": .string("C")])["id"].stringValue!
        let noteB = try human.call("note.create", params: ["space_id": .string(b), "title": .string("shared constellation"), "body": .string("read-only source")])
        _ = try human.call("note.create", params: ["space_id": .string(c), "title": .string("secret constellation"), "body": .string("must remain hidden")])
        let connection = try human.call("connection.create", params: ["from_space_id": .string(a), "to_space_id": .string(b), "access": .string("read")])
        _ = try human.call("connection.create", params: ["from_space_id": .string(b), "to_space_id": .string(c), "access": .string("write")])
        let profile = try human.call("profile.create", params: ["name": .string("test Codex"), "space_id": .string(a)])
        let agent = LocalBridgeClient(socketURL: endpoint, credential: .agent(profile["token"].stringValue!))
        let captured = try agent.call("note.create", params: ["space_id": .string(a), "title": .string("own constellation"), "body": .string("durable captured body"), "idempotency_key": .string("capture-1")])
        XCTAssertEqual(captured["receipt"]["status"], .string("local_committed"))
        let repeated = try agent.call("note.create", params: ["space_id": .string(a), "title": .string("own constellation"), "body": .string("durable captured body"), "idempotency_key": .string("capture-1")])
        XCTAssertEqual(repeated["id"], captured["id"])
        XCTAssertEqual(repeated["revision_id"], captured["revision_id"])
        XCTAssertEqual(repeated["receipt"], captured["receipt"])
        XCTAssertTrue(repeated["replayed"].boolValue)
        XCTAssertNotEqual(repeated["interaction_id"], captured["interaction_id"])
        let found = try agent.call("search", params: ["query": .string("constellation")])["results"].arrayValue
        XCTAssertEqual(found.count, 2)
        XCTAssertFalse(found.contains { $0["space_id"].stringValue == c })
        let noteSource = try agent.call("read", params: ["kind": .string("source"), "id": noteB["id"]])
        XCTAssertEqual(noteSource["body"], .string("read-only source"))
        let revisionSource = try agent.call("read", params: ["kind": .string("source"), "id": noteB["revision_id"]])
        XCTAssertEqual(revisionSource["body"], .string("read-only source"))
        XCTAssertEqual(revisionSource["revision_id"], noteB["revision_id"])
        XCTAssertThrowsError(try agent.call("note.create", params: ["space_id": .string(b), "title": .string("forbidden"), "body": .string("x")])) {
            XCTAssertEqual(($0 as? BridgeError)?.code, "forbidden")
        }
        XCTAssertThrowsError(try agent.call("profile.create", params: ["name": .string("escalation"), "space_id": .string(c)])) {
            XCTAssertEqual(($0 as? BridgeError)?.code, "forbidden")
        }
        _ = try human.call("connection.delete", params: ["connection_id": connection["id"]])
        XCTAssertThrowsError(try agent.call("read", params: ["kind": .string("note"), "id": noteB["id"]])) {
            XCTAssertEqual(($0 as? BridgeError)?.code, "forbidden")
        }
        for sourceID in [noteB["id"], noteB["revision_id"]] {
            XCTAssertThrowsError(try agent.call("read", params: ["kind": .string("source"), "id": sourceID])) {
                XCTAssertEqual(($0 as? BridgeError)?.code, "forbidden")
            }
        }
        _ = try human.call("profile.revoke", params: ["profile_id": profile["id"]])
        XCTAssertThrowsError(try agent.call("search", params: ["query": .string("constellation")])) {
            XCTAssertEqual(($0 as? BridgeError)?.code, "unauthorized")
        }
        server.stop()
        let reopened = try MioStore(directory: root.appendingPathComponent("db"))
        let persisted = try reopened.execute("read", params: ["kind": .string("note"), "id": captured["id"]])
        XCTAssertEqual(persisted["body"], .string("durable captured body"))
    }
}

private final class ConcurrentOwnerResults {
    private let lock = NSLock()
    private(set) var tokens: [String] = []
    private(set) var errors: [String] = []
    func add(_ result: Result<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        switch result { case .success(let token): tokens.append(token); case .failure(let error): errors.append(error.localizedDescription) }
    }
}
