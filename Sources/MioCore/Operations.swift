import Foundation
import CSQLite

extension MioStore {
    func dispatch(_ method: String, _ p: [String: JSONValue], _ s: Scope) throws -> JSONValue {
        switch method {
        case "diagnostics": return .object(["schema_version": .number(1), "sqlite_version": .string(String(cString: sqlite3_libversion())), "fts5": .bool(sqlite3_compileoption_used("ENABLE_FTS5") != 0), "integrity": .string(try db.rows("PRAGMA integrity_check").first?.values.first ?? "unknown")])
        case "interaction.session.begin", "interaction.session.end", "interaction.call.begin", "interaction.call.reject", "interaction.call.delivery": return try interactionControl(method,p,s)
        case "snapshot": return try snapshot(s,projection:p.string("projection","full"))
        case "space.create":
            let id = UUID().uuidString.lowercased()
            let d: JSONValue = .object(["id": .string(id), "name": .string(try p.required("name")), "color": .string(p.string("color","blue")), "deleted": .bool(false), "created_at": .string(now())])
            _ = try record("space",entityID:id,data:d); return d
        case "space.rename", "space.delete":
            let id = try p.required("space_id"); try requireSpace(id,s,write:true)
            var d = try entity("space",id)!.objectValue
            if method == "space.rename" { d["name"] = .string(try p.required("name")) }
            else { d["deleted"] = .bool(true) }
            _ = try record("space",entityID:id,data:.object(d)); return .object(d)
        case "note.create": return try createNote(p,s)
        case "note.update", "note.restore", "note.resolve": return try changeNote(method,p,s)
        case "note.delete":
            let id = try p.required("note_id"); let n = try requireEntity("note",id,s,write:true)
            _ = try record("note.delete",entityID:id,data:.object(["space_id": n["space_id"], "revision_id": n["revision_id"]])); return .object(["id": .string(id),"note_id": .string(id), "deleted": .bool(true)])
        case "note.history":
            let id = try p.required("note_id"); _ = try requireEntity("note",id,s,allowDeleted:true)
            let note = try requireEntity("note",id,s,allowDeleted:true)
            let history = try revisions(id).map { revision -> JSONValue in try requireSpace(revision["space_id"].stringValue ?? "",s); guard revision["space_id"] == note["space_id"] else { throw MioError("invalid_revision","Revision belongs to a different space") }; return sanitizeSources(revision,s) }
            return .object(["note_id":.string(id),"revisions":.array(history)])
        case "link.create":
            let from = try p.required("from_note_id"), to = try p.required("to_note_id")
            let n = try requireEntity("note",from,s,write:true); _ = try requireEntity("note",to,s)
            let kind = p.string("kind","related")
            if let old = try all("link").first(where: { !$0["deleted"].boolValue && $0["from_note_id"].stringValue == from && $0["to_note_id"].stringValue == to && $0["kind"].stringValue == kind }) {
                if old["derived"].stringValue == "wikilink" { var d = old.objectValue; d["derived"] = .null; _ = try record("link",entityID:old["id"].stringValue!,data:.object(d)); return .object(d) }; return old
            }
            let id = UUID().uuidString.lowercased()
            let d: JSONValue = .object(["id": .string(id), "space_id": n["space_id"],"from_note_id": .string(from), "to_note_id": .string(to), "kind": .string(kind),"deleted": .bool(false)])
            _ = try record("link",entityID:id,data:d); return d
        case "link.delete":
            let id = try p.required("link_id"); let d = try requireEntity("link",id,s,write:true)
            _ = try requireEntity("note",d["to_note_id"].stringValue!,s)
            var values = d.objectValue; values["deleted"] = .bool(true); _ = try record("link",entityID:id,data:.object(values)); return .object(values)
        case "connection.create":
            let from = try p.required("from_space_id"), to = try p.required("to_space_id"); try requireSpace(from,s); try requireSpace(to,s)
            guard from != to, ["read","write"].contains(p.string("access","read")) else { throw MioError("invalid_params", "Invalid space connection") }
            for old in try all("connection") where !old["deleted"].boolValue && old["from_space_id"].stringValue == from && old["to_space_id"].stringValue == to {
                var d = old.objectValue; d["deleted"] = .bool(true); _ = try record("connection",entityID:old["id"].stringValue!,data:.object(d))
            }
            let id = UUID().uuidString.lowercased()
            let d: JSONValue = .object(["id": .string(id),"from_space_id": .string(from),"to_space_id": .string(to),"access": .string(p.string("access","read")),"deleted": .bool(false)])
            _ = try record("connection",entityID:id,data:d); return d
        case "connection.delete":
            let id = try p.required("connection_id"); guard var d = try entity("connection",id)?.objectValue else { throw MioError("not_found", "Connection not found") }
            d["deleted"] = .bool(true); _ = try record("connection",entityID:id,data:.object(d)); return .object(d)
        case "profile.create":
            let space = try p.required("space_id"); try requireSpace(space,s)
            let id = UUID().uuidString.lowercased(), token = UUID().uuidString + UUID().uuidString
            let d: JSONValue = .object(["id": .string(id),"name": .string(try p.required("name")),"space_id": .string(space),"token_hash": .string(hash(Data(token.utf8))),"revoked": .bool(false),"created_at": .string(now())])
            // Credentials are local only, never replica or archive records.
            try put("profile",d)
            var response = d.objectValue; response.removeValue(forKey:"token_hash"); response["token"] = .string(token); return .object(response)
        case "profile.revoke":
            let id = try p.required("profile_id"); guard var d = try entity("profile",id)?.objectValue else { throw MioError("not_found", "Profile not found") }
            d["revoked"] = .bool(true); try put("profile",.object(d)); d.removeValue(forKey:"token_hash"); return .object(d)
        case "search": return try search(p,s)
        case "search.rebuild": try rebuildSearchIndex(); return .object(["status":.string("rebuilt"),"documents":.number(Double(try db.rows("SELECT count(*) AS n FROM search_documents").first?["n"] ?? "0") ?? 0)])
        case "read": return try read(p,s)
        case "history.import", "history.restore": return try importHistory(p,s,restore:method == "history.restore")
        case "history.purge":
            let id = try p.required("session_id"); return try purgeHistory(id,selectedNoteIDs:p["note_ids"]?.arrayValue.compactMap(\.stringValue) ?? [],scope:s)
        case "replica.export": return try replicaDocument()
        case "replica.record":
            let id = try p.required("id"); guard let row = try db.rows("SELECT json FROM records WHERE id=?",[id]).first else { return .null }; let r = try decode(row["json"]!); var d = r.objectValue; d["content_hash"] = .string(hash(try r.encoded())); return .object(d)
        case "replica.merge": return try mergeDocument(p["document"] ?? .null,restore:false)
        case "sync.pending":
            let pending = try db.rows("SELECT records.id,records.json FROM outbox JOIN records ON records.id=outbox.record_id ORDER BY records.id").map { row -> JSONValue in .object(["id":.string(row["id"]!),"content_hash":.string(hash(try decode(row["json"]!).encoded()))]) }
            let deferred = try db.rows("SELECT json FROM records").map { try decode($0["json"]!) }.filter { try !canApply($0) }.count
            return .object(["records":.array(pending),"record_ids":.array(pending.map { $0["id"] }),"count":.number(Double(pending.count)),"pending_dependencies":.number(Double(deferred))])
        case "sync.queue":
            let deliveries = p["records"]?.arrayValue ?? []; var queued = 0, rejected = 0
            for delivery in deliveries { guard let id = delivery["id"].stringValue, let expected = delivery["content_hash"].stringValue, let row = try db.rows("SELECT json FROM records WHERE id=?",[id]).first, expected == hash(try decode(row["json"]!).encoded()) else { rejected += 1; continue }; try db.exec("INSERT OR IGNORE INTO outbox VALUES(?)",[id]); queued += 1 }
            return .object(["queued":.number(Double(queued)),"rejected":.number(Double(rejected))])
        case "sync.ack":
            let deliveries = p["records"]?.arrayValue ?? []
            var ack = 0, rejected = 0
            for delivery in deliveries {
                guard let id = delivery["id"].stringValue, let expected = delivery["content_hash"].stringValue, let row = try db.rows("SELECT json FROM records WHERE id=?",[id]).first, expected == hash(try decode(row["json"]!).encoded()) else { rejected += 1; continue }
                try db.exec("DELETE FROM outbox WHERE record_id=?",[id]); ack += 1
            }
            return .object(["acknowledged":.number(Double(ack)),"rejected":.number(Double(rejected))])
        case "archive.export": return try archiveExport(p)
        case "archive.import": return try archiveImport(p)
        case "markdown.export": return try markdownExport(p,s)
        case "markdown.import": return try markdownImport(p,s)
        default: throw MioError("method_not_found", "Unknown Mio operation \(method)")
        }
    }
    func revisions(_ id: String) throws -> [JSONValue] { try db.rows("SELECT json FROM entities WHERE kind='revision' AND json_extract(json,'$.note_id')=? ORDER BY json_extract(json,'$.timestamp'),id",[id]).map { try decode($0["json"]!) } }
    func createNote(_ p: [String: JSONValue], _ s: Scope) throws -> JSONValue {
        let space = try p.required("space_id"); try requireSpace(space,s,write:true)
        let id = UUID().uuidString.lowercased(), rid = UUID().uuidString.lowercased()
        let file = try prepareCapturedFile(p, noteID:id, revisionID:rid, spaceID:space, maximumBytes:s.human ? 20_000_000:5_000_000)
        let sources = p["source_ids"] ?? .array([]); try validateSources(sources,s)
        if let file { _ = try record("attachment",entityID:file["id"].stringValue!,data:file) }
        var values: [String:JSONValue] = ["id": .string(rid),"note_id": .string(id),"space_id": .string(space),"title": .string(try p.required("title")),"body": .string(p.string("body")),"status": .string(p.string("status","unverified")),"source_ids": sources,"parent_ids": .array([]),"cleared_deletions": .array([]),"timestamp": .string(now()),"author": .string(s.actor),"import_path":p["import_path"] ?? .null,"import_relative_path":p["import_relative_path"] ?? .null,"import_source_namespace":p["import_source_namespace"] ?? .null]
        if let file { values["file_ids"] = .array([file["id"]]); values["content_kind"] = .string("file") }
        let d: JSONValue = .object(values)
        _ = try record("revision",entityID:rid,data:d)
        if let file, let row=try db.rows("SELECT json FROM records WHERE kind='attachment' AND entity_id=?",[file["id"].stringValue!]).first { try apply(decode(row["json"]!)) }
        let note = try entity("note",id)!; let warnings = try refreshWikilinks(note,s)
        var response: [String:JSONValue] = ["id":.string(id),"note_id":.string(id),"revision_id":.string(rid),"note":note,"link_warnings":.array(warnings)]
        if let file { response["file_id"] = file["id"]; response["file"] = fileMetadata(file) }
        return .object(response)
    }
    func changeNote(_ method: String, _ p: [String: JSONValue], _ s: Scope) throws -> JSONValue {
        let id = try p.required("note_id"), old = try requireEntity("note",id,s,write:true,allowDeleted:method == "note.restore")
        if method == "note.update", !(try records("note.redact",id)).isEmpty { throw MioError("source_purged","This note was cleared with its source. Create a new note to save fresh evidence.") }
        var values = old.objectValue
        let heads = old["head_revision_ids"].arrayValue
        var conflict = false
        if method == "note.update" {
            let expected = try p.required("expected_revision")
            guard let base = try entity("revision",expected), base["note_id"].stringValue == id, base["space_id"] == old["space_id"] else { throw MioError("invalid_revision", "Expected revision does not belong to this note") }
            try requireSpace(base["space_id"].stringValue ?? "",s,write:true)
            conflict = expected != old["revision_id"].stringValue || old["has_conflict"].boolValue
            values = base.objectValue
            for key in ["title","body","status","source_ids"] { if let v = p[key] { values[key] = v } }
            values["parent_ids"] = .array([.string(expected)])
        } else {
            let chosen = try p.required("revision_id")
            guard let rev = try entity("revision",chosen), rev["note_id"].stringValue == id, rev["space_id"] == old["space_id"] else { throw MioError("invalid_revision", "Selected revision does not belong to this note") }
            try requireSpace(rev["space_id"].stringValue ?? "",s,write:true)
            values = rev.objectValue; values["parent_ids"] = .array(heads)
            if method == "note.restore" { values["cleared_deletions"] = .array(try records("note.delete",id).map { $0["id"] }); values["restored_from"] = .string(chosen) }
            else { values["resolved_from"] = .string(chosen) }
        }
        guard let title = values["title"]?.stringValue, !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, values["body"]?.stringValue != nil else { throw MioError("invalid_params", "A note requires a title and text body") }
        try validateSources(values["source_ids"] ?? .array([]),s)
        let rid = UUID().uuidString.lowercased()
        values["id"] = .string(rid); values["note_id"] = .string(id); values["author"] = .string(s.actor); values["timestamp"] = .string(now())
        for key in ["revision_id","head_revision_ids","has_conflict","updated_at","deleted"] { values.removeValue(forKey:key) }
        _ = try record("revision",entityID:rid,data:.object(values))
        var result: [String: JSONValue] = ["id": .string(id),"note_id": .string(id),"revision_id": .string(rid),"current_revision": old["revision_id"],"note": try entity("note",id)!]
        if !conflict { result["link_warnings"] = .array(try refreshWikilinks(try entity("note",id)!,s)) }
        if conflict { result["_error"] = .string("revision_conflict") }
        return .object(result)
    }
    func validateSources(_ sources: JSONValue, _ s: Scope) throws {
        for source in sources.arrayValue {
            guard let id = source.stringValue else { throw MioError("invalid_params", "Source IDs must be strings") }
            if try id.hasPrefix("source-") || entity("attachment",id)?["kind"] == .string("memory_file") || entity("event",id) != nil || entity("revision",id) != nil || entity("note",id) != nil { try requireSourceReference(id,s) }
            else if !s.human && !id.hasPrefix("https://") && !id.hasPrefix("http://") { throw MioError("invalid_source", "Source is unavailable or outside this profile") }
        }
    }
    func sanitizeSources(_ v: JSONValue, _ s: Scope) -> JSONValue {
        guard !s.human else { return v }
        var d = v.objectValue
        d["source_ids"] = .array(v["source_ids"].arrayValue.filter { ref in
            guard let id = ref.stringValue else { return false }
            if id.hasPrefix("https://") || id.hasPrefix("http://") { return true }
            if (try? requireSourceReference(id,s)) != nil { return true }
            return false
        })
        if !v["file_ids"].arrayValue.isEmpty {
            let files=v["file_ids"].arrayValue.filter { ref in guard let id=ref.stringValue,let file=try? requireFile(id,s) else { return false };return file["note_id"] == (v["note_id"] == .null ? v["id"]:v["note_id"]) && file["space_id"]==v["space_id"] }
            d["file_ids"] = .array(files);d["file_state"] = .string(files.count==v["file_ids"].arrayValue.count ? "available":"pending_or_unavailable")
        }
        return .object(d)
    }
    func snapshot(_ s: Scope, projection: String = "full") throws -> JSONValue {
        guard ["full","compact"].contains(projection) else { throw MioError("invalid_params","Snapshot projection must be full or compact") }
        let compact = projection == "compact"
        func visible(_ v: JSONValue) -> Bool { !v["deleted"].boolValue && s.readable.contains(v["space_id"].stringValue ?? "") }
        let spaces = try all("space").filter { s.human || s.readable.contains($0["id"].stringValue ?? "") }
        let notes = compact ? try compactSnapshotNotes(s) : try all("note").filter { s.human || visible($0) }.map { sanitizeSources($0,s) }
        let sessions = try all("session").filter { s.human || visible($0) }.compactMap { try visibleSession($0,s) }
        let eventWhere: String, eventBindings: [String]
        if s.human { eventWhere = "kind='event'"; eventBindings = [] }
        else if !s.readable.isEmpty { eventWhere = "kind='event' AND json_extract(json,'$.space_id') IN (" + Array(repeating:"?",count:s.readable.count).joined(separator:",") + ")"; eventBindings = s.readable.sorted() }
        else { eventWhere = "0"; eventBindings = [] }
        let (eventVisibility,eventScopeBindings) = eventVisibilitySQL(s)
        let visibleEventWhere = eventWhere + " AND " + eventVisibility
        let visibleEventBindings = eventBindings + eventScopeBindings
        let eventCount = Int(try db.rows("SELECT count(*) AS n FROM entities WHERE " + visibleEventWhere,visibleEventBindings).first?["n"] ?? "0") ?? 0
        let events = compact ? try compactSnapshotEvents(s) : try db.rows("SELECT json FROM entities WHERE " + visibleEventWhere + " ORDER BY json_extract(json,'$.timestamp') DESC LIMIT 200",visibleEventBindings).map { try decode($0["json"]!) }
        let links = try all("link").filter { link in
            guard !link["deleted"].boolValue else { return s.human }
            return (try? requireEntity("note",link["from_note_id"].stringValue ?? "",s)) != nil && (try? requireEntity("note",link["to_note_id"].stringValue ?? "",s)) != nil
        }
        let profiles = s.human ? try all("profile").map { v -> JSONValue in var d = v.objectValue; d.removeValue(forKey:"token_hash"); return .object(d) } : []
        let audit = s.human ? try db.rows("SELECT json FROM audit ORDER BY rowid DESC LIMIT 200").map { try decode($0["json"]!) } : []
        let connections = try all("connection").filter { s.human || (!$0["deleted"].boolValue && s.readable.contains($0["from_space_id"].stringValue ?? "") && s.readable.contains($0["to_space_id"].stringValue ?? "")) }
        return .object(["projection":.string(projection),"bodies_omitted":.bool(compact),"spaces": .array(spaces),"notes": .array(notes),"links": .array(links),"connections": .array(connections),"profiles": .array(profiles),"sessions": .array(sessions),"events": .array(events),"interactions":.array(try visibleInteractions(s)),"audit": .array(audit),"counts": .object(["spaces": .number(Double(spaces.filter { !$0["deleted"].boolValue }.count)),"notes": .number(Double(notes.filter { !$0["deleted"].boolValue }.count)),"sessions": .number(Double(sessions.filter { !$0["deleted"].boolValue }.count)),"events": .number(Double(eventCount))]),"pending_sync": .number(s.human ? Double(try db.rows("SELECT count(*) AS n FROM outbox").first?["n"] ?? "0") ?? 0 : 0)])
    }
    func importHistory(_ p: [String: JSONValue], _ s: Scope, restore: Bool) throws -> JSONValue {
        let space = try p.required("space_id"); try requireSpace(space,s,write:true)
        let external = try p.required("external_id"), source = p.string("source","codex")
        let id = "session-" + hash(Data((space + "\u{0}" + source + "\u{0}" + external).utf8))
        let purged = try isPurged(id)
        if purged && !restore { throw MioError("source_purged", "This source was purged. Restore explicitly from the external source.") }
        let sourceEvents = p["events"]?.arrayValue ?? []
        if restore && sourceEvents.isEmpty { throw MioError("invalid_params", "Restoration requires explicit external source events") }
        let generation = restore ? UUID().uuidString.lowercased() : (try entity("session",id))?["generation"].stringValue ?? "initial"
        var session: [String: JSONValue] = ["id": .string(id),"external_id": .string(external),"source": .string(source),"title": .string(p.string("title",external)),"space_id": .string(space),"event_count": .number(0),"updated_at": .string(now()),"completeness": .string(p.string("completeness","partial")),"source_path": .string(p.string("source_path")),"generation": .string(generation),"deleted": .bool(false)]
        var newEvents: [JSONValue] = [], seenBatch: [String:JSONValue] = [:]
        for (sequence,raw) in sourceEvents.enumerated() {
            let e = raw.objectValue
            let sourceID = try e["source_id"]?.stringValue ?? hash(raw.encoded())
            let eid = "event-" + hash(Data((id + "\u{0}" + generation + "\u{0}" + sourceID).utf8))
            let normalized: JSONValue = .object(["id":.string(eid),"source_id":.string(sourceID),"session_id":.string(id),"space_id":.string(space),"kind":.string(e.string("kind","message")),"role":.string(e.string("role","unknown")),"text":.string(e.string("text")),"timestamp":.string(e.string("timestamp")),"tool_name":.string(e.string("tool_name")),"outcome":.string(e.string("outcome","unknown")),"generation":.string(generation),"source_sequence":e["source_sequence"] ?? .number(Double(sequence))])
            var semantic = normalized.objectValue; semantic.removeValue(forKey:"source_sequence")
            if let previous = seenBatch[eid] { guard previous == .object(semantic) else { throw MioError("source_conflict","A stable source ID has conflicting content within this import",details:.object(["session_id":.string(id),"source_id":.string(sourceID)])) }; continue }
            seenBatch[eid] = .object(semantic)
            if let existing = try entity("event",eid) {
                guard existing == normalized else { throw MioError("source_conflict", "A source item changed; the original was preserved",details:.object(["session_id":.string(id),"source_id":.string(sourceID)])) }
            } else { newEvents.append(normalized) }
        }
        if restore {
            session["purge_ids"] = .array(try records("session.purge",id).map { $0["id"] })
            _ = try record("session.restore",entityID:id,data:.object(session))
        } else {
            let old = try entity("session",id)
            let metadataChanged = ["title","completeness","source_path","generation"].contains { old?[$0] != session[$0] }
            if old == nil || metadataChanged || !newEvents.isEmpty { _ = try record("session",entityID:id,data:.object(session)) }
        }
        for event in newEvents { _ = try record("event",entityID:event["id"].stringValue!,data:event) }
        let added = newEvents.count
        try refreshSession(id)
        return .object(["id": .string(id),"session_id": .string(id),"imported": .number(Double(added)),"event_count": try entity("session",id)!["event_count"],"completeness": session["completeness"]!])
    }
}
