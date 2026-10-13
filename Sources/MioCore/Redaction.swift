import Foundation

extension MioStore {
    func redacted(_ input: JSONValue) throws -> JSONValue {
        let kind = input["kind"].stringValue ?? ""
        var r = input.objectValue, d = input["data"].objectValue
        if kind == "event" {
            let id = input["entity_id"].stringValue ?? "", sessionID = d["session_id"]?.stringValue ?? ""
            let purges = try records("session.purge",sessionID)
            let explicitlyPurged = purges.contains { $0["data"]["event_ids"].arrayValue.contains(.string(id)) }
            if try explicitlyPurged || isPurged(sessionID) || d["purged"]?.boolValue == true { d["text"] = .string(""); if d["kind"]?.stringValue == "memory_operation" { d["request"] = .object([:]); d["result_refs"] = .array([]); d["issued_graph"] = .null }; d["purged"] = .bool(true); r["data"] = .object(d) }
        } else if kind == "session" || kind == "session.restore" {
            let id = input["entity_id"].stringValue ?? "", purges = try records("session.purge",input["entity_id"].stringValue ?? "")
            let oldMetadata = purges.contains { $0["data"]["metadata_record_ids"].arrayValue.contains(input["id"]) || $0["data"]["purged_generations"].arrayValue.contains(d["generation"] ?? .string("initial")) }
            let clears = Set(input["data"]["purge_ids"].arrayValue.compactMap(\.stringValue))
            let explicitRestore = kind == "session.restore" && purges.allSatisfy { clears.contains($0["id"].stringValue!) }
            if try oldMetadata || (!explicitRestore && isPurged(id)) || d["purged"]?.boolValue == true {
                d["title"] = .string("Purged source"); d["source_path"] = .string(""); d["purged"] = .bool(true); r["data"] = .object(d)
            }
        } else if kind == "revision" {
            let noteID = d["note_id"]?.stringValue ?? ""
            if !(try records("note.redact",noteID)).isEmpty || d["purged"]?.boolValue == true {
                d["title"] = .string("Purged source"); d["body"] = .string(""); d["source_ids"] = .array([]); d["status"] = .string("purged"); d["purged"] = .bool(true); r["data"] = .object(d)
            }
        } else if kind == "attachment", d["kind"] == .string("memory_file") {
            if !(try records("note.redact",d["note_id"]?.stringValue ?? "")).isEmpty || d["purged"]?.boolValue == true {
                d["bytes"] = .string(""); d["sha256"] = .string(hash(Data())); d["file_name"] = .string("Purged file"); d["mime_type"] = .string("application/octet-stream")
                d["relative_path"] = .string("Files/"+(input["entity_id"].stringValue ?? "")+"/purged"); d["byte_count"] = .number(0); d["purged"] = .bool(true); r["data"] = .object(d)
            }
        }
        return .object(r)
    }
    func purgeHistory(_ id: String, selectedNoteIDs: [String], scope: Scope) throws -> JSONValue {
        let session = try requireEntity("session",id,scope)
        if session["source"].stringValue == Self.interactionSource && session["session_state"].stringValue == "open" { throw MioError("session_active","Close or interrupt this memory session before clearing its history") }
        let events = try eventItems(id)
        var references = Set(events.compactMap { $0["id"].stringValue }), notes = Set(selectedNoteIDs)
        for nid in selectedNoteIDs { _ = try requireEntity("note",nid,scope,write:true,allowDeleted:true) }
        let allRevisions = try all("revision")
        var changed = true
        while changed {
            changed = false
            for rev in allRevisions {
                let nid = rev["note_id"].stringValue!
                if notes.contains(nid) || rev["source_ids"].arrayValue.contains(where: { references.contains($0.stringValue ?? "") }) {
                    if notes.insert(nid).inserted { changed = true }
                    if references.insert(nid).inserted { changed = true }
                    if references.insert(rev["id"].stringValue!).inserted { changed = true }
                    for file in rev["file_ids"].arrayValue.compactMap(\.stringValue) { if references.insert(file).inserted { changed=true } }
                    for row in try db.rows("SELECT id FROM source_fragments WHERE note_id=?",[nid]) { if references.insert(row["id"]!).inserted { changed=true } }
                }
            }
        }
        _ = try record("session.purge",entityID:id,data:.object(["session_id":.string(id),"space_id":session["space_id"],"event_ids":.array(events.map { $0["id"] }),"note_ids":.array(notes.sorted().map(JSONValue.string)),"metadata_record_ids":.array((try records("session",id) + records("session.restore",id)).map { $0["id"] }),"purged_generations":.array((try records("session",id) + records("session.restore",id)).map { $0["data"]["generation"] == .null ? .string("initial") : $0["data"]["generation"] })]))
        for nid in notes { _ = try record("note.redact",entityID:nid,data:.object(["note_id":.string(nid),"session_id":.string(id)])) }
        // Existing receipts may contain the note projection. Redact them in the same commit.
        for row in try db.rows("SELECT key,json FROM idempotency") {
            let value = try decode(row["json"]!)
            let cleaned = scrubReceipt(value,notes:references.union(notes))
            if value != cleaned { try db.exec("UPDATE idempotency SET json=? WHERE key=?",[try encode(cleaned),row["key"]!]) }
        }
        return .object(["session_id":.string(id),"deleted":.bool(true),"redacted_note_ids":.array(notes.sorted().map(JSONValue.string)),"purged_event_count":.number(Double(events.count))])
    }
    func scrubReceipt(_ value: JSONValue, notes: Set<String>) -> JSONValue {
        switch value {
        case .object(let object):
            var d = object.mapValues { scrubReceipt($0,notes:notes) }
            let id = object["note_id"]?.stringValue ?? object["id"]?.stringValue ?? ""
            if notes.contains(id) { if d["title"] != nil { d["title"] = .string("Purged source") }; if d["body"] != nil { d["body"] = .string("") }; if d["text"] != nil { d["text"] = .string("") }; if d["snippet"] != nil { d["snippet"] = .string("") }; if d["source_ids"] != nil { d["source_ids"] = .array([]) } }
            if notes.contains(id), d["file_name"] != nil { d["file_name"] = .string("Purged file");d["sha256"] = .string(hash(Data()));d["file_version"] = .string("");d["byte_count"] = .number(0);d["mime_type"] = .string("application/octet-stream");d["purged"] = .bool(true);d.removeValue(forKey:"media") }
            return .object(d)
        case .array(let values): return .array(values.map { scrubReceipt($0,notes:notes) })
        default: return value
        }
    }
    func scrubStoredReceipts(_ ids: Set<String>) throws {
        for row in try db.rows("SELECT key,json FROM idempotency") { let value = try decode(row["json"]!); let cleaned = scrubReceipt(value,notes:ids); if value != cleaned { try db.exec("UPDATE idempotency SET json=? WHERE key=?",[try encode(cleaned),row["key"]!]) } }
    }
    func redactNote(_ id: String) throws {
        try eraseSourceIndex(id)
        let work=directory.appendingPathComponent("IndexWork",isDirectory:true)
        for run in (try? FileManager.default.contentsOfDirectory(at:work,includingPropertiesForKeys:nil)) ?? [] {
            for file in (try? FileManager.default.contentsOfDirectory(at:run,includingPropertiesForKeys:nil)) ?? [] where file.lastPathComponent.hasPrefix(id+"-") { try? FileManager.default.removeItem(at:file) }
        }
        interactionReplies.removeAll(); interactionReplyOrder.removeAll()
        try scrubStoredReceipts([id])
        for rev in try revisions(id) {
            for row in try db.rows("SELECT id,json FROM records WHERE kind='revision' AND entity_id=?",[rev["id"].stringValue!]) {
                let clean = try redacted(decode(row["json"]!))
                try db.exec("UPDATE records SET json=? WHERE id=?",[try encode(clean),row["id"]!])
                try db.exec("INSERT OR IGNORE INTO outbox VALUES(?)",[row["id"]!])
                try put("revision",clean["data"])
            }
        }
        for row in try db.rows("SELECT id,json FROM records WHERE kind='attachment' AND json_extract(json,'$.data.note_id')=? AND json_extract(json,'$.data.kind')='memory_file'",[id]) {
            let clean = try redacted(decode(row["json"]!))
            try db.exec("UPDATE records SET json=? WHERE id=?",[try encode(clean),row["id"]!]);try db.exec("INSERT OR IGNORE INTO outbox VALUES(?)",[row["id"]!])
            try put("attachment",clean["data"])
        }
        try refreshNote(id)
    }
    func eventItems(_ sessionID: String) throws -> [JSONValue] {
        try db.rows("SELECT json FROM entities WHERE kind='event' AND json_extract(json,'$.session_id')=? ORDER BY json_extract(json,'$.timestamp'),json_extract(json,'$.source_sequence'),json_extract(json,'$.source_id')",[sessionID]).map { try decode($0["json"]!) }
    }
}
