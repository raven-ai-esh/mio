import XCTest
import Foundation
import Darwin
import MioCore
@testable import MioBridge

final class MemoryDeliveryTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() { for url in folders { try? FileManager.default.removeItem(at: url) }; folders = []; super.tearDown() }
    private func fixture() throws -> (MioStore, URL, String, String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mio-delivery-\(UUID().uuidString)")
        folders.append(folder)
        let store = try MioStore(directory: folder.appendingPathComponent("data"))
        let space = try store.execute("space.create", params: ["name": .string("Delivery acceptance")])["id"].stringValue!
        let profile = try store.execute("profile.create", params: ["space_id": .string(space), "name": .string("Adapter"), "idempotency_key": .string(UUID().uuidString)])
        return (store, BridgeRuntime(directory: folder.appendingPathComponent("runtime")).socketURL, space, profile["token"].stringValue!)
    }
    private func metadata() -> JSONValue { .object(["transport_session_id": .string(UUID().uuidString), "request_id": .string(UUID().uuidString)]) }
    private func server(_ store: MioStore, _ endpoint: URL, observed: XCTestExpectation? = nil, handler: LocalBridgeServer.Handler? = nil) -> LocalBridgeServer {
        LocalBridgeServer(socketURL: endpoint, ownerToken: String(repeating: "a", count: 64), onDelivery: { observation, context in
            try store.observeMemoryDelivery(metadata: observation.metadata, context: context, peerPID: observation.peerPID, state: observation.state, errorCode: observation.errorCode)
            observed?.fulfill()
        }, handler: handler ?? { try store.execute($0, params: $1, context: $2) })
    }
    private func interactions(_ store: MioStore) throws -> [JSONValue] { try store.execute("snapshot")["interactions"].arrayValue }

    func testRealIPCResponseOversizeKeepsExecutionAndOriginalNoteCommit() throws {
        let (store, endpoint, space, token) = try fixture()
        let note = try store.execute("note.create", params: ["space_id": .string(space), "title": .string("Large delivery"), "body": .string(String(repeating: "x", count: 8_400_000)), "idempotency_key": .string(UUID().uuidString)])
        let observed = expectation(description: "oversize observed")
        let service = server(store, endpoint, observed: observed); try service.start(); defer { service.stop() }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .agent(token))
        XCTAssertThrowsError(try client.call("read", params: ["kind": .string("note"), "id": note["id"], "_mio_interaction": metadata()])) { XCTAssertEqual(($0 as? BridgeError)?.code, "frame_too_large") }
        wait(for: [observed], timeout: 3)
        let attempt = try XCTUnwrap(interactions(store).first)
        XCTAssertEqual(attempt["state"], .string("completed"))
        XCTAssertEqual(attempt["outcome"], .string("success"))
        XCTAssertEqual(attempt["response_delivery"], .string("frame_too_large"))
        let journal = try store.execute("read", params: ["kind": .string("session"), "id": attempt["session_id"], "limit": .number(500)])
        let deliveries = journal["events"].arrayValue.filter { $0["phase"] == .string("delivery") }
        XCTAssertEqual(deliveries.count, 1, "Small fallback error must not overwrite original response failure")
        XCTAssertEqual(deliveries[0]["observation_type"], .string("server_observed"))
        XCTAssertEqual(deliveries[0]["delivery_state"], .string("frame_too_large"))
        XCTAssertEqual(journal["events"].arrayValue.filter { $0["phase"] == .string("end") }.first?["outcome"], .string("success"))
        let persisted = try store.execute("read", params: ["kind": .string("note"), "id": note["id"]])
        XCTAssertEqual(persisted["revision_id"], note["revision_id"])
        XCTAssertEqual(persisted["body"].stringValue?.count, 8_400_000)
    }

    func testRealSocketBrokenPipePreservesCapturedReceiptAndLogsWriteFailure() throws {
        let (store, endpoint, space, token) = try fixture()
        let executed = expectation(description: "committed before peer close"), observed = expectation(description: "broken socket observed")
        let release = DispatchSemaphore(value: 0)
        let service = server(store, endpoint, observed: observed) { method, params, context in
            let result = try store.execute(method, params: params, context: context)
            executed.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            return result
        }
        try service.start(); defer { service.stop() }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(endpoint.path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(connected, 0)
        let request: JSONValue = .object(["protocol_version": .number(1), "id": .string("broken-peer"), "credential": .object(["kind": .string("agent"), "token": .string(token)]), "method": .string("note.create"), "params": .object(["space_id": .string(space), "title": .string("Committed before disconnect"), "body": .string("Persisted"), "idempotency_key": .string(UUID().uuidString), "_mio_interaction": metadata()])])
        var bytes = try request.encoded(); bytes.append(10)
        let sent = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }; XCTAssertEqual(sent, bytes.count)
        wait(for: [executed], timeout: 3)
        shutdown(fd, SHUT_RDWR); close(fd); release.signal()
        wait(for: [observed], timeout: 3)
        let attempt = try XCTUnwrap(interactions(store).first)
        XCTAssertEqual(attempt["state"], .string("completed"))
        XCTAssertEqual(attempt["receipt"]["status"], .string("local_committed"))
        XCTAssertEqual(attempt["response_delivery"], .string("socket_write_failed"))
        XCTAssertFalse(attempt["result_refs"].arrayValue.isEmpty)
        XCTAssertEqual(try store.execute("snapshot")["notes"].arrayValue.count, 1)
    }

    func testActualMCPOutputLimitIsAdapterReportWithoutChangingExecution() throws {
        let (store, endpoint, space, token) = try fixture()
        let note = try store.execute("note.create", params: ["space_id": .string(space), "title": .string("MCP wrapper limit"), "body": .string(String(repeating: "x", count: 4_300_000)), "idempotency_key": .string(UUID().uuidString)])
        let service = server(store, endpoint); try service.start(); defer { service.stop() }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .agent(token))
        let folder = endpoint.deletingLastPathComponent()
        let inputURL = folder.appendingPathComponent("frames.in"), outputURL = folder.appendingPathComponent("frames.out")
        try inputFrames(noteID: note["id"]).write(to: inputURL); FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
        defer { try? input.close(); try? output.close() }
        XCTAssertThrowsError(try MCPRunner.run(client: client, input: input, output: output)) { XCTAssertEqual(($0 as? BridgeError)?.code, "frame_too_large") }
        let attempt = try XCTUnwrap(interactions(store).first)
        XCTAssertEqual(attempt["state"], .string("completed"))
        XCTAssertEqual(attempt["response_delivery"], .string("socket_written"))
        XCTAssertEqual(attempt["adapter_delivery"], .string("stdout_write_failed"))
        let journal = try store.execute("read", params: ["kind": .string("session"), "id": attempt["session_id"], "limit": .number(500)])
        let reported = journal["events"].arrayValue.first { $0["observation_type"] == .string("adapter_report") }
        XCTAssertEqual(reported?["phase"], .string("delivery"))
        XCTAssertEqual(reported?["delivery_state"], .string("stdout_write_failed"))
        XCTAssertEqual(reported?["error_code"], .string("frame_too_large"))
        XCTAssertNotEqual(attempt["response_delivery"], .string("client_consumed"))
    }

    func testActualMCPBrokenOutputPipeReportsFailureAndDoesNotSynthesizeReply() throws {
        let (store, endpoint, _, token) = try fixture()
        let pipe = Pipe()
        let service = server(store, endpoint) { method, params, context in
            let result = try store.execute(method, params: params, context: context)
            if method == "search" { try pipe.fileHandleForReading.close() }
            return result
        }
        try service.start(); defer { service.stop() }
        let inputURL = endpoint.deletingLastPathComponent().appendingPathComponent("pipe.in")
        var bytes = Data(); for value in [initialize, JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"), "params": .object(["name": .string("search"), "arguments": .object(["query": .string("nothing")])])])] { bytes.append(try value.encoded()); bytes.append(10) }; try bytes.write(to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL); defer { try? input.close(); try? pipe.fileHandleForWriting.close() }
        XCTAssertThrowsError(try MCPRunner.run(client: LocalBridgeClient(socketURL: endpoint, credential: .agent(token)), input: input, output: pipe.fileHandleForWriting))
        let attempt = try XCTUnwrap(interactions(store).first)
        XCTAssertEqual(attempt["state"], .string("completed"))
        XCTAssertEqual(attempt["adapter_delivery"], .string("stdout_write_failed"))
        XCTAssertEqual(attempt["outcome"], .string("success"))
    }

    func testPrivateAdapterReportCannotForgeServerStateForeignAttemptOrRevokedGrant() throws {
        let (store, endpoint, space, token) = try fixture()
        let second = try store.execute("profile.create", params: ["space_id": .string(space), "name": .string("Second identity"), "idempotency_key": .string(UUID().uuidString)])
        let profileID = try store.execute("snapshot")["profiles"].arrayValue.first { $0["id"] != second["id"] }!["id"]
        let service = server(store, endpoint); try service.start(); defer { service.stop() }
        let client = LocalBridgeClient(socketURL: endpoint, credential: .agent(token))
        let supplied = metadata()
        _ = try client.call("search", params: ["query": .string("acceptance"), "_mio_interaction": supplied])
        XCTAssertThrowsError(try client.call("interaction.call.delivery", params: ["state": .string("socket_written"), "_mio_interaction": supplied]))
        let foreign = LocalBridgeClient(socketURL: endpoint, credential: .agent(second["token"].stringValue!))
        XCTAssertThrowsError(try foreign.call("interaction.call.delivery", params: ["state": .string("stdout_written"), "_mio_interaction": supplied])) { XCTAssertEqual(($0 as? BridgeError)?.code, "forbidden") }
        _ = try client.call("interaction.call.delivery", params: ["state": .string("stdout_written"), "_mio_interaction": supplied])
        let attempt = try XCTUnwrap(interactions(store).first)
        XCTAssertEqual(attempt["adapter_delivery"], .string("stdout_written"))
        _ = try store.execute("profile.revoke", params: ["profile_id": profileID])
        XCTAssertThrowsError(try client.call("interaction.call.delivery", params: ["state": .string("stdout_write_failed"), "_mio_interaction": supplied])) { XCTAssertEqual(($0 as? BridgeError)?.code, "unauthorized") }
        XCTAssertEqual(try XCTUnwrap(interactions(store).first)["adapter_delivery"], .string("stdout_written"))
        XCTAssertThrowsError(try client.call("search", params: ["query": .string("acceptance")])) { XCTAssertEqual(($0 as? BridgeError)?.code, "unauthorized") }
    }

    func testFirstMCPToolWithKnownRevokedProfileRecordsDenialWithoutModelArguments() throws {
        let (store, endpoint, space, token) = try fixture()
        let profile = try XCTUnwrap(store.execute("snapshot")["profiles"].arrayValue.first)
        _ = try store.execute("profile.revoke", params: ["profile_id": profile["id"]])
        let service = server(store, endpoint); try service.start(); defer { service.stop() }
        let folder = endpoint.deletingLastPathComponent()
        let inputURL = folder.appendingPathComponent("revoked.in"), outputURL = folder.appendingPathComponent("revoked.out")
        let capture: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"), "params": .object(["name": .string("capture"), "arguments": .object(["space_id": .string(space), "title": .string("Must not be written"), "body": .string("private rejected body"), "idempotency_key": .string("private rejected key")])])])
        var bytes = Data(); for value in [initialize, capture] { bytes.append(try value.encoded()); bytes.append(10) }; try bytes.write(to: inputURL); FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
        defer { try? input.close(); try? output.close() }
        try MCPRunner.run(client: LocalBridgeClient(socketURL: endpoint, credential: .agent(token)), input: input, output: output)
        let replies = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        XCTAssertEqual(replies[1]["result"]["isError"], .bool(true))
        XCTAssertEqual(replies[1]["result"]["structuredContent"]["code"], .string("unauthorized"))
        let snapshot = try store.execute("snapshot"), attempt = try XCTUnwrap(snapshot["interactions"].arrayValue.first)
        XCTAssertEqual(snapshot["notes"].arrayValue.count, 0)
        XCTAssertEqual(attempt["method"], .string("note.create"))
        XCTAssertEqual(attempt["outcome"], .string("error"))
        XCTAssertEqual(attempt["error_code"], .string("unauthorized"))
        XCTAssertEqual(attempt["response_delivery"], .string("socket_written"))
        XCTAssertEqual(attempt["adapter_delivery"], .null, "Revoked adapter cannot grant itself reporting authority")
        XCTAssertEqual(snapshot["events"].arrayValue.filter { ["start", "end"].contains($0["phase"].stringValue ?? "") }.count, 2)
        let journalText = String(decoding: try snapshot.encoded(), as: UTF8.self)
        XCTAssertFalse(journalText.contains("private rejected body"))
        XCTAssertFalse(journalText.contains("private rejected key"))
        XCTAssertFalse(journalText.contains("Must not be written"))
    }

    private var initialize: JSONValue { .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-06-18"), "clientInfo": .object(["name": .string("Delivery acceptance"), "version": .string("1")])])]) }
    private func inputFrames(noteID: JSONValue) throws -> Data {
        var bytes = Data()
        for value in [initialize, JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"), "params": .object(["name": .string("read"), "arguments": .object(["kind": .string("note"), "id": noteID])])])] { bytes.append(try value.encoded()); bytes.append(10) }
        return bytes
    }
}
