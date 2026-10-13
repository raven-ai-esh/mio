import Foundation

extension MioStore {
    func canApply(_ r: JSONValue) throws -> Bool {
        let kind = r["kind"].stringValue ?? "", data = r["data"]
        if ["revision","session","session.restore","event","attachment"].contains(kind), try entity("space",data["space_id"].stringValue ?? "") == nil { return false }
        if kind == "revision" {
            for parent in data["parent_ids"].arrayValue {
                guard let p = try entity("revision",parent.stringValue ?? "") else { return false }
                guard p["note_id"] == data["note_id"],p["space_id"] == data["space_id"] else { throw MioError("invalid_replica", "Revision parent belongs to a different note") }
            }
        }
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
    func applyAvailableRecords() throws {
        let records = try db.rows("SELECT json FROM records ORDER BY rowid").map { try decode($0["json"]!) }
        var remaining = records, previous = remaining.count + 1
        while !remaining.isEmpty && remaining.count < previous {
            previous = remaining.count; var deferred: [JSONValue] = []
            for record in remaining {
                if try canApply(record) { try apply(record) }
                else { deferred.append(record) }
            }
            remaining = deferred
        }
    }
}
