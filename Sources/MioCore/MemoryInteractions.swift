import Foundation
import Darwin

extension MioStore {
    static let interactionSource = "memory_operations_v1"
    struct InteractionAttempt {
        let id: String; let sessionID: String; let started: String; let request: JSONValue
        let fingerprint: String; let created: Bool; let required: Set<String>; let targets: Set<String>; let metadata: JSONValue
    }
    func semanticParams(_ params: [String:JSONValue]) -> [String:JSONValue] { var p = params; p.removeValue(forKey:"_mio_interaction"); return p }
    func tracedMethod(_ method: String, _ scope: Scope) -> Bool { !scope.human && !method.hasPrefix("interaction.") && !["snapshot","diagnostics","sync.pending","replica.record"].contains(method) }
    func operationRequest(_ method: String, _ p: [String:JSONValue]) -> JSONValue {
        var d: [String:JSONValue] = [:]
        let labels=["kind","id","note_id","space_id","from_note_id","to_note_id","expected_revision","revision_id","scope","status","idempotency_key"]
        for key in labels {
            if let value = p[key]?.stringValue { d[key] = .string(value) }
        }
        for key in ["offset","limit","max_chars"] { if let value = p[key] { d[key] = value } }
        if let query = p["query"]?.stringValue { d["query"] = .string(query); d["query_hash"] = .string(hash(Data(query.utf8))); d["query_chars"] = .number(Double(query.count)); d["query_truncated"] = .bool(query.count>1024) }
        var safe=automaticTrace(.object(d)).objectValue
        for key in labels { if let value=safe[key]?.stringValue { safe[key] = .string(String(value.prefix(200))) } }
        if let value=safe["query"]?.stringValue { safe["query"] = .string(String(value.prefix(1024))) }
        return .object(safe)
    }
    func interactionSpaces(_ method: String, _ p: [String:JSONValue], _ scope: Scope, result: JSONValue = .null) throws -> Set<String> {
        // Catalog totals and names depend on the complete current readable set,
        // including spaces outside the returned page.
        if method == "read", p["kind"] == .string("spaces") { return scope.readable }
        if method == "search" {
            var spaces = scope.readable
            if let filter = p["space_ids"], !filter.arrayValue.isEmpty { spaces.formIntersection(filter.arrayValue.compactMap(\.stringValue)) }
            return spaces
        }
        var spaces = Set<String>()
        if let space = p["space_id"]?.stringValue, scope.readable.contains(space) { spaces.insert(space) }
        var refs = ["id","note_id","from_note_id","to_note_id","revision_id","expected_revision"].compactMap { p[$0]?.stringValue }
        refs += p["source_ids"]?.arrayValue.compactMap(\.stringValue) ?? []
        refs += resultIDs(result).arrayValue.compactMap(\.stringValue)
        for ref in refs {
            spaces.formUnion(try sourceDependencySpaces(ref,scope))
        }
        for row in result["results"].arrayValue + [result,result["note"]] {
            if let space = row["space_id"].stringValue, scope.readable.contains(space) { spaces.insert(space) }
            for id in row["source_ids"].arrayValue.compactMap(\.stringValue) {
                spaces.formUnion(try sourceDependencySpaces(id,scope))
            }
        }
        func nestedDependencies(_ value: JSONValue) throws {
            switch value {
            case .object(let object):
                if let space=object["space_id"]?.stringValue { spaces.insert(space) }
                spaces.formUnion((object["required_space_ids"]?.arrayValue ?? []).compactMap(\.stringValue))
                for source in object["source_ids"]?.arrayValue ?? [] {
                    guard let id=source.stringValue else { continue }
                    spaces.formUnion(try sourceDependencySpaces(id,scope))
                }
                for (key,child) in object where key != "request" { try nestedDependencies(child) }
            case .array(let array): for child in array { try nestedDependencies(child) }
            default: break
            }
        }
        try nestedDependencies(result)
        return spaces
    }
    func sessionForInteraction(_ metadata: JSONValue, _ scope: Scope) throws -> JSONValue {
        guard !scope.human, let home = scope.homeSpace else { throw MioError("forbidden","Memory transport sessions require an authenticated agent") }
        let transport = String((metadata["transport_session_id"].stringValue ?? ("agent-api-" + runtimeID)).prefix(128))
        let sid = "session-" + hash(Data((scope.actor + "\u{0}" + transport).utf8))
        if let existing = try entity("session",sid) { guard !existing["deleted"].boolValue else { throw MioError("source_purged","This memory interaction session was cleared") }; return existing }
        let opened = now()
        let value: JSONValue = .object(["id":.string(sid),"space_id":.string(home),"external_id":.string(transport),"transport_session_id":.string(transport),"source":.string(Self.interactionSource),"title":.string("MCP memory session"),"actor":.string(scope.actor),"owner_pid":.number(Double(getpid())),"owner_device_id":.string(deviceID),"adapter_pid":metadata["adapter_pid"],"opened_at":.string(opened),"updated_at":.string(opened),"session_state":.string("open"),"closed_at":.null,"event_count":.number(0),"completeness":.string("Mio API operations only; no conversation content; response consumption not observed"),"deleted":.bool(false),"generation":.string("initial")])
        var sessionValue = value.objectValue
        sessionValue["graph_trace_version"] = .number(1)
        _ = try record("session",entityID:sid,data:.object(sessionValue)); return try entity("session",sid)!
    }
    func beginInteraction(_ method: String, _ params: [String:JSONValue], _ scope: Scope, identityOnly: Bool = false) throws -> InteractionAttempt {
        let metadata = params["_mio_interaction"] ?? .object([:]), session = try sessionForInteraction(metadata,scope)
        let requestID = String((metadata["request_id"].stringValue ?? UUID().uuidString.lowercased()).prefix(128))
        let callID = "call-" + hash(Data((scope.actor + "\u{0}" + session["id"].stringValue! + "\u{0}" + requestID).utf8))
        let fingerprint = hash(try JSONValue.object(["method":.string(method),"params":.object(semanticParams(params))]).encoded())
        var required = try interactionSpaces(method,params,scope); required.insert(session["space_id"].stringValue!)
        if let old = try entity("interaction",callID) {
            guard old["request_fingerprint"].stringValue == fingerprint else { throw MioError("interaction_mismatch","The same request identifier was reused with different parameters") }
            if !identityOnly { try requireVisibility(old,scope) }
            return InteractionAttempt(id:callID,sessionID:session["id"].stringValue!,started:old["started_at"].stringValue!,request:old["request"],fingerprint:fingerprint,created:false,required:Set(old["required_space_ids"].arrayValue.compactMap(\.stringValue)),targets:Set(old["target_space_ids"].arrayValue.compactMap(\.stringValue)),metadata:metadata)
        }
        guard session["session_state"].stringValue == "open" else { throw MioError("session_closed","Use a new transport session for a new memory request") }
        let started = now(), targets = try interactionSpaces(method,params,scope)
        let attempt = InteractionAttempt(id:callID,sessionID:session["id"].stringValue!,started:started,request:identityOnly ? .object(["request_hash":.string(fingerprint)]) : operationRequest(method,params),fingerprint:fingerprint,created:true,required:required,targets:targets,metadata:metadata)
        let event = try interactionEvent(attempt,scope:scope,method:method,phase:"start",outcome:"in_progress",result:.null,errorCode:nil,replayed:false,original:nil)
        _ = try record("event",entityID:event["id"].stringValue!,data:event)
        return attempt
    }
    func interactionEvent(_ call: InteractionAttempt, scope: Scope, method: String, phase: String, outcome: String, result: JSONValue, errorCode: String?, replayed: Bool, original: String?) throws -> JSONValue {
        let session = try entity("session",call.sessionID)!, sourceID = call.id + ":" + phase
        let eid = "event-" + hash(Data((call.sessionID + "\u{0}initial\u{0}" + sourceID).utf8))
        let finished = now(), interrupted = outcome == "interrupted"
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let elapsed = max(0,(formatter.date(from:finished)?.timeIntervalSince(formatter.date(from:call.started) ?? Date()) ?? 0)*1000)
        var targets = call.targets
        if !interrupted { targets.formUnion(try interactionSpaces(method,[:],scope,result:result)) }
        var required = call.required; required.formUnion(targets)
        let refs = operationResultRefs(result)
        let mutations: Set<String> = ["note.create","note.update","note.delete","note.restore","note.resolve","link.create","link.delete"]
        let ownReceipt = mutations.contains(method) ? result["receipt"] : .null
        var text = "Memory operation \(method). Phase \(phase). Observed outcome \(outcome)."
        if let query = call.request["query"].stringValue { text += " Query: " + query }
        for key in ["kind","id","note_id","from_note_id","to_note_id","expected_revision"] { if let value = call.request[key].stringValue { text += " \(key): \(value)." } }
        if phase == "end" { text += " Result references: " + refs.arrayValue.flatMap { reference in ["id","revision_id","source_id"].compactMap { reference[$0].stringValue } }.joined(separator:",") }
        if let errorCode { text += " Error code: " + errorCode + "." }
        if replayed { text += " Logical operation replayed; no new domain write." }
        var event: [String:JSONValue] = ["id":.string(eid),"source_id":.string(sourceID),"session_id":.string(call.sessionID),"space_id":session["space_id"],"kind":.string("memory_operation"),"role":.string("agent"),"tool_name":.string(method),"text":.string(text),"timestamp":.string(phase == "start" ? call.started : finished),"outcome":.string(outcome),"generation":.string("initial"),"source_sequence":.number(Double(session["event_count"].intValue)),"interaction_id":.string(call.id),"phase":.string(phase),"method":.string(method),"actor":.string(scope.actor),"request":call.request,"request_fingerprint":.string(call.fingerprint),"required_space_ids":.array(required.sorted().map(JSONValue.string)),"target_space_ids":.array(targets.sorted().map(JSONValue.string)),"started_at":.string(call.started),"finished_at":phase == "end" && !interrupted ? .string(finished) : .null,"duration_ms":phase == "end" && !interrupted ? .number(elapsed) : .null,"observed_duration_ms":phase == "end" ? .number(elapsed) : .null,"owner_pid":call.metadata["owner_pid"] == .null ? .number(Double(getpid())) : call.metadata["owner_pid"],"owner_device_id":.string(deviceID),"observing_pid":.number(Double(getpid())),"adapter_pid":call.metadata["adapter_pid"],"client_name":.string(String((call.metadata["client_name"].stringValue ?? "").prefix(120))),"client_version":.string(String((call.metadata["client_version"].stringValue ?? "").prefix(80))),"result_refs":phase == "end" ? refs : .array([]),"result_count":.number(Double(result["results"].arrayValue.count)),"receipt":ownReceipt,"operation_id":ownReceipt["operation_id"],"replayed":.bool(replayed),"original_interaction_id":original.map(JSONValue.string) ?? .null,"response_delivery":.string("not_observed")]
        if result["kind"] == .string("spaces") { event["result_count"] = .number(Double(result["spaces"].arrayValue.count)) }
        if phase == "end", errorCode == nil, !interrupted, method == "read", result["links_state"] != .null {
            event["issued_graph"] = issuedGraph(result)
        }
        if let errorCode { event["error_code"] = .string(errorCode) }
        return automaticTrace(.object(event))
    }
    // Capture exactly the authorized page returned by read. Bodies and global
    // topology are excluded; delivery observations remain separate evidence.
    func issuedGraph(_ result: JSONValue) -> JSONValue {
        let links = result["links"].arrayValue.map { edge -> JSONValue in
            var fields: [String:JSONValue] = [:]
            for key in ["id","from_note_id","to_note_id","kind","space_id","direction","origin"] { if edge[key] != .null { fields[key] = edge[key] } }
            var neighbor: [String:JSONValue] = [:]
            for key in ["id","space_id","revision_id"] { if edge["note"][key] != .null { neighbor[key] = edge["note"][key] } }
            neighbor["kind"] = .string("note")
            fields["note"] = .object(neighbor)
            return .object(fields)
        }
        return .object([
            "version":.number(1), "state":.string(result["links_state"] == .string("current") ? "recorded" : result["links_state"].stringValue ?? "unavailable"),
            "note_id":result["note_id"] == .null ? result["id"] : result["note_id"], "revision_id":result["revision_id"],
            "observed_at":result["links_observed_at"], "offset":result["links_offset"], "limit":result["links_limit"],
            "next_offset":result["links_next_offset"], "links":.array(links)
        ])
    }
    func operationResultRefs(_ result: JSONValue) -> JSONValue {
        let catalog = result["kind"] == .string("spaces")
        let rows = catalog ? result["spaces"].arrayValue : result["results"].arrayValue.isEmpty ? [result,result["note"]] : result["results"].arrayValue
        var refs: [JSONValue] = [], seen = Set<String>()
        for row in rows {
            guard let id = row["id"].stringValue, seen.insert(id).inserted else { continue }
            var reference: [String:JSONValue] = ["id":.string(id)]
            if catalog { reference["kind"] = .string("space"); reference["space_id"] = .string(id) }
            for key in ["kind","space_id","note_id","revision_id","session_id","source_id","from_note_id","to_note_id"] { if row[key] != .null { reference[key] = row[key] } }
            let sources=row["source_ids"] == .null ? row["note"]["source_ids"] : row["source_ids"]
            if sources != .null { reference["source_ids"] = sources }
            refs.append(.object(reference))
        }
        return automaticTrace(.array(refs))
    }
    func finishInteraction(_ call: InteractionAttempt, scope: Scope, method: String, result: JSONValue, errorCode: String? = nil, replayed: Bool = false, original: String? = nil, interrupted: Bool = false) throws {
        if try entity("interaction",call.id)?["end_event_id"].stringValue != nil { return }
        let outcome = interrupted ? "interrupted" : errorCode == nil ? "success" : errorCode == "revision_conflict" ? "revision_conflict" : "error"
        let event = try interactionEvent(call,scope:scope,method:method,phase:"end",outcome:outcome,result:result,errorCode:errorCode,replayed:replayed,original:original)
        _ = try record("event",entityID:event["id"].stringValue!,data:event)
    }
    func projectInteraction(_ event: JSONValue) throws {
        guard event["kind"].stringValue == "memory_operation", let id = event["interaction_id"].stringValue else { return }
        try refreshInteractionProjection(id)
    }
    func ensureInteractionProjection() throws {
        try db.exec("CREATE INDEX IF NOT EXISTS entity_interaction ON entities(kind,json_extract(json,'$.interaction_id'))")
        // Only derived rows change. Retained, applied events remain the source of truth;
        // no execution is replayed and no lifecycle ending is manufactured here.
        try db.transaction {
            guard try db.rows("SELECT value FROM metadata WHERE key='interaction_projection_version'").first?["value"] != "4" else { return }
            let ids = try db.rows("SELECT DISTINCT json_extract(json,'$.interaction_id') AS id FROM entities WHERE kind='event' AND json_extract(json,'$.kind')='memory_operation' AND json_extract(json,'$.interaction_id') IS NOT NULL")
            try db.exec("DELETE FROM entities WHERE kind='interaction'")
            for row in ids { if let id = row["id"] { try refreshInteractionProjection(id) } }
            try db.exec("INSERT OR REPLACE INTO metadata VALUES('interaction_projection_version','4')")
        }
    }
    func interactionEventDate(_ value: JSONValue) -> Date? {
        guard let timestamp = value.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:timestamp)
    }
    func validInteractionExecution(_ event: JSONValue) -> Bool {
        guard !event["purged"].boolValue,
              ["id","interaction_id","session_id","space_id","actor","method","request_fingerprint","owner_device_id"].allSatisfy({ !(event[$0].stringValue ?? "").isEmpty }),
              interactionEventDate(event["timestamp"]) != nil, interactionEventDate(event["started_at"]) != nil,
              case .object = event["request"], case .array(let required) = event["required_space_ids"], required.allSatisfy({ $0.stringValue != nil }),
              case .array(let targets) = event["target_space_ids"], targets.allSatisfy({ $0.stringValue != nil }) else { return false }
        if event["phase"].stringValue == "start" {
            let noRefs: Bool
            if case .array(let refs)=event["result_refs"] { noRefs=refs.isEmpty } else { noRefs=event["result_refs"] == .null }
            return event["outcome"].stringValue == "in_progress" && event["finished_at"] == .null && event["receipt"] == .null && event["operation_id"] == .null && noRefs
        }
        guard event["phase"].stringValue == "end", let outcome = event["outcome"].stringValue,
              ["success","error","revision_conflict","interrupted"].contains(outcome) else { return false }
        if outcome == "success" { return event["error_code"] == .null && interactionEventDate(event["finished_at"]) != nil }
        return outcome == "interrupted" || interactionEventDate(event["finished_at"]) != nil
    }
    func refreshInteractionProjection(_ id: String) throws {
        // The index bounds this read to one request, including late START/delivery.
        let events = try db.rows("SELECT json FROM entities WHERE kind='event' AND json_extract(json,'$.interaction_id')=? AND json_extract(json,'$.kind')='memory_operation'",[id]).map { try decode($0["json"]!) }
        let execution = events.filter(validInteractionExecution).sorted {
            let left = interactionEventDate($0["timestamp"])!, right = interactionEventDate($1["timestamp"])!
            return left == right ? $0["id"].stringValue! < $1["id"].stringValue! : left < right
        }
        guard let anchor = execution.first(where:{$0["phase"] == .string("start")}) ?? execution.first(where:{$0["phase"] == .string("end")}) else {
            try db.exec("DELETE FROM entities WHERE kind='interaction' AND id=?",[id]); return
        }
        let identity = ["session_id","space_id","actor","method","request_fingerprint","started_at","owner_device_id","owner_pid","adapter_pid"]
        func matches(_ event: JSONValue) -> Bool { identity.allSatisfy { event[$0] == anchor[$0] } }
        let contradictory = execution.contains { !matches($0) }
        let matching = execution.filter(matches), start = matching.first(where:{$0["phase"] == .string("start")}), end = matching.last(where:{$0["phase"] == .string("end")})
        let source = contradictory ? (start ?? anchor) : (end ?? start!)
        var current: [String:JSONValue] = [:]
        for key in ["session_id","space_id","actor","method","request","request_fingerprint","started_at","owner_pid","owner_device_id","adapter_pid"] { current[key] = source[key] }
        current["id"] = .string(id)
        current["state"] = .string(contradictory ? "invalid" : "in_progress")
        if let start { current["start_event_id"] = start["id"] }
        var observations: [JSONValue] = []
        if let end, !contradictory {
            current["state"] = .string(end["outcome"].stringValue == "success" ? "completed" : end["outcome"].stringValue == "interrupted" ? "interrupted" : "failed")
            current["end_event_id"] = end["id"]
            for key in ["finished_at","duration_ms","observed_duration_ms","outcome","error_code","result_refs","result_count","receipt","operation_id","replayed","original_interaction_id"] { current[key] = end[key] }
            current["response_delivery"] = .string("not_observed")
            observations = events.filter { event in
                guard event["phase"] == .string("delivery"), !event["purged"].boolValue, matches(event),
                      event["execution_end_event_id"] == end["id"], interactionEventDate(event["observed_at"]) != nil,
                      event["outcome"] == end["outcome"],event["receipt"] == end["receipt"],event["operation_id"] == end["operation_id"] else { return false }
                let states = event["observation_type"] == .string("adapter_report") ? ["stdout_written","stdout_write_failed"] : event["observation_type"] == .string("server_observed") ? ["socket_written","frame_too_large","socket_write_failed"] : []
                return states.contains(event["delivery_state"].stringValue ?? "")
            }.sorted {
                let left = interactionEventDate($0["observed_at"])!, right = interactionEventDate($1["observed_at"])!
                return left == right ? $0["id"].stringValue! < $1["id"].stringValue! : left < right
            }
            for observation in observations { current[observation["observation_type"] == .string("adapter_report") ? "adapter_delivery" : "response_delivery"] = observation["delivery_state"] }
            if let latest = observations.last {
                current["delivery_event_ids"] = .array(observations.map { $0["id"] })
                current["last_delivery_at"] = latest["observed_at"]
            }
        }
        // Never discard a known private dependency because another event contradicts
        // its identity. Raw records remain available to the owner for inspection.
        let retained = events.filter { !$0["purged"].boolValue }
        let malformedAccess = retained.contains { event in
            guard case .array(let required)=event["required_space_ids"],required.allSatisfy({$0.stringValue != nil}),
                  case .array(let targets)=event["target_space_ids"],targets.allSatisfy({$0.stringValue != nil}) else { return true }
            return false
        }
        current["integrity_state"] = .string(contradictory ? "conflicting" : malformedAccess ? "invalid" : "valid")
        let accepted=contradictory ? [] : matching+observations
        current["valid_event_ids"] = .array(accepted.map{$0["id"]}.sorted{($0.stringValue ?? "")<($1.stringValue ?? "")})
        // An untrusted existing END cannot be replaced by a fabricated recovery END
        // using that same immutable ID; retain it for owner inspection instead.
        current["has_untrusted_execution_end"] = .bool(retained.contains{ event in event["phase"] == .string("end") && !accepted.contains(where:{$0["id"] == event["id"]})})
        current["required_space_ids"] = .array(Set(retained.flatMap { $0["required_space_ids"].arrayValue.compactMap(\.stringValue) + [$0["space_id"].stringValue].compactMap{$0} }).sorted().map(JSONValue.string))
        current["target_space_ids"] = .array(Set(retained.flatMap { $0["target_space_ids"].arrayValue.compactMap(\.stringValue) }).sorted().map(JSONValue.string))
        try put("interaction",.object(current))
    }
    func isMemoryInteractionEvent(_ value: JSONValue) -> Bool {
        // Generic legacy events may have their own interaction_id. Cached search
        // wrappers are separately checked against the stored event by source access.
        value["kind"].stringValue == "memory_operation" || value["event_kind"].stringValue == "memory_operation"
    }
    func memoryInteractionVisible(_ value: JSONValue, _ scope: Scope) -> Bool {
        if let integrity=value["integrity_state"].stringValue,integrity != "valid" { return false }
        guard isMemoryInteractionEvent(value) else { return true }
        guard let id=value["interaction_id"].stringValue,let call=try? entity("interaction",id),call["integrity_state"].stringValue == "valid",call["valid_event_ids"].arrayValue.contains(value["id"]) else { return false }
        return call["required_space_ids"].arrayValue.allSatisfy { scope.readable.contains($0.stringValue ?? "") }
    }
    func requireVisibility(_ value: JSONValue, _ scope: Scope) throws {
        guard scope.human || (value["required_space_ids"].arrayValue.allSatisfy({ scope.readable.contains($0.stringValue ?? "") }) && memoryInteractionVisible(value,scope)) else { throw MioError("forbidden","Entity is unavailable or access is not permitted") }
    }
    func isVisible(_ value: JSONValue, _ scope: Scope) -> Bool { scope.human || (scope.readable.contains(value["space_id"].stringValue ?? "") && value["required_space_ids"].arrayValue.allSatisfy { scope.readable.contains($0.stringValue ?? "") } && memoryInteractionVisible(value,scope)) }
    func processGone(_ pid: Int) -> Bool { guard pid>0 else { return false }; errno=0; return Darwin.kill(Int32(pid),0) == -1 && errno == ESRCH }
    func recoverMemoryInteractions() throws {
        let pending = try db.rows("SELECT json FROM entities WHERE kind='interaction' AND json_extract(json,'$.state')='in_progress' AND coalesce(json_extract(json,'$.has_untrusted_execution_end'),0)=0 AND json_extract(json,'$.owner_device_id')=?",[deviceID]).map { try decode($0["json"]!) }
        let sessions = try db.rows("SELECT json FROM entities WHERE kind='session' AND json_extract(json,'$.source')=? AND json_extract(json,'$.session_state')='open' AND json_extract(json,'$.owner_device_id')=?",[Self.interactionSource,deviceID]).map { try decode($0["json"]!) }
        let goneCalls = pending.filter { $0["owner_device_id"].stringValue == deviceID && processGone($0["owner_pid"].intValue) }, goneSessions = sessions.filter { $0["owner_device_id"].stringValue == deviceID && processGone($0["adapter_pid"].intValue>0 ? $0["adapter_pid"].intValue : $0["owner_pid"].intValue) }
        if goneCalls.isEmpty && goneSessions.isEmpty { return }
        try db.transaction {
            for old in goneCalls {
                let allSpaces = Set(try all("space").compactMap { $0["id"].stringValue }), scope = Scope(actor:old["actor"].stringValue ?? "agent",human:true,readable:allSpaces,writable:allSpaces,homeSpace:old["space_id"].stringValue)
                let call = InteractionAttempt(id:old["id"].stringValue!,sessionID:old["session_id"].stringValue!,started:old["started_at"].stringValue!,request:old["request"],fingerprint:old["request_fingerprint"].stringValue!,created:false,required:Set(old["required_space_ids"].arrayValue.compactMap(\.stringValue)),targets:Set(old["target_space_ids"].arrayValue.compactMap(\.stringValue)),metadata:.object(["adapter_pid":old["adapter_pid"],"owner_pid":old["owner_pid"]]))
                try finishInteraction(call,scope:scope,method:old["method"].stringValue!,result:.null,errorCode:"owner_process_terminated",interrupted:true)
            }
            for session in goneSessions { var d = session.objectValue; d["session_state"] = .string("interrupted"); d["observed_at"] = .string(now()); d["closed_at"] = .null; _ = try record("session",entityID:session["id"].stringValue!,data:.object(d)) }
        }
    }
    func interactionControl(_ method: String, _ p: [String:JSONValue], _ scope: Scope) throws -> JSONValue {
        let metadata = p["_mio_interaction"] ?? .object([:])
        if method == "interaction.call.delivery" {
            let state=p.string("state")
            guard ["stdout_written","stdout_write_failed"].contains(state) else { throw MioError("forbidden","Serialized clients can only report their own adapter output observation") }
            guard let pid=Int32(exactly:metadata["adapter_pid"].intValue) else { throw MioError("invalid_params","Invalid adapter process identity") }
            try recordMemoryDelivery(metadata:metadata,actor:scope.actor,peerPID:pid,state:state,origin:"adapter_report",errorCode:p["error_code"]?.stringValue,scope:scope)
            return .object(["observation_type":.string("adapter_report"),"delivery_state":.string(state)])
        }
        let session = try sessionForInteraction(metadata,scope)
        if method == "interaction.session.begin" { return .object(["session_id":session["id"],"session_state":session["session_state"]]) }
        if method == "interaction.session.end" {
            if session["session_state"].stringValue == "closed" { return .object(["session_id":session["id"],"session_state":session["session_state"],"closed_at":session["closed_at"]]) }
            guard session["session_state"].stringValue == "open" else { throw MioError("session_closed","An interrupted session cannot report a normal close") }
            guard try db.rows("SELECT id FROM entities WHERE kind='interaction' AND json_extract(json,'$.state')='in_progress' AND json_extract(json,'$.session_id')=? LIMIT 1",[session["id"].stringValue!]).isEmpty else { throw MioError("interaction_active","Finish the active memory request before closing its session") }
            var d = session.objectValue; d["session_state"] = .string("closed"); d["closed_at"] = .string(now()); _ = try record("session",entityID:session["id"].stringValue!,data:.object(d)); return .object(["session_id":session["id"],"session_state":.string("closed"),"closed_at":d["closed_at"]!])
        }
        let operation = p.string("method","unrecognized_operation")
        let call = try beginInteraction(operation,["_mio_interaction":metadata],scope)
        if method == "interaction.call.reject" { try finishInteraction(call,scope:scope,method:operation,result:.null,errorCode:"invalid_params") }
        return .object(["session_id":.string(call.sessionID),"interaction_id":.string(call.id),"outcome":.string(method == "interaction.call.reject" ? "error" : "in_progress")])
    }
}

