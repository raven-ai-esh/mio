import Foundation
import Darwin
import MioCore

/// JSON-RPC over newline-delimited stdio. stdout is reserved exclusively for protocol replies.
public enum MCPRunner {
    public static let toolNames = ["search", "read", "capture", "revise", "link"]

    public static func run(client: LocalBridgeClient, input: FileHandle = .standardInput,
                           output: FileHandle = .standardOutput) throws {
        guard client.isAgent else {
            throw BridgeError("invalid_mcp_profile", "MCP requires a scoped agent token, never an owner credential.")
        }
        // A broken output pipe must return an observed failure, not terminate via SIGPIPE.
        _ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = BoundedLineReader(handle: input, limit: 8_388_608)
        var initialized = false
        let transportSessionID = UUID().uuidString.lowercased()
        var clientName = "", clientVersion = ""
        var sessionStarted = false
        func metadata(requestID: String? = nil) -> JSONValue {
            var values: [String: JSONValue] = ["transport_session_id": .string(transportSessionID),
                "client_name": .string(clientName), "client_version": .string(clientVersion),
                "session_label": .string("MCP memory session")]
            if let requestID { values["request_id"] = .string(requestID) }
            return .object(values)
        }
        func sendToolReply(_ reply: JSONValue, metadata: JSONValue) throws {
            do { try send(reply, output: output) }
            catch {
                let code = (error as? BridgeError)?.code ?? "stdout_write_failed"
                _ = try? client.call("interaction.call.delivery", params: ["state": .string("stdout_write_failed"),
                    "error_code": .string(code), "_mio_interaction": metadata])
                throw error
            }
            _ = try? client.call("interaction.call.delivery", params: ["state": .string("stdout_written"), "_mio_interaction": metadata])
        }
        while true {
            let line: Data
            do {
                guard let next = try reader.next() else {
                    if sessionStarted {
                        // Revoked/expired credentials cannot close by escalating to owner authority.
                        // Failed closure leaves a truthful open trace for dead-adapter recovery.
                        _ = try? client.call("interaction.session.end", params: ["_mio_interaction": metadata()])
                    }
                    return
                }
                line = next
            } catch let error as BridgeError where error.code == "frame_too_large" {
                try send(rpcError(id: .null, code: -32600, message: error.message), output: output)
                continue
            }
            if line.isEmpty { continue }
            let request: JSONValue
            do { request = try JSONValue.decode(line) }
            catch {
                try send(rpcError(id: .null, code: -32700, message: "Invalid JSON."), output: output)
                continue
            }
            guard case .object(let object) = request, request["jsonrpc"].stringValue == "2.0",
                  let method = request["method"].stringValue else {
                try send(rpcError(id: request["id"], code: -32600, message: "Invalid JSON-RPC request."), output: output)
                continue
            }
            let hasID = object["id"] != nil
            if !hasID {
                // Notifications carry no reply. No model parameter can select an owner context.
                continue
            }
            let id = request["id"]
            if method == "initialize" {
                guard !initialized else {
                    try send(rpcError(id: id, code: -32600, message: "Mio is already initialized on this transport."), output: output)
                    continue
                }
                clientName = String((request["params"]["clientInfo"]["name"].stringValue ?? "").prefix(120))
                clientVersion = String((request["params"]["clientInfo"]["version"].stringValue ?? "").prefix(80))
                let version = request["params"]["protocolVersion"].stringValue ?? ""
                let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
                let chosen = supported.contains(version) ? version : supported[0]
                initialized = true
                try send(rpcResult(id: id, result: .object([
                    "protocolVersion": .string(chosen),
                    "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                    "serverInfo": .object(["name": .string("mio"), "version": .string("0.4.2")]),
                    "instructions": .string("Use read(kind=spaces) without id to discover authorized space names, IDs, read/write permissions and default_space_id. Choose by name, then use its ID in search.space_ids or capture.space_id; duplicate names remain distinct IDs. Search notes and memory interaction history first. History records Mio searches, reads and changes, not your chats. Read exact evidence before capturing or revising. Preserve source IDs and expected revisions. Spaces are scoped by your profile. This MCP connection has its own transport session and is not identified as a Codex chat.")
                ])), output: output)
                continue
            }
            guard initialized else {
                try send(rpcError(id: id, code: -32000, message: "Initialize Mio before calling tools."), output: output)
                continue
            }
            switch method {
            case "ping": try send(rpcResult(id: id, result: .object([:])), output: output)
            case "tools/list":
                try send(rpcResult(id: id, result: .object(["tools": .array(toolDefinitions)])), output: output)
            case "tools/call":
                guard let name = request["params"]["name"].stringValue, toolNames.contains(name) else {
                    try send(rpcError(id: id, code: -32602, message: "Unknown Mio tool or invalid arguments."), output: output)
                    continue
                }
                let operation = ["search": "search", "read": "read", "capture": "note.create", "revise": "note.update", "link": "link.create"][name]!
                let callMetadata = metadata(requestID: UUID().uuidString.lowercased())
                do {
                    if !sessionStarted {
                        _ = try client.call("interaction.session.begin", params: ["_mio_interaction": metadata()])
                        sessionStarted = true
                    }
                } catch {
                    let failure = error as? BridgeError ?? BridgeError("service_error", error.localizedDescription)
                    if failure.code == "unauthorized" {
                        // A recognized revoked profile can record an identity-only denial;
                        // this control never executes the domain operation or grants access.
                        _ = try? client.call("interaction.call.reject", params: ["method": .string(operation),
                            "error_code": .string("unauthorized"), "_mio_interaction": callMetadata])
                    }
                    let detail: JSONValue = .object(["code": .string(failure.code), "message": .string(failure.message), "details": failure.details])
                    try send(rpcResult(id: id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: try detail.encoded(), as: UTF8.self))])]), "isError": .bool(true), "structuredContent": detail])), output: output)
                    continue
                }
                guard case .object(let arguments) = request["params"]["arguments"] else {
                    _ = try? client.call("interaction.call.reject", params: ["method": .string(operation), "error_code": .string("invalid_params"), "_mio_interaction": callMetadata])
                    try sendToolReply(rpcError(id: id, code: -32602, message: "Tool arguments must be an object."), metadata: callMetadata)
                    continue
                }
                let schema = toolDefinitions.first { $0["name"].stringValue == name }!["inputSchema"]
                let hasReadID = name != "read" || arguments["kind"] == .string("spaces") || arguments["id"] != nil
                if !hasReadID || !validArguments(arguments, schema: schema) {
                    _ = try? client.call("interaction.call.reject", params: ["method": .string(operation), "error_code": .string("invalid_params"), "_mio_interaction": callMetadata])
                    try sendToolReply(rpcError(id: id, code: -32602, message: "Tool arguments do not match the Mio schema."), metadata: callMetadata)
                    continue
                }
                let reply: JSONValue
                do {
                    var scopedArguments = arguments
                    scopedArguments["_mio_interaction"] = callMetadata
                    let result = try client.call(operation, params: scopedArguments)
                    var structured = result.objectValue
                    var images: [JSONValue] = []
                    if let data = result["media"]["data"].stringValue, result["media"]["mime_type"] == .string("image/png") {
                        images.append(.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(data)]))
                        structured["media"] = .object(["mime_type": .string("image/png"), "delivery": .string("mcp_image_content")])
                    }
                    let clean = structured.isEmpty ? result : JSONValue.object(structured)
                    let text = String(data: try clean.encoded(), encoding: .utf8) ?? "{}"
                    var toolResult: [String: JSONValue] = ["content": .array([.object(["type": .string("text"), "text": .string(text)])] + images), "isError": .bool(false)]
                    if case .object = clean { toolResult["structuredContent"] = clean }
                    reply = rpcResult(id: id, result: .object(toolResult))
                } catch {
                    let failure = error as? BridgeError ?? BridgeError("service_error", error.localizedDescription)
                    let detail: JSONValue = .object(["code": .string(failure.code), "message": .string(failure.message), "details": failure.details])
                    let text = String(data: try detail.encoded(), encoding: .utf8) ?? failure.message
                    reply = rpcResult(id: id, result: .object([
                        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                        "isError": .bool(true), "structuredContent": detail
                    ]))
                }
                try sendToolReply(reply, metadata: callMetadata)
            default:
                try send(rpcError(id: id, code: -32601, message: "Method not found."), output: output)
            }
        }
    }

    private static func rpcResult(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    private static func rpcError(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
    private static func send(_ value: JSONValue, output: FileHandle) throws {
        var data = try value.encoded()
        guard data.count <= 8_388_608 else { throw BridgeError("frame_too_large", "MCP result exceeds the output byte limit.") }
        data.append(10)
        try output.write(contentsOf: data)
    }

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    private static func validArguments(_ args: [String: JSONValue], schema: JSONValue) -> Bool {
        let properties = schema["properties"].objectValue
        guard args.keys.allSatisfy({ properties[$0] != nil }),
              schema["required"].arrayValue.allSatisfy({ args[$0.stringValue ?? ""] != nil }) else { return false }
        for (key, value) in args {
            let property = properties[key]!
            switch property["type"].stringValue {
            case "string": if case .string = value {} else { return false }
            case "integer":
                guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                      number >= 0, number <= 1_000_000_000 else { return false }
            case "array":
                guard case .array(let items) = value, items.allSatisfy({ if case .string = $0 { return true }; return false }) else { return false }
            default: return false
            }
            if case .array(let values) = property["enum"], !values.contains(value) { return false }
        }
        return true
    }
    private static let string: JSONValue = .object(["type": .string("string")])
    private static let strings: JSONValue = .object(["type": .string("array"), "items": string])
    private static let integer: JSONValue = .object(["type": .string("integer")])
    private static func tool(_ name: String, _ description: String, _ inputSchema: JSONValue, readOnly: Bool) -> JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": inputSchema,
                 "annotations": .object(["readOnlyHint": .bool(readOnly), "openWorldHint": .bool(false)])])
    }
    public static var toolDefinitions: [JSONValue] {
        [
            tool("search", "Hybrid BM25 plus local EmbeddingGemma2 search across authorized note fragments, PDF pages, image/OCR sources and Mio operation history. Inspect semantic_state/search_mode for fallback or incomplete indexing. Hits are candidates, not factual answers; preserve source_id/source_group_id/revision_id/locator and read the exact source. History describes only Mio searches, reads and writes.", schema([
                "query": string, "scope": .object(["type": .string("string"), "enum": .array(["all", "notes", "files", "history"].map(JSONValue.string))]),
                "space_ids": strings, "limit": integer, "max_chars": integer, "as_of": string
            ], required: ["query"]), readOnly: true),
            tool("read", "Use kind=spaces without id to list authorized space names, IDs, can_read/can_write and default_space_id. Choose a name, then use the returned ID in search.space_ids or capture.space_id. Duplicate names have different IDs. offset/limit page the catalog (default50, maximum200); follow next_offset. Other kinds require id: read a note, event, session or exact source. For a search source_id, use kind=source to receive its exact version, locator, text or MCP image content. File IDs show the original preview; offset is the zero-based PDF page. Current note reads include paged incoming/outgoing links from the same graph used by [[wikilinks]] and link, with neighbor IDs and small metadata. offset/limit page links (default50, maximum200); follow links_next_offset. Exact historical revisions omit current graph links. URL sources are not fetched. Authorization is checked anew.", schema([
                "kind": .object(["type": .string("string"), "enum": .array(["spaces", "note", "event", "session", "source"].map(JSONValue.string))]),
                "id": string, "revision_id": string, "offset": integer, "limit": integer
            ], required: ["kind"]), readOnly: true),
            tool("capture", "Create durable knowledge with sources and an idempotency key. Optionally capture one immutable PDF or PNG/JPEG/HEIC/WebP/TIFF image using file_name, mime_type and file_base64 together (decoded max5MB; no filesystem paths). body is an annotation. Local commit precedes background indexing and cloud delivery. Repeating the key requires identical content.", schema([
                "space_id": string, "title": string, "body": string, "status": string, "source_ids": strings, "idempotency_key": string,
                "file_name": string, "mime_type": string, "file_base64": string
            ], required: ["space_id", "title", "body", "idempotency_key"]), readOnly: false),
            tool("revise", "Create a note version from expected_revision. A stale base preserves your draft and reports revision_conflict. Check and resolve the conflict instead of reporting success.", schema([
                "note_id": string, "expected_revision": string, "title": string, "body": string, "status": string, "source_ids": strings, "idempotency_key": string
            ], required: ["note_id", "expected_revision", "title", "body", "idempotency_key"]), readOnly: false),
            tool("link", "Connect two notes with a typed directional relation. You need write access to the source and read access to the destination. Linking does not grant access or mount other spaces.", schema([
                "from_note_id": string, "to_note_id": string, "kind": string
            ], required: ["from_note_id", "to_note_id", "kind"]), readOnly: false)
        ]
    }
}

