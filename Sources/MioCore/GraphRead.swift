import Foundation

extension MioStore {
    // Wikilinks and explicit links share these stored entities. Reading never
    // creates another graph or expands the profile's space grants.
    func noteWithLinks(_ value: JSONValue, owner: JSONValue, revisionID: String?, params: [String: JSONValue], scope: Scope) throws -> JSONValue {
        var response = value.objectValue
        response["links"] = .array([])
        response["links_next_offset"] = .null
        if let revisionID, revisionID != owner["revision_id"].stringValue {
            response["links_state"] = .string("unavailable_for_historical_revision")
            return .object(response)
        }
        guard !owner["purged"].boolValue, !owner["redacted"].boolValue, owner["status"] != .string("purged") else {
            response["links_state"] = .string("unavailable_for_purged_note")
            return .object(response)
        }
        let id = owner["id"].stringValue!
        let rows = try db.rows("SELECT json FROM entities WHERE kind='link' AND (json_extract(json,'$.from_note_id')=? OR json_extract(json,'$.to_note_id')=?) AND coalesce(json_extract(json,'$.deleted'),0)=0 ORDER BY id", [id, id])
        var visible: [JSONValue] = [], seen = Set<String>()
        for row in rows {
            let candidate = try decode(row["json"]!)
            guard let edgeID = candidate["id"].stringValue,
                  let fromID = candidate["from_note_id"].stringValue, let toID = candidate["to_note_id"].stringValue,
                  let from = try liveGraphNote(fromID, scope), let to = try liveGraphNote(toID, scope) else { continue }
            let edge: JSONValue
            do { edge = try requireEntity("link", edgeID, scope) }
            catch let error as MioError where ["forbidden", "not_found", "source_purged"].contains(error.code) { continue }
            guard edge["space_id"] == from["space_id"], !edge["purged"].boolValue else { continue }
            let fingerprint = try graphRelationFingerprint(edge)
            guard seen.insert(fingerprint).inserted else { continue }
            let neighbor = fromID == id ? to : from
            let title = neighbor["title"].stringValue ?? "", status = neighbor["status"].stringValue ?? ""
            let kind = edge["kind"].stringValue ?? ""
            visible.append(.object([
                "id": edge["id"], "entity_kind": .string("link"), "from_note_id": edge["from_note_id"], "to_note_id": edge["to_note_id"], "space_id": edge["space_id"],
                "kind": .string(String(kind.prefix(120))), "kind_truncated": .bool(kind.count > 120), "relation_fingerprint": .string(fingerprint),
                "direction": .string(fromID == id && toID == id ? "self" : fromID == id ? "outgoing" : "incoming"),
                "origin": .string(edge["derived"] == .string("wikilink") ? "wikilink" : "explicit"),
                "note": .object(["kind": .string("note"), "id": neighbor["id"], "space_id": neighbor["space_id"], "revision_id": neighbor["revision_id"], "has_conflict": neighbor["has_conflict"],
                                 "title": .string(String(title.prefix(300))), "title_truncated": .bool(title.count > 300),
                                 "status": .string(String(status.prefix(80))), "status_truncated": .bool(status.count > 80)])
            ]))
        }
        // Filter authorization/deletion and duplicate relations before pagination.
        // No count or cursor reveals unavailable neighbors.
        let offset = max(0, params["offset"]?.intValue ?? 0), limit = max(1, min(200, params["limit"]?.intValue ?? 50))
        response["links"] = .array(Array(visible.dropFirst(offset).prefix(limit)))
        response["links_state"] = .string("current")
        response["links_revision_id"] = owner["revision_id"]
        response["links_observed_at"] = .string(now())
        response["links_offset"] = .number(Double(offset))
        response["links_limit"] = .number(Double(limit))
        if offset < visible.count && visible.count - offset > limit { response["links_next_offset"] = .number(Double(offset + limit)) }
        return .object(response)
    }

    func liveGraphNote(_ id: String, _ scope: Scope) throws -> JSONValue? {
        do {
            let note = try requireEntity("note", id, scope)
            guard !note["purged"].boolValue, !note["redacted"].boolValue, note["status"] != .string("purged") else { return nil }
            return note
        } catch let error as MioError where ["forbidden", "not_found", "source_purged"].contains(error.code) { return nil }
    }

    func graphRelationFingerprint(_ edge: JSONValue) throws -> String {
        hash(try JSONValue.object(["from_note_id": edge["from_note_id"], "to_note_id": edge["to_note_id"], "kind": edge["kind"]]).encoded())
    }
}