extension MioStore {
    func eventVisibilitySQL(_ scope: Scope, json: String = "entities.json") -> (String,[String]) {
        if scope.human { return ("1",[]) }
        guard !scope.readable.isEmpty else { return ("0",[]) }
        let marks = Array(repeating:"?",count:scope.readable.count).joined(separator:",")
        let own="NOT EXISTS(SELECT 1 FROM json_each(\(json),'$.required_space_ids') visibility WHERE visibility.value NOT IN (\(marks)))"
        let effective="(coalesce(json_extract(\(json),'$.kind'),'')<>'memory_operation' OR EXISTS(SELECT 1 FROM entities interaction_acl WHERE interaction_acl.kind='interaction' AND interaction_acl.id=json_extract(\(json),'$.interaction_id') AND json_extract(interaction_acl.json,'$.integrity_state')='valid' AND EXISTS(SELECT 1 FROM json_each(interaction_acl.json,'$.valid_event_ids') accepted_event WHERE accepted_event.value=json_extract(\(json),'$.id')) AND NOT EXISTS(SELECT 1 FROM json_each(interaction_acl.json,'$.required_space_ids') required WHERE required.value NOT IN (\(marks)))))"
        return (own+" AND coalesce(json_extract(\(json),'$.integrity_state'),'valid')='valid' AND "+effective,scope.readable.sorted()+scope.readable.sorted())
    }
    func visibleInteractions(_ scope: Scope, sessionID: String? = nil, limit: Int = 200) throws -> [JSONValue] {
        let (visible,bindings) = eventVisibilitySQL(scope)
        var condition = "kind='interaction' AND " + visible, values = bindings
        if !scope.human { condition += " AND json_extract(json,'$.space_id') IN (" + Array(repeating:"?",count:scope.readable.count).joined(separator:",") + ")"; values += scope.readable.sorted() }
        if let sessionID { condition += " AND json_extract(json,'$.session_id')=?"; values.append(sessionID) }
        return try db.rows("SELECT json FROM entities WHERE " + condition + " ORDER BY json_extract(json,'$.started_at') DESC LIMIT \(max(1,min(limit,500)))",values).map { row in
            var value = try decode(row["json"]!).objectValue
            // Older derived rows may contain a complete issued page. Exact
            // pages live in immutable events, never in compact summary lists.
            value.removeValue(forKey:"issued_graph")
            return .object(value)
        }
    }
    func visibleSession(_ session: JSONValue, _ scope: Scope) throws -> JSONValue? {
        if session["source"].stringValue != Self.interactionSource { return session }
        let (visible,bindings) = eventVisibilitySQL(scope)
        let rows = try db.rows("SELECT count(*) AS n,max(json_extract(json,'$.timestamp')) AS latest FROM entities WHERE kind='event' AND json_extract(json,'$.session_id')=? AND " + visible,[session["id"].stringValue!] + bindings)
        let count = Int(rows.first?["n"] ?? "0") ?? 0
        if count == 0 && !scope.human { return nil }
        var value = session.objectValue; value["event_count"] = .number(Double(count)); value["updated_at"] = .string(rows.first?["latest"] ?? session["opened_at"].stringValue ?? "")
        let targetRows = try db.rows("SELECT DISTINCT target.value AS space FROM entities JOIN json_each(entities.json,'$.target_space_ids') target WHERE entities.kind='event' AND json_extract(entities.json,'$.session_id')=? AND target.type='text' AND " + visible + " ORDER BY target.value",[session["id"].stringValue!] + bindings)
        value["target_space_ids"] = .array(targetRows.compactMap { $0["space"].map(JSONValue.string) })
        let (callVisible,callBindings) = eventVisibilitySQL(scope)
        let total = Int(try db.rows("SELECT count(*) AS n FROM entities WHERE kind='interaction' AND json_extract(json,'$.session_id')=? AND " + callVisible,[session["id"].stringValue!] + callBindings).first?["n"] ?? "0") ?? 0
        value["interaction_count"] = .number(Double(total))
        return .object(value)
    }
}

