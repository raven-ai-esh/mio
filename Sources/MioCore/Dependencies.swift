import Foundation

extension MioStore {
    /// Count unresolved references with indexed existence checks. Validation is
    /// still performed by validateDocument/canApply when records are imported.
    /// Queue status must not decode every historical body (or the full note
    /// behind both ends of every graph edge) while holding the store lock.
    func pendingDependencyCount() throws -> Int {
        // Match JSONValue.stringValue/arrayValue/boolValue exactly, including
        // sparse legacy records with optional fields of another JSON type.
        func ref(_ key: String) -> String { "(CASE WHEN json_type(r.json,'$.data.\(key)')='text' THEN json_extract(r.json,'$.data.\(key)') ELSE '' END)" }
        func member(_ name: String) -> String { "(CASE WHEN \(name).type='text' THEN \(name).value ELSE '' END)" }
        func missing(_ kind: String, _ id: String) -> String { "NOT EXISTS (SELECT 1 FROM entities e WHERE e.kind='\(kind)' AND e.id=\(id))" }
        let missingSpace=missing("space",ref("space_id"))
        let clauses=[
            "(r.kind IN ('revision','session','session.restore','event','attachment') AND \(missingSpace))",
            "(r.kind IN ('note.move','note.assets') AND (\(missing("note","r.entity_id")) OR \(missingSpace) OR (json_type(r.json,'$.data.asset_ids')='array' AND EXISTS (SELECT 1 FROM json_each(r.json,'$.data.asset_ids') a WHERE \(missing("attachment",member("a")))))))",
            "(r.kind='note.assets' AND \(missing("revision",ref("revision_id"))))",
            "(r.kind='note.move' AND json_type(r.json,'$.data.asset_revision_id')='text' AND \(missing("revision",ref("asset_revision_id"))))",
            "(r.kind='revision' AND json_type(r.json,'$.data.parent_ids')='array' AND EXISTS (SELECT 1 FROM json_each(r.json,'$.data.parent_ids') p WHERE \(missing("revision",member("p")))))",
            "(r.kind='attachment' AND \(ref("kind"))='pinned_asset' AND \(missing("note",ref("note_id"))))",
            "(r.kind='attachment' AND \(ref("kind"))='memory_file' AND \(missing("revision",ref("captured_revision_id"))))",
            "(r.kind='event' AND (\(missing("session",ref("session_id"))) OR (\(ref("kind"))='memory_operation' AND \(ref("phase"))='delivery' AND coalesce(json_type(r.json,'$.data.purged'),'null')!='true' AND \(missing("event",ref("execution_end_event_id"))))))",
            "(r.kind='link' AND (\(missing("note",ref("from_note_id"))) OR \(missing("note",ref("to_note_id")))))",
            "(r.kind='connection' AND (\(missing("space",ref("from_space_id"))) OR \(missing("space",ref("to_space_id")))))"
        ]
        let missing=Int(try db.rows("SELECT count(*) AS n FROM records r WHERE "+clauses.joined(separator:" OR ")).first?["n"] ?? "0") ?? 0
        let unapplied=Int(try db.rows("SELECT count(*) AS n FROM pending_record_applications").first?["n"] ?? "0") ?? 0
        return max(missing,unapplied)
    }
    func canApply(_ r: JSONValue) throws -> Bool {
        let kind = r["kind"].stringValue ?? "", data = r["data"]
        if ["revision","session","session.restore","event","attachment"].contains(kind), try entity("space",data["space_id"].stringValue ?? "") == nil { return false }
        if ["note.move","note.assets"].contains(kind) {
            guard try entity("note",r["entity_id"].stringValue ?? "") != nil,try entity("space",data["space_id"].stringValue ?? "") != nil else { return false }
            if kind == "note.assets" { guard let revision=try entity("revision",data["revision_id"].stringValue ?? "") else { return false };guard revision["note_id"]==data["note_id"] else { throw MioError("invalid_replica","Attachment bindings belong to another note") } }
            for id in data["asset_ids"].arrayValue {
                guard let asset=try entity("attachment",id.stringValue ?? "") else { return false }
                guard asset["kind"] == .string("pinned_asset"),asset["note_id"] == data["note_id"] else { throw MioError("invalid_replica","Pinned attachment belongs to a different note") }
            }
            if kind == "note.move",let anchor=data["asset_revision_id"].stringValue {
                guard let revision=try entity("revision",anchor) else { return false }
                guard revision["note_id"]==data["note_id"] else { throw MioError("invalid_replica","Location attachment revision belongs to another note") }
            }
            return true
        }
        if kind == "revision" {
            for parent in data["parent_ids"].arrayValue {
                guard let p = try entity("revision",parent.stringValue ?? "") else { return false }
                guard p["note_id"] == data["note_id"],p["space_id"] == data["space_id"] else { throw MioError("invalid_replica", "Revision parent belongs to a different note") }
            }
        }
        if kind == "attachment",data["kind"] == .string("pinned_asset"),try entity("note",data["note_id"].stringValue ?? "") == nil { return false }
        if kind == "attachment", data["kind"] == .string("memory_file") {
            guard let parent=try entity("revision",data["captured_revision_id"].stringValue ?? "") else { return false }
            guard data["id"] == r["entity_id"],parent["note_id"] == data["note_id"],parent["space_id"] == data["space_id"],parent["file_ids"].arrayValue.contains(data["id"]) else { throw MioError("invalid_replica","File binding does not match its parent revision") }
        }
        if kind == "event" {
            guard let session = try entity("session",data["session_id"].stringValue ?? "") else { return false }; guard session["space_id"] == data["space_id"] else { throw MioError("invalid_replica","Event belongs to a different session space") }
            if data["kind"].stringValue == "memory_operation" && data["phase"].stringValue == "delivery" && !data["purged"].boolValue {
                guard let end=try entity("event",data["execution_end_event_id"].stringValue ?? "") else { return false }
                guard end["interaction_id"] == data["interaction_id"],end["phase"].stringValue == "end",end["session_id"] == data["session_id"],end["space_id"] == data["space_id"] else { throw MioError("invalid_replica","Delivery refers to a different execution") }
            }
        }
        if kind == "link" { return try entity("note",data["from_note_id"].stringValue ?? "") != nil && entity("note",data["to_note_id"].stringValue ?? "") != nil }
        if kind == "connection" { return try entity("space",data["from_space_id"].stringValue ?? "") != nil && entity("space",data["to_space_id"].stringValue ?? "") != nil }
        return true
    }
    func applyAvailableRecords(rejectInvalid:Bool = true) throws {
        while true {
            let records=try db.rows("SELECT r.id FROM pending_record_applications p JOIN records r ON r.id=p.record_id ORDER BY CASE r.kind WHEN 'note.redact' THEN 0 WHEN 'session.purge' THEN 0 ELSE 1 END,r.rowid")
            var applied=false
            for row in records {
                // An earlier purge/redaction may have sanitized this payload in
                // the same transaction. Never apply a pre-purge JSON snapshot.
                guard let json=try db.rows("SELECT json FROM records WHERE id=?",[row["id"]!]).first?["json"] else { continue }
                let original=try decode(json),record=try redacted(original)
                if record != original {
                    try db.exec("UPDATE records SET json=? WHERE id=?",[try encode(record),row["id"]!])
                    try db.exec("INSERT OR IGNORE INTO outbox VALUES(?)",[row["id"]!])
                }
                let available:Bool
                do { available=try canApply(record) }
                catch let error as MioError where !rejectInvalid && error.code == "invalid_replica" {
                    // An untrusted deferred record must not prevent a local
                    // dependency from committing or stop the owner reopening.
                    // Keep it queued and counted; an explicit merge still fails.
                    continue
                }
                if available { try apply(record);applied=true }
            }
            if !applied { return }
        }
    }
}
