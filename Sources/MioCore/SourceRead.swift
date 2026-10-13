import Foundation

extension MioStore {
    /// Resolve provenance through the canonical owner, never a caller-supplied
    /// title/space or a guessed source ID. Unknown/unauthorized references add
    /// no hidden identifiers to a denial trace.
    func sourceDependencySpaces(_ id:String,_ scope:Scope) throws -> Set<String> {
        var value:JSONValue?
        if id.hasPrefix("source-") { value=try? requireFragment(id,scope) }
        else if try entity("attachment",id)?["kind"] == .string("memory_file") { value=try? requireFile(id,scope) }
        else {
            for kind in ["note","revision","event","session","link"] {
                if try entity(kind,id) != nil { value=try? requireEntity(kind,id,scope);break }
            }
        }
        guard let value,let space=value["space_id"].stringValue,scope.readable.contains(space) else { return [] }
        return Set([space]).union(value["required_space_ids"].arrayValue.compactMap(\.stringValue).filter{scope.readable.contains($0)})
    }
    // Only authorize the reference itself, without recursively reading linked note bodies.
    func requireSourceReference(_ id: String, _ scope: Scope) throws {
        if id.hasPrefix("source-") { _ = try requireFragment(id,scope);return }
        if try entity("attachment",id)?["kind"] == .string("memory_file") { _ = try requireFile(id,scope); return }
        for kind in ["event","revision","note"] {
            guard try entity(kind,id) != nil else { continue }
            let source=try requireEntity(kind,id,scope)
            guard !source["purged"].boolValue && source["status"].stringValue != "purged" else { throw MioError("source_purged","This source was cleared") }
            if kind == "event" {
                let owner=try requireEntity("session",source["session_id"].stringValue ?? "",scope)
                guard owner["space_id"] == source["space_id"] else { throw MioError("forbidden","Source is unavailable or access is not permitted") }
            } else if kind == "revision" {
                let owner=try requireEntity("note",source["note_id"].stringValue ?? "",scope)
                guard owner["space_id"] == source["space_id"] else { throw MioError("forbidden","Source is unavailable or access is not permitted") }
            }
            return
        }
        throw MioError("forbidden","Source is unavailable or access is not permitted")
    }
    func readSource(_ id: String, _ scope: Scope, params: [String: JSONValue] = [:]) throws -> JSONValue {
        if id.hasPrefix("source-") { return try readFragment(id,scope) }
        if try entity("attachment",id)?["kind"] == .string("memory_file") { return try readFileSource(id,scope,params:params) }
        if id.hasPrefix("http://") || id.hasPrefix("https://") {
            guard let url = URL(string:id), ["http","https"].contains(url.scheme ?? ""), let host = url.host, !host.isEmpty else { throw MioError("invalid_source","The source URL is invalid") }
            return .object(["kind":.string("url"),"id":.string(id),"url":.string(id),"title":.string(id),"content_fetched":.bool(false)])
        }
        if try entity("event",id) != nil {
            let event = try requireEntity("event",id,scope)
            let session = try requireEntity("session",event["session_id"].stringValue ?? "",scope)
            guard session["space_id"] == event["space_id"] else { throw MioError(scope.human ? "invalid_source" : "forbidden","Source is unavailable or access is not permitted") }
            guard !event["purged"].boolValue else { throw MioError("source_purged","This source was cleared") }
            var value = event.objectValue
            value["event_kind"] = event["kind"]; value["kind"] = .string("event")
            value["completeness"] = session["completeness"] == .null ? .string("partial") : session["completeness"]
            return .object(value)
        }
        if try entity("note",id) != nil {
            let note = try requireEntity("note",id,scope)
            guard !note["purged"].boolValue && note["status"].stringValue != "purged" else { throw MioError("source_purged","This source note was cleared") }
            var value = sanitizeSources(note,scope).objectValue; value["kind"] = .string("note"); value["body_omitted"] = .bool(false)
            return try noteWithLinks(.object(value),owner:note,revisionID:nil,params:params,scope:scope)
        }
        if try entity("revision",id) != nil {
            let revision = try requireEntity("revision",id,scope), note = try requireEntity("note",revision["note_id"].stringValue ?? "",scope)
            guard revision["space_id"] == note["space_id"] else { throw MioError(scope.human ? "invalid_revision" : "forbidden","Source is unavailable or access is not permitted") }
            guard !revision["purged"].boolValue && !note["purged"].boolValue && revision["status"].stringValue != "purged" else { throw MioError("source_purged","This source revision was cleared") }
            var value = sanitizeSources(revision,scope).objectValue; value["kind"] = .string("revision"); value["revision_id"] = .string(id); value["body_omitted"] = .bool(false)
            return try noteWithLinks(.object(value),owner:note,revisionID:id,params:params,scope:scope)
        }
        if let row = try db.rows("SELECT records.json AS json FROM records,json_each(records.json,'$.data.event_ids') WHERE records.kind='session.purge' AND json_each.value=? LIMIT 1",[id]).first {
            let deletion = try decode(row["json"]!)
            try requireSpace(deletion["data"]["space_id"].stringValue ?? "",scope)
            throw MioError("source_purged","This source event was cleared")
        }
        throw MioError(scope.human ? "not_found" : "forbidden","Source is unavailable or access is not permitted")
    }
}