/// Used by both MCP and Codex RPC. POSIX read returns available pipe bytes rather than waiting for a full buffer.
final class BoundedLineReader {
    private let handle: FileHandle
    private let limit: Int
    private var buffer = Data()
    private var ended = false
    private var draining = false
    init(handle: FileHandle, limit: Int) { self.handle = handle; self.limit = limit }
    func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newline) + 1)
                if draining || line.count > limit {
                    draining = false
                    throw BridgeError("frame_too_large", "The input frame exceeds its byte limit.")
                }
                return line
            }
            if ended {
                if draining { draining = false; throw BridgeError("frame_too_large", "The input frame exceeds its byte limit.") }
                if buffer.isEmpty { return nil }
                let tail = buffer; buffer = Data(); return tail
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BridgeError("input_error", "Cannot read protocol input.") }
            if count == 0 { ended = true; continue }
            if draining {
                if let nl = bytes.prefix(count).firstIndex(of: 10) {
                    buffer = Data(bytes[(nl + 1)..<count]); draining = false
                    throw BridgeError("frame_too_large", "The input frame exceeds its byte limit.")
                }
            } else {
                buffer.append(contentsOf: bytes.prefix(count))
                if buffer.count > limit, !buffer.contains(10) { buffer.removeAll(keepingCapacity: true); draining = true }
            }
        }
    }
}
