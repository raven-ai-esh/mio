import XCTest
import Foundation
import MioCore
@testable import MioBridge

final class MCPInteractionMetadataTests: XCTestCase {
    func testAdapterCreatesTruthfulBoundedSessionAndRejectsModelSelectedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mio-mcp-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = BridgeRuntime(directory: root.appendingPathComponent("runtime")).socketURL
        let records = CapturedMetadata()
        let controls = CapturedMetadata()
        let server = LocalBridgeServer(socketURL: endpoint, ownerToken: String(repeating: "a", count: 64)) { method, params, actor in
            guard case .agent(let token) = actor, token == "scoped-token" else { throw MioError("unauthorized", "Agent context required") }
            if method.hasPrefix("interaction.") {
                controls.add(.object(["method": .string(method), "metadata": params["_mio_interaction"] ?? .null]))
                return .object(["session_state": .string(method == "interaction.session.end" ? "closed" : "active")])
            }
            records.add(params["_mio_interaction"] ?? .null)
            return .object(["method": .string(method), "actor": .string("agent")])
        }
        try server.start(); defer { server.stop() }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .agent("scoped-token"))
        func run(_ requests: [JSONValue], name: String) throws -> [JSONValue] {
            let inputURL = root.appendingPathComponent(name + ".in"), outputURL = root.appendingPathComponent(name + ".out")
            var bytes = Data()
            for request in requests { bytes.append(try request.encoded()); bytes.append(10) }
            try bytes.write(to: inputURL)
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
            defer { try? input.close(); try? output.close() }
            try MCPRunner.run(client: client, input: input, output: output)
            return try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        }
        let initialize: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-06-18"), "clientInfo": .object([
                "name": .string(String(repeating: "human", count: 100)), "version": .string(String(repeating: "v", count: 100)),
                "threadId": .string("not-a-trusted-codex-thread")])])])
        let search: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
            "params": .object(["name": .string("search"), "arguments": .object(["query": .string("memory")])])])
        let read: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(3), "method": .string("tools/call"),
            "params": .object(["name": .string("read"), "arguments": .object(["kind": .string("note"), "id": .string("note")])])])
        let malicious: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(4), "method": .string("tools/call"),
            "params": .object(["name": .string("search"), "arguments": .object(["query": .string("memory"),
                "_mio_interaction": .object(["transport_session_id": .string("chosen-by-model"), "actor": .string("human")])])])])
        let firstReplies = try run([initialize, search, read, malicious, initialize], name: "first")
        XCTAssertEqual(firstReplies[1]["result"]["structuredContent"]["actor"], .string("agent"))
        XCTAssertEqual(firstReplies[3]["error"]["code"].intValue, -32602)
        XCTAssertEqual(firstReplies[4]["error"]["code"].intValue, -32600)
        XCTAssertEqual(records.values.count, 2)
        let first = records.values[0], same = records.values[1]
        XCTAssertEqual(first["transport_session_id"], same["transport_session_id"])
        XCTAssertNotNil(UUID(uuidString: first["transport_session_id"].stringValue!))
        XCTAssertEqual(first["client_name"].stringValue?.count, 120)
        XCTAssertEqual(first["client_version"].stringValue?.count, 80)
        XCTAssertEqual(first["session_label"], .string("MCP memory session"))
        XCTAssertNotEqual(first["request_id"], same["request_id"])
        XCTAssertNotNil(UUID(uuidString: first["request_id"].stringValue!))
        XCTAssertEqual(first["adapter_pid"].intValue, Int(getpid()))
        XCTAssertEqual(first["threadId"], .null)
        XCTAssertEqual(first["origin_thread_id"], .null)
        XCTAssertEqual(first["actor"], .null)
        XCTAssertEqual(controls.values.map { $0["method"].stringValue! }, ["interaction.session.begin", "interaction.call.delivery", "interaction.call.delivery", "interaction.call.reject", "interaction.call.delivery", "interaction.session.end"])
        XCTAssertEqual(controls.values.filter { $0["method"] == .string("interaction.call.delivery") }.count, 3)
        _ = try run([initialize, search], name: "second")
        XCTAssertEqual(records.values.count, 3)
        XCTAssertNotEqual(records.values[2]["transport_session_id"], first["transport_session_id"])
        XCTAssertEqual(controls.values.count, 9)
    }

    func testKernelPeerPIDOverridesCallerSuppliedPID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mio-peer-pid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = BridgeRuntime(directory: root.appendingPathComponent("runtime")).socketURL
        let server = LocalBridgeServer(socketURL: endpoint, ownerToken: String(repeating: "a", count: 64)) { _, params, _ in params["_mio_interaction"] ?? .null }
        try server.start(); defer { server.stop() }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .agent("profile"))
        let received = try client.call("search", params: ["_mio_interaction": .object(["adapter_pid": .number(123456), "transport_session_id": .string(UUID().uuidString)])])
        XCTAssertEqual(received["adapter_pid"].intValue, Int(getpid()))
        XCTAssertNotEqual(received["adapter_pid"].intValue, 123456)
    }
}

private final class CapturedMetadata {
    private let lock = NSLock()
    private var stored: [JSONValue] = []
    var values: [JSONValue] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ value: JSONValue) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
}
