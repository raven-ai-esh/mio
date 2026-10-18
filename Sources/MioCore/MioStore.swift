import Foundation
import CryptoKit
import CSQLite

public final class MioStore: @unchecked Sendable {
    let db: SQLite
    let lock = NSRecursiveLock()
    public let directory: URL
    let deviceID: String
    static let schema = 2
    let runtimeID = UUID().uuidString.lowercased()
    var activeInteractionID: String?
    var interactionReplies: [String: Result<JSONValue,MioError>] = [:]
    var interactionReplyOrder: [String] = []
    var semanticQueryEncoder: ((String) throws -> MioSemanticQuery)?
    var retrievalMode: MioRetrievalMode = .hybrid
    var sourceImageRenderer: ((JSONValue,Data,JSONValue) throws -> Data)?
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.db = try SQLite(path: directory.appendingPathComponent("mio.sqlite").path)
        try db.exec("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        let previous = try db.rows("SELECT value FROM metadata WHERE key='schema'").first?["value"]
        if let previous, !["1","2"].contains(previous) { throw MioError("schema_incompatible", "This database requires a different Mio version") }
        try db.exec("INSERT OR REPLACE INTO metadata VALUES('schema','2')")
        let existing = try db.rows("SELECT value FROM metadata WHERE key='device_id'").first?["value"]
        deviceID = existing ?? UUID().uuidString.lowercased()
        try db.exec("INSERT OR IGNORE INTO metadata VALUES('device_id',?)", [deviceID])
        try db.exec("CREATE TABLE IF NOT EXISTS entities(kind TEXT NOT NULL,id TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(kind,id))")
        try db.exec("CREATE INDEX IF NOT EXISTS entity_space ON entities(kind,json_extract(json,'$.space_id'))")
        try db.exec("CREATE INDEX IF NOT EXISTS entity_session ON entities(kind,json_extract(json,'$.session_id'))")
        try db.exec("CREATE INDEX IF NOT EXISTS entity_session_page ON entities(kind,json_extract(json,'$.session_id'),json_extract(json,'$.timestamp'),json_extract(json,'$.source_sequence'),json_extract(json,'$.source_id'),id)")
        try db.exec("CREATE INDEX IF NOT EXISTS entity_state ON entities(kind,json_extract(json,'$.state'))")
        try db.exec("CREATE INDEX IF NOT EXISTS local_memory_sessions ON entities(kind,json_extract(json,'$.source'),json_extract(json,'$.session_state'),json_extract(json,'$.owner_device_id'))")
        try db.exec("CREATE INDEX IF NOT EXISTS entity_note ON entities(kind,json_extract(json,'$.note_id'))")
        try db.exec("CREATE INDEX IF NOT EXISTS entity_link_from ON entities(kind,json_extract(json,'$.from_note_id'),id)")
        try db.exec("CREATE INDEX IF NOT EXISTS entity_link_to ON entities(kind,json_extract(json,'$.to_note_id'),id)")
        try db.exec("CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY,kind TEXT NOT NULL,entity_id TEXT NOT NULL,json TEXT NOT NULL)")
        try db.exec("CREATE INDEX IF NOT EXISTS record_lookup ON records(kind,entity_id)")
        try db.exec("CREATE TABLE IF NOT EXISTS outbox(record_id TEXT PRIMARY KEY)")
        try db.exec("CREATE TABLE IF NOT EXISTS audit(id TEXT PRIMARY KEY,json TEXT NOT NULL)")
        try db.exec("CREATE TABLE IF NOT EXISTS idempotency(key TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,json TEXT NOT NULL)")
        try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(id UNINDEXED,kind UNINDEXED,space_id UNINDEXED,revision_id UNINDEXED,title,text,timestamp UNINDEXED,status UNINDEXED,tokenize='unicode61 remove_diacritics 2')")
        try db.exec("INSERT INTO search_index(search_index,rank) VALUES('secure-delete',1)")
        try ensureSearchMapping()
        try ensureSourceIndex()
        if previous == "1" { try upgradeSourceIndexLocationSignatures() }
        try ensureSourceIndexQueue()
        try ensureWorkspaceGenerations()
        try ensureRecordInventory()
        try ensureInteractionProjection()
        try ensureRecordApplications()
        try db.transaction { try applyAvailableRecords(rejectInvalid:false) }
        try recoverMemoryInteractions()
    }
    public func execute(_ method: String, params: [String: JSONValue] = [:], context: AccessContext = .human) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        try recoverMemoryInteractions()
        var call: InteractionAttempt?
        let authenticatedAccess = try? scope(context)
        let revokedRejection=method == "interaction.call.reject" && params.string("error_code") == "unauthorized"
        if authenticatedAccess == nil, let identity = try revokedIdentity(context), tracedMethod(method,identity) || revokedRejection {
            // A recognized revoked identity may leave an owner-visible denied attempt;
            // it receives no grants, domain data, reply cache, or lifecycle authority.
            try? db.transaction {
                let knownMethods: Set<String> = ["search","read","note.create","note.update","note.delete","note.restore","note.history","note.resolve","link.create","link.delete"]
                let deniedMethod=revokedRejection ? params.string("method") : method
                let label = knownMethods.contains(deniedMethod) ? deniedMethod : "unrecognized_operation"
                let rejected = try beginInteraction(label,params,identity,identityOnly:true)
                if rejected.created { try finishInteraction(rejected,scope:identity,method:label,result:.null,errorCode:"unauthorized") }
            }
        }
        if let access = authenticatedAccess, tracedMethod(method,access) {
            call = try db.transaction { try beginInteraction(method,params,access) }
            if let call, !call.created, let old = try entity("interaction",call.id), old["end_event_id"].stringValue == nil { throw MioError("interaction_in_progress","This request is already in progress; no duplicate execution was started") }
            if let call, let old = try entity("interaction",call.id), old["end_event_id"].stringValue != nil {
                try requireVisibility(old,access); try authorizeMethod(method,params,access)
                if let reply = interactionReplies[call.id] {
                    switch reply { case .success(let value): try authorizeCachedReply(value,access); return value; case .failure(let error): try authorizeCachedReply(error.details,access); throw error }
                }
                if ["note.create","note.update"].contains(method), !params.string("idempotency_key").isEmpty {
                    let key = access.actor + ":" + method + ":" + params.string("idempotency_key")
                    if let row = try db.rows("SELECT json FROM idempotency WHERE key=?",[key]).first { let cached = try decode(row["json"]!); try authorizeCachedReply(cached,access); return responseWithTrace(domainReplayResult(cached),call:call,replayed:old["replayed"].boolValue,original:old["original_interaction_id"].stringValue) }
                }
                if old["state"].stringValue == "interrupted" { throw MioError("interaction_interrupted","The original memory request was interrupted; use a fresh request identifier") }
                if let code = old["error_code"].stringValue { throw MioError(code,"The original memory request failed") }
                throw MioError("reply_unavailable","The original execution is recorded, but its reply is no longer retained; use a fresh request identifier")
            }
        }
        do {
            let semantic=try prepareSearchEncoding(method,params,context)
            try Task.checkCancellation()
            activeInteractionID = call?.id
            defer { activeInteractionID = nil }
            let result = try perform(method,params:params,context:context,interaction:call,semantic:semantic)
            if let call { cacheInteractionReply(call.id,.success(result)) }
            return result
        } catch {
            let error:Error = error is CancellationError ? MioError("cancelled","The memory request was cancelled"):error
            if let call, let access = authenticatedAccess, try entity("interaction",call.id)?["end_event_id"].stringValue == nil {
                try db.transaction { try finishInteraction(call,scope:access,method:method,result:.null,errorCode:(error as? MioError)?.code ?? "operation_failed") }
            }
            if let call { let failure = error as? MioError ?? MioError("operation_failed",error.localizedDescription); cacheInteractionReply(call.id,.failure(failure)) }
            if (error as? MioError)?.code != "revision_conflict" {
                let actor = (try? scope(context).actor) ?? "unauthorized"
                let audit: JSONValue = .object(["id":.string(UUID().uuidString.lowercased()),"timestamp":.string(now()),"actor":.string(actor),"device_id":.string(deviceID),"method":.string(method),"request":auditRequest(params),"outcome":.string("error"),"error_code":.string((error as? MioError)?.code ?? "operation_failed")])
                try? db.transaction { try db.exec("INSERT INTO audit VALUES(?,?)",[audit["id"].stringValue!,try encode(audit)]) }
            }
            throw error
        }
    }
    func cacheInteractionReply(_ id: String, _ reply: Result<JSONValue,MioError>) {
        if case .success(let value) = reply, (try? value.encoded().count) ?? Int.max > 262144 { return }
        if interactionReplies[id] == nil { interactionReplyOrder.append(id) }
        interactionReplies[id] = reply
        while interactionReplyOrder.count > 32 { interactionReplies.removeValue(forKey:interactionReplyOrder.removeFirst()) }
    }
    func perform(_ method: String, params: [String: JSONValue], context: AccessContext, interaction: InteractionAttempt? = nil, semantic:Result<MioSemanticQuery,MioError>? = nil) throws -> JSONValue {
        let result: JSONValue = try db.transaction {
            let access = try scope(context)
            try authorizeMethod(method, params, access)
            let idem = ["note.create","note.update","profile.create"].contains(method) ? params.string("idempotency_key") : ""
            let key = access.actor + ":" + method + ":" + idem
            let fingerprint = hash(try JSONValue.object(semanticParams(params)).encoded())
            if !idem.isEmpty, let row = try db.rows("SELECT fingerprint,json FROM idempotency WHERE key=?", [key]).first {
                guard row["fingerprint"] == fingerprint else { throw MioError("idempotency_mismatch", "This idempotency key was used for another request") }
                let cached = try decode(row["json"]!)
                try authorizeCachedReply(cached,access)
                let original = cached["call_trace"]["interaction_id"].stringValue ?? cached["interaction_id"].stringValue
                if let original, let saved = try entity("interaction",original) { try requireVisibility(saved,access) }
                var replay = domainReplayResult(cached)
                if let interaction { replay = responseWithTrace(replay,call:interaction,replayed:true,original:original); try finishInteraction(interaction,scope:access,method:method,result:replay,errorCode:replay["_error"].stringValue,replayed:true,original:original) }
                return replay

            }
            var result = try dispatch(method, params, access,semantic:semantic)
            if isMutation(method) {
                var values = result.objectValue
                values["receipt"] = .object(["status": .string("local_committed"), "operation_id": .string(UUID().uuidString.lowercased()), "committed_at": .string(now()), "cloud_status": .string(["profile.create","profile.revoke","sync.ack","sync.queue","search.rebuild"].contains(method) ? "not_applicable" : "pending")])
                result = .object(values)
            }
            if let interaction { result = responseWithTrace(result,call:interaction,replayed:false); try finishInteraction(interaction,scope:access,method:method,result:result,errorCode:result["_error"].stringValue) }
            if !idem.isEmpty { var cached = result.objectValue; if method == "profile.create" { cached.removeValue(forKey:"token") }; try db.exec("INSERT INTO idempotency VALUES(?,?,?)", [key, fingerprint, try encode(.object(cached))]) }
            let audit: JSONValue = .object(["id": .string(UUID().uuidString.lowercased()), "timestamp": .string(now()), "actor": .string(access.actor), "device_id":.string(deviceID), "method": .string(method), "request":auditRequest(params), "result_refs":auditRefs(result), "space_ids": .array(access.readable.sorted().map(JSONValue.string)), "result_ids": resultIDs(result), "outcome": .string(result["_error"].stringValue == nil ? "success" : "conflict")])
            if !["snapshot","diagnostics","replica.export","replica.record","replica.merge","sync.pending","sync.status","sync.inventory","sync.ack","sync.queue"].contains(method) { try db.exec("INSERT INTO audit VALUES(?,?)", [audit["id"].stringValue!, try encode(audit)]) }
            return result
        }
        if let error = result["_error"].stringValue { throw MioError(error, "The note changed. Your submitted draft was preserved as a conflicting version.", details: result) }
        if method == "history.purge" { interactionReplies.removeAll(); interactionReplyOrder.removeAll(); try db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        return result
    }
    public func currentChangeToken() throws -> String {
        lock.lock(); defer { lock.unlock() }
        try recoverMemoryInteractions()
        let external = try db.rows("PRAGMA data_version").first?["data_version"] ?? "unknown"
        let local = try db.rows("SELECT total_changes() AS total").first?["total"] ?? "unknown"
        return external + ":" + local
    }
    struct Scope { let actor: String; let human: Bool; let readable: Set<String>; let writable: Set<String>; let homeSpace: String? }
    func revokedIdentity(_ context: AccessContext) throws -> Scope? {
        guard case .agent(let token) = context, !token.isEmpty else { return nil }
        let digest = hash(Data(token.utf8))
        guard let profile = try all("profile").first(where:{$0["token_hash"].stringValue == digest && $0["revoked"].boolValue}), let home=profile["space_id"].stringValue, let space=try entity("space",home), !space["deleted"].boolValue else { return nil }
        return Scope(actor:profile["id"].stringValue!,human:false,readable:[],writable:[],homeSpace:home)
    }
    func scope(_ context: AccessContext) throws -> Scope {
        let spaces = try all("space").filter { !$0["deleted"].boolValue }.compactMap { $0["id"].stringValue }
        switch context {
        case .human: return Scope(actor: "human", human: true, readable: Set(spaces), writable: Set(spaces), homeSpace:nil)
        case .agent(let token):
            let digest = hash(Data(token.utf8))
            guard !token.isEmpty, let profile = try all("profile").first(where: { $0["token_hash"].stringValue == digest && !$0["revoked"].boolValue }), let root = profile["space_id"].stringValue, spaces.contains(root) else { throw MioError("unauthorized", "Invalid or revoked agent profile") }
            var read: Set<String> = [root], write: Set<String> = [root]
            for connection in try all("connection") where !connection["deleted"].boolValue && connection["from_space_id"].stringValue == root {
                if let target = connection["to_space_id"].stringValue, spaces.contains(target) { read.insert(target); if connection["access"].stringValue == "write" { write.insert(target) } }
            }
            return Scope(actor: profile["id"].stringValue!, human: false, readable: read, writable: write, homeSpace:root)
        }
    }
    func requireSpace(_ id: String, _ scope: Scope, write: Bool = false) throws {
        guard scope.human || (write ? scope.writable : scope.readable).contains(id) else { throw MioError("forbidden", "Space is unavailable or access is not permitted") }
        guard let space = try entity("space", id), !space["deleted"].boolValue else { throw MioError(scope.human ? "not_found" : "forbidden", "Space is unavailable or access is not permitted") }
    }
    func requireEntity(_ kind: String, _ id: String, _ scope: Scope, write: Bool = false, allowDeleted: Bool = false) throws -> JSONValue {
        guard let stored = try entity(kind, id), allowDeleted || !stored["deleted"].boolValue else { throw MioError(scope.human ? "not_found" : "forbidden", "Entity is unavailable or access is not permitted") }
        let item = try currentOwnership(stored,kind:kind)
        if !scope.human && !(write ? scope.writable : scope.readable).contains(item["space_id"].stringValue ?? "") { throw MioError("forbidden", "Entity is unavailable or access is not permitted") }
        try requireVisibility(item,scope)
        try requireSpace(item["space_id"].stringValue ?? "", scope, write: write)
        return item
    }
    func authorizeMethod(_ method: String, _ p: [String: JSONValue], _ s: Scope) throws {
        if !s.human {
            let allowed: Set<String> = ["snapshot", "search", "read", "note.create", "note.update", "note.delete", "note.restore", "note.history", "note.resolve", "link.create", "link.delete", "interaction.session.begin", "interaction.session.end", "interaction.call.begin", "interaction.call.reject", "interaction.call.delivery"]
            guard allowed.contains(method) else { throw MioError("forbidden", "This operation requires the local owner") }
        }
        if method.hasPrefix("note.") && method != "note.create" { _ = try requireEntity("note", p.required("note_id"), s, write: method != "note.history", allowDeleted: ["note.history", "note.restore"].contains(method)) }
        if method == "note.create" { try requireSpace(p.required("space_id"), s, write: true) }
    }
    func isMutation(_ method: String) -> Bool { !["snapshot", "search", "read", "note.history", "replica.export", "replica.record", "sync.pending", "sync.status", "sync.inventory", "archive.export", "markdown.export", "diagnostics"].contains(method) }
    func now() -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: Date()) }
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func encode(_ v: JSONValue) throws -> String { String(decoding: try v.encoded(), as: UTF8.self) }
    func decode(_ text: String) throws -> JSONValue { try JSONValue.decode(Data(text.utf8)) }
    func entity(_ kind: String, _ id: String) throws -> JSONValue? { try db.rows("SELECT json FROM entities WHERE kind=? AND id=?", [kind, id]).first.map { try decode($0["json"]!) } }
    func all(_ kind: String) throws -> [JSONValue] { try db.rows("SELECT json FROM entities WHERE kind=? ORDER BY id", [kind]).map { try decode($0["json"]!) } }
    func put(_ kind: String, _ value: JSONValue) throws { try db.exec("INSERT INTO entities VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET json=excluded.json WHERE entities.json IS NOT excluded.json", [kind, value["id"].stringValue!, try encode(value)]) }
    func record(_ kind: String, entityID: String, data: JSONValue) throws -> JSONValue {
        let r: JSONValue = .object(["id": .string(UUID().uuidString.lowercased()), "kind": .string(kind), "entity_id": .string(entityID), "data": data, "timestamp": .string(now()), "device_id": .string(deviceID)])
        try insertRecord(r, pending: true)
        try applyAvailableRecords(rejectInvalid:false)
        return r
    }
    func insertRecord(_ input: JSONValue, pending: Bool) throws {
        let r = try redacted(input)
        guard let id = r["id"].stringValue, let kind = r["kind"].stringValue, let entityID = r["entity_id"].stringValue else { throw MioError("invalid_replica", "Record missing identifiers") }
        if let old = try db.rows("SELECT json FROM records WHERE id=?", [id]).first {
            let original = try decode(old["json"]!), canonicalOld = try redacted(original)
            if canonicalOld != r {
                if canonicalOld["data"]["purged"].boolValue { return }
                guard r["data"]["purged"].boolValue else { throw MioError("record_conflict", "Immutable record content differs") }
            }
            if original != r {
                try db.exec("UPDATE records SET json=? WHERE id=?",[try encode(r),id])
                try db.exec("INSERT OR IGNORE INTO outbox VALUES(?)",[id])
                try apply(r)
            }
            return
        }
        try db.exec("INSERT INTO records VALUES(?,?,?,?)", [id, kind, entityID, try encode(r)])
        if pending { try db.exec("INSERT INTO outbox VALUES(?)", [id]) }
        if try canApply(r) { try apply(r) }
    }
    func records(_ kind: String, _ entityID: String) throws -> [JSONValue] { try db.rows("SELECT json FROM records WHERE kind=? AND entity_id=?", [kind,entityID]).map { try decode($0["json"]!) } }
    func auditRequest(_ params: [String:JSONValue]) -> JSONValue {
        var request: [String:JSONValue] = [:]
        for key in ["scope","kind","id","note_id","space_id","session_id","revision_id","expected_revision","offset","limit","max_chars","as_of"] { if let value = params[key] { request[key] = value } }
        if let query = params["query"]?.stringValue { request["query_hash"] = .string(hash(Data(query.utf8))); request["query_chars"] = .number(Double(query.count)) }
        return automaticTrace(.object(request))
    }
    func auditRefs(_ value: JSONValue) -> JSONValue {
        let items = value["results"].arrayValue.isEmpty ? [value] : value["results"].arrayValue
        return automaticTrace(.array(items.map { item in var d: [String:JSONValue] = [:]; for key in ["id","kind","note_id","revision_id","session_id","source_id"] { if item[key] != .null { d[key] = item[key] } }; return .object(d) }))
    }
    func resultIDs(_ value: JSONValue) -> JSONValue {
        var ids = [String]()
        for key in ["id", "note_id", "revision_id", "space_id", "session_id"] { if let id = value[key].stringValue { ids.append(id) } }
        for row in value["results"].arrayValue { if let id = row["id"].stringValue { ids.append(id) } }
        return automaticTrace(.array(ids.map(JSONValue.string)))
    }
    func apply(_ r: JSONValue) throws {
        try applyRecord(r)
        try db.exec("DELETE FROM pending_record_applications WHERE record_id=?",[r["id"].stringValue!])
    }
    private func applyRecord(_ r: JSONValue) throws {
        let kind = r["kind"].stringValue!, id = r["entity_id"].stringValue!
        var d = r["data"].objectValue
        if kind == "revision" { try put("revision", .object(d)); try refreshNote(d["note_id"]!.stringValue!); return }
        if kind == "note.assets" { try refreshNote(id); return }
        if kind == "note.delete" { try refreshNote(id); return }
        if kind == "note.move" { try latest("note_location",id,d,r); try refreshNote(id); return }
        if kind == "note.redact" { try redactNote(id); return }
        if kind == "session.purge" { try purgeProjection(id); return }
        if kind == "event" {
            let sessionID = d["session_id"]!.stringValue!
            if try d["purged"]?.boolValue == true || isPurged(sessionID) { return }
            if try entity("event",d["id"]!.stringValue!) == .object(d) { return }
            let wasNew = try entity("event",d["id"]!.stringValue!) == nil
            try put("event", .object(d)); try indexEvent(.object(d)); try projectInteraction(.object(d))
            if wasNew { try db.exec("UPDATE entities SET json=json_set(json,'$.event_count',coalesce(json_extract(json,'$.event_count'),0)+1) WHERE kind='session' AND id=?",[sessionID]) }
            return
        }
        if kind == "session" {
            if try isPurged(id) { d["deleted"] = .bool(true) }
            try latest(kind, id, d, r); try refreshSession(id); return
        }
        if kind == "session.restore" {
            try put("session_restore", .object(["id": r["id"], "session_id": .string(id), "purge_ids": r["data"]["purge_ids"]]))
            try latest("session", id, d, r); try refreshSession(id); return
        }
        if ["space", "link", "connection", "profile", "attachment"].contains(kind) { try latest(kind,id,d,r); return }
        throw MioError("invalid_replica", "Unsupported record kind \(kind)")
    }
    func latest(_ kind: String, _ id: String, _ data: [String: JSONValue], _ record: JSONValue) throws {
        let current = try entity(kind, id)
        var d = data; d["id"] = .string(id); d["last_record"] = record["id"]; d["record_timestamp"] = record["timestamp"]
        if current?["deleted"].boolValue == true && !d["deleted", default: .null].boolValue && kind != "session" { return }
        if current?["revoked"].boolValue == true && kind == "profile" { return }
        let oldKey = (current?["record_timestamp"].stringValue ?? "") + (current?["last_record"].stringValue ?? "")
        let newKey = (record["timestamp"].stringValue ?? "") + (record["id"].stringValue ?? "")
        if current == nil || newKey > oldKey || d["deleted", default: .null].boolValue || d["revoked", default: .null].boolValue { try put(kind, .object(d)) }
    }
    func refreshNote(_ noteID: String) throws {
        let revs = try revisions(noteID)
        guard !revs.isEmpty else { return }
        guard Set(revs.compactMap { $0["space_id"].stringValue }).count == 1 else { throw MioError("invalid_replica","One note cannot belong to multiple spaces") }
        let parents = Set(revs.flatMap { $0["parent_ids"].arrayValue.compactMap(\.stringValue) })
        let heads = revs.filter { !parents.contains($0["id"].stringValue!) }.sorted { ($0["timestamp"].stringValue! + $0["id"].stringValue!) < ($1["timestamp"].stringValue! + $1["id"].stringValue!) }
        guard let selected = heads.last else { throw MioError("invalid_replica", "Revision ancestry contains a cycle") }
        let cleared = Set(revs.flatMap { $0["cleared_deletions"].arrayValue.compactMap(\.stringValue) })
        let deleted = try records("note.delete", noteID).contains { !cleared.contains($0["id"].stringValue!) }
        let previous = try entity("note",noteID)
        var n = selected.objectValue
        let location=try entity("note_location",noteID)
        if let location { n["space_id"]=location["space_id"]; n["location_id"]=location["last_record"] }
        n["asset_ids"] = .array(try noteAssetBindings(noteID,revision:selected,location:location))
        n["id"] = .string(noteID); n["revision_id"] = selected["id"]; n["updated_at"] = selected["timestamp"]
        n["deleted"] = .bool(deleted); n["has_conflict"] = .bool(heads.count > 1); n["head_revision_ids"] = .array(heads.map { $0["id"] })
        try put("note", .object(n))
        if let previous,previous["space_id"] != n["space_id"] { try relocateSourceIndex(.object(n),previous:previous) }
        try db.exec("UPDATE source_fragments SET current=0 WHERE note_id=? AND (json_extract(json,'$.indexed_note_revision')<>? OR ?='1')",[noteID,n["revision_id"]!.stringValue!,deleted || n["purged"]?.boolValue == true ? "1":"0"])
        if !deleted && n["status"]?.stringValue != "purged" {
            try indexDocument(kind:"note",id:noteID,space:n["space_id"]!.stringValue!,revision:selected["id"].stringValue!,title:n["title"]!.stringValue!,text:n["body"]!.stringValue!,timestamp:n["updated_at"]!.stringValue!,status:n["status"]!.stringValue!)
        } else { try removeSearchDocument(kind:"note",id:noteID) }

    }
    func isPurged(_ id: String) throws -> Bool {
        let clears = Set(try all("session_restore").filter { $0["session_id"].stringValue == id }.flatMap { $0["purge_ids"].arrayValue.compactMap(\.stringValue) })
        return try records("session.purge",id).contains { !clears.contains($0["id"].stringValue!) }
    }
    func purgeProjection(_ id: String) throws {
        if !(try isPurged(id)) { return }
        interactionReplies.removeAll(); interactionReplyOrder.removeAll()
        let events = try eventItems(id)
        try db.exec("DELETE FROM entities WHERE kind='interaction' AND json_extract(json,'$.session_id')=?",[id])
        try scrubStoredReceipts(Set(events.compactMap { $0["id"].stringValue }))
        for e in events { try removeSearchDocument(kind:"event",id:e["id"].stringValue!); try db.exec("DELETE FROM entities WHERE kind='event' AND id=?", [e["id"].stringValue!]) }
        for row in try db.rows("SELECT id,json FROM records WHERE kind='event'") {
            var r = try decode(row["json"]!).objectValue
            if r["data"]?["session_id"].stringValue == id { var d = r["data"]!.objectValue; d["text"] = .string(""); if d["kind"]?.stringValue == "memory_operation" { d["request"] = .object([:]); d["result_refs"] = .array([]); d["issued_graph"] = .null }; d["purged"] = .bool(true); r["data"] = .object(d); try db.exec("UPDATE records SET json=? WHERE id=?", [try encode(.object(r)),row["id"]!]); try db.exec("INSERT OR IGNORE INTO outbox VALUES(?)",[row["id"]!]) }
        }
        for row in try db.rows("SELECT id,json FROM records WHERE kind IN ('session','session.restore') AND entity_id=?",[id]) {
            let original = try decode(row["json"]!), clean = try redacted(original)
            if original != clean { try db.exec("UPDATE records SET json=? WHERE id=?",[try encode(clean),row["id"]!]); try db.exec("INSERT OR IGNORE INTO outbox VALUES(?)",[row["id"]!]) }
        }
        if var s = try entity("session",id)?.objectValue { s["deleted"] = .bool(true); s["event_count"] = .number(0); s["title"] = .string("Purged source"); s["source_path"] = .string(""); s["purged"] = .bool(true); try put("session",.object(s)) }
    }
    func refreshSession(_ id: String) throws {
        guard var s = try entity("session",id)?.objectValue else { return }
        s["event_count"] = .number(Double(try db.rows("SELECT count(*) AS n FROM entities WHERE kind='event' AND json_extract(json,'$.session_id')=?",[id]).first?["n"] ?? "0") ?? 0)
        s["deleted"] = .bool(try isPurged(id)); try put("session",.object(s))
    }
    func indexEvent(_ e: JSONValue) throws {
        try indexDocument(kind:"event",id:e["id"].stringValue!,space:e["space_id"].stringValue!,revision:"",title:e["tool_name"].stringValue ?? e["role"].stringValue ?? "Event",text:e["text"].stringValue ?? "",timestamp:e["timestamp"].stringValue ?? "",status:e["outcome"].stringValue ?? "unknown")

    }
}