extension MioStore {
    func authorizeCachedReply(_ value: JSONValue, _ scope: Scope) throws {
        guard !scope.human else { return }
        switch value {
        case .object(let object):
            try requireVisibility(value,scope)
            if object["kind"] == .string("spaces") {
                let current = try readSpaces(["offset":value["offset"],"limit":value["limit"]],scope)
                guard ["default_space_id","spaces","total_count","connections"].allSatisfy({value[$0] == current[$0]}) else {
                    throw MioError("catalog_changed","Space names or permissions changed; request a fresh read(kind=spaces)")
                }
            }
            if let source=object["source_id"]?.stringValue, source.hasPrefix("source-") { try requireSourceReference(source,scope) }
            if let file=object["file_id"]?.stringValue, !file.isEmpty { _ = try requireFile(file,scope) }
            if object["entity_kind"] == .string("link"), let id = object["id"]?.stringValue {
                let edge = try requireEntity("link",id,scope)
                guard let from = edge["from_note_id"].stringValue, let to = edge["to_note_id"].stringValue,
                      let source = try liveGraphNote(from,scope), try liveGraphNote(to,scope) != nil,
                      edge["space_id"] == source["space_id"], !edge["purged"].boolValue,
                      edge["from_note_id"] == value["from_note_id"], edge["to_note_id"] == value["to_note_id"],
                      try graphRelationFingerprint(edge) == value["relation_fingerprint"].stringValue else {
                    throw MioError("forbidden","Graph relation is unavailable or has changed")
                }
            }
            if let id=object["id"]?.stringValue,object["space_id"] != nil {
                for kind in ["note","revision","attachment","link"] {
                    if let stored=try entity(kind,id) {
                        guard try currentOwnership(stored,kind:kind)["space_id"] == value["space_id"] else { throw MioError("location_changed","Memory moved; request a fresh read") }
                        break
                    }
                }
            }
            if let id=object["id"]?.stringValue {
                if object["source_id"] != nil && object["session_id"] != nil { try requireSourceReference(id,scope) }
                else if object["events"] != nil || object["session_state"] != nil { _=try requireEntity("session",id,scope) }
                else if ["revision","note","file"].contains(object["kind"]?.stringValue ?? "") { try requireSourceReference(id,scope) }
                else if object["kind"]?.stringValue == "event" { try requireSourceReference(id,scope) }
                else if object["body"] != nil || object["note_id"] != nil { try requireSourceReference(id,scope) }
            }
            for ref in object["source_ids"]?.arrayValue ?? [] {
                guard let id=ref.stringValue else { continue }
                if !id.hasPrefix("https://") && !id.hasPrefix("http://") { try requireSourceReference(id,scope) }
            }
            for (key,child) in object where key != "request" { try authorizeCachedReply(child,scope) }
        case .array(let values): for child in values { try authorizeCachedReply(child,scope) }
        default: break
        }
    }
    func responseWithTrace(_ value: JSONValue, call: InteractionAttempt, replayed: Bool, original: String? = nil) -> JSONValue {
        var object = value.objectValue
        let trace: JSONValue = .object(["interaction_id":.string(call.id),"session_id":.string(call.sessionID),"replayed":.bool(replayed),"original_interaction_id":original.map(JSONValue.string) ?? .null])
        object["call_trace"] = trace
        if object["interaction_id"] == nil { object["interaction_id"] = .string(call.id) }
        if object["interaction_session_id"] == nil { object["interaction_session_id"] = .string(call.sessionID) }
        if object["replayed"] == nil { object["replayed"] = .bool(replayed) }
        if object["original_interaction_id"] == nil && original != nil { object["original_interaction_id"] = original.map(JSONValue.string) }
        return .object(object)
    }
    func domainReplayResult(_ value: JSONValue) -> JSONValue {
        var object = value.objectValue
        let prior = object.removeValue(forKey:"call_trace") ?? .null
        if object["interaction_id"] == prior["interaction_id"] { object.removeValue(forKey:"interaction_id") }
        if object["interaction_session_id"] == prior["session_id"] { object.removeValue(forKey:"interaction_session_id") }
        if object["replayed"] == prior["replayed"] { object.removeValue(forKey:"replayed") }
        object.removeValue(forKey:"original_interaction_id")
        return .object(object)
    }
}
