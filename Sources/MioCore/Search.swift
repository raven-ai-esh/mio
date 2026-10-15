import Foundation

extension MioStore {
    func legacySearch(_ p: [String: JSONValue], _ s: Scope) throws -> JSONValue {
        let query = p.string("query").trimmingCharacters(in:.whitespacesAndNewlines)
        let searchScope = p.string("scope","all")
        guard ["all","notes","files","history"].contains(searchScope) else { throw MioError("invalid_params", "Scope must be all, notes, files or history") }
        var spaces = s.readable
        if let requested = p["space_ids"], !requested.arrayValue.isEmpty { spaces.formIntersection(requested.arrayValue.compactMap(\.stringValue)) }
        let limit = min(100,max(1,p["limit"]?.intValue ?? 20)), budget = min(100000,max(1,p["max_chars"]?.intValue ?? 12000))
        let words = query.components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(32)
        if words.isEmpty || spaces.isEmpty { return .object(["results": .array([]),"returned_chars": .number(0),"truncated": .bool(false),"as_of": p["as_of"] ?? .null]) }
        let match = words.map { "\"" + $0.replacingOccurrences(of:"\"",with:"") + "\"*" }.joined(separator:searchScope == "history" || p["as_of"] != nil ? " AND ":" OR ")
        let placeholders = Array(repeating:"?",count:spaces.count).joined(separator:",")
        let noteFilter = "space_id IN (\(placeholders))"
        let eventFilter = "(space_id IN (\(placeholders)) OR EXISTS(SELECT 1 FROM entities target,json_each(target.json,'$.target_space_ids') targets WHERE target.kind='event' AND target.id=search_index.id AND targets.value IN (\(placeholders))))"
        let (visibility,visibilityBindings) = eventVisibilitySQL(s,json:"visible.json")
        var sql = "SELECT id,kind,title,text,timestamp,status,space_id,revision_id,bm25(search_index,0,0,0,0,3,1,0,0) AS rank FROM search_index WHERE search_index MATCH ? AND ((kind='note' AND \(noteFilter)) OR (kind='event' AND \(eventFilter)))"
        var bindings = [match] + spaces.sorted() + spaces.sorted() + spaces.sorted()
        sql += " AND (kind!='event' OR EXISTS(SELECT 1 FROM entities visible WHERE visible.kind='event' AND visible.id=search_index.id AND " + visibility
        bindings += visibilityBindings
        if let active = activeInteractionID { sql += " AND coalesce(json_extract(visible.json,'$.interaction_id'),'')<>?"; bindings.append(active) }
        if !(p["include_legacy_history"]?.boolValue ?? false) {
            sql += " AND EXISTS(SELECT 1 FROM entities history_session WHERE history_session.kind='session' AND history_session.id=json_extract(visible.json,'$.session_id') AND json_extract(history_session.json,'$.source')=?)"
            bindings.append(Self.interactionSource)
        }
        sql += "))"
        if searchScope == "notes" || searchScope == "files" {
            sql += " AND kind='note'"
            if searchScope == "files" || !(p["include_file_notes"]?.boolValue ?? false) { sql += " AND EXISTS(SELECT 1 FROM entities file_owner WHERE file_owner.kind='note' AND file_owner.id=search_index.id AND coalesce(json_array_length(file_owner.json,'$.file_ids'),0)"+(searchScope == "files" ? ">0":"=0")+")" }
        }
        if searchScope == "history" { sql += " AND kind='event'" }
        let asOf = p["as_of"]?.stringValue
        if let asOf { sql += " AND timestamp <> '' AND timestamp<=?"; bindings.append(asOf) }
        sql += " ORDER BY rank LIMIT 1000"
        let rows = try db.rows(sql,bindings)
        var candidates: [(Double,JSONValue)] = []
        for row in rows {
            let kind = row["kind"]!, id = row["id"]!
            if kind == "note" && asOf != nil { continue }
            guard let entity = try entity(kind,id) else { continue }
            if kind == "note" { guard let current=try? requireEntity("note",id,s),current["space_id"].stringValue == row["space_id"],current["revision_id"].stringValue == row["revision_id"] else { continue } }
            if kind == "event" && (!isVisible(entity,s) || (activeInteractionID != nil && entity["interaction_id"].stringValue == activeInteractionID)) { continue }
            let evidenceWeight: Double = kind == "event" && entity["role"].stringValue == "assistant" ? 0.000001 : 0
            var d: [String: JSONValue] = ["kind": .string(kind),"id": .string(id),"title": .string(row["title"] ?? ""),"snippet": .string(excerpt(row["text"] ?? "",words:Array(words),max:1200)),"space_id": .string(row["space_id"]!),"timestamp": .string(row["timestamp"] ?? ""),"status": .string(row["status"] ?? "unknown")]
            if kind == "note" { d["revision_id"] = .string(row["revision_id"] ?? ""); d["has_conflict"] = entity["has_conflict"]; d["source_ids"] = sanitizeSources(entity,s)["source_ids"] }
            else { d["session_id"] = entity["session_id"]; d["source_id"] = entity["source_id"]; d["role"] = entity["role"]; d["tool_name"] = entity["tool_name"]; d["outcome"] = entity["outcome"]; d["phase"] = entity["phase"]; d["interaction_id"] = entity["interaction_id"]; d["method"] = entity["method"]; d["replayed"] = entity["replayed"]; d["completeness"] = try self.entity("session",entity["session_id"].stringValue ?? "")?["completeness"] ?? .string("partial") }
            candidates.append(((Double(row["rank"] ?? "0") ?? 0) + evidenceWeight,.object(d)))
        }
        if let asOf, searchScope != "history" {
            for n in try all("note") where !n["deleted"].boolValue && spaces.contains(n["space_id"].stringValue ?? "") {
                guard let rev = try revisions(n["id"].stringValue!).last(where: { ($0["timestamp"].stringValue ?? "") <= asOf }) else { continue }
                if searchScope == "files" && rev["file_ids"].arrayValue.isEmpty || searchScope == "notes" && !rev["file_ids"].arrayValue.isEmpty { continue }
                let text = (rev["title"].stringValue ?? "") + " " + (rev["body"].stringValue ?? "")
                if words.allSatisfy({ text.localizedCaseInsensitiveContains($0) }) {
                    candidates.append((-1,.object(["kind": .string("note"),"id": n["id"],"title": rev["title"],"snippet": .string(excerpt(rev["body"].stringValue ?? "",words:Array(words),max:1200)),"space_id": n["space_id"],"revision_id": rev["id"],"timestamp": rev["timestamp"],"status": rev["status"],"as_of": .string(asOf)])))
                }
            }
        }
        candidates.sort { $0.0 == $1.0 ? ($0.1["id"].stringValue ?? "") < ($1.1["id"].stringValue ?? "") : $0.0 < $1.0 }
        var results: [JSONValue] = [], used = 0, seen = Set<String>(), truncated = false
        for (_,candidate) in candidates {
            let signature = candidate["interaction_id"].stringValue != nil ? "memory_operation:"+(candidate["id"].stringValue ?? "") : (candidate["kind"].stringValue ?? "") + (candidate["snippet"].stringValue ?? "").lowercased()
            guard seen.insert(signature).inserted else { continue }
            if results.count >= limit || used >= budget { truncated = true; break }
            var d = candidate.objectValue
            let available = budget - used
            let text = String((candidate["snippet"].stringValue ?? "").prefix(available))
            d["snippet"] = .string(text); used += text.count
            results.append(.object(d))
        }
        return .object(["results": .array(results),"returned_chars": .number(Double(used)),"truncated": .bool(truncated),"as_of": p["as_of"] ?? .null,"search_mode": .string("fts5_lexical"),"history_boundary": .string("Mio memory operation traces only; no conversations are imported or searched by default")])
    }
    func excerpt(_ text: String, words: [String], max: Int) -> String {
        guard text.count > max else { return text }
        if let first = words.first, let match = text.range(of:first,options:[.caseInsensitive,.diacriticInsensitive]) {
            let start = text.index(match.lowerBound,offsetBy:-min(120,text.distance(from:text.startIndex,to:match.lowerBound)))
            return (start == text.startIndex ? "" : "…") + String(text[start...].prefix(max)) + "…"
        }
        return String(text.prefix(max)) + "…"
    }
    func read(_ p: [String: JSONValue], _ s: Scope) throws -> JSONValue {
        let kind = p.string("kind","note")
        if kind == "spaces" { return try readSpaces(p,s) }
        let id = try p.required("id")
        if kind == "source" { return try readSource(id,s,params:p) }
        guard ["note","event","session"].contains(kind) else { throw MioError("invalid_params", "Read kind must be spaces, note, event, session or source") }
        let item = try requireEntity(kind,id,s)
        if kind == "note" {
            if let rid = p["revision_id"]?.stringValue, !rid.isEmpty {
                guard let rev = try? requireEntity("revision",rid,s), rev["note_id"].stringValue == id, rev["space_id"] == item["space_id"] else { throw MioError("invalid_revision", "Revision does not belong to this note") }
                var d = sanitizeSources(rev,s).objectValue; d["id"] = .string(id); d["revision_id"] = .string(rid); d["deleted"] = item["deleted"]; d["has_conflict"] = item["has_conflict"]
                return try noteWithLinks(.object(d),owner:item,revisionID:rid,params:p,scope:s)
            }
            return try noteWithLinks(sanitizeSources(item,s),owner:item,revisionID:nil,params:p,scope:s)
        }
        if kind == "event" {
            var d = item.objectValue; d["completeness"] = try entity("session",item["session_id"].stringValue ?? "")?["completeness"] ?? .string("partial")
            return .object(d)
        }
        var d = item.objectValue
        let events = try eventItems(id).filter { isVisible($0,s) && (s.human || s.readable.contains($0["space_id"].stringValue ?? "")) }
        d["event_count"] = .number(Double(events.count))
        if item["source"].stringValue == Self.interactionSource { d["interactions"] = .array(try visibleInteractions(s,sessionID:id)) }
        let offset = max(0,p["offset"]?.intValue ?? 0), limit = max(1,min(500,p["limit"]?.intValue ?? 200))
        var projections = [String:JSONValue]()
        let page = Array(events.dropFirst(offset).prefix(limit)).map { event -> JSONValue in
            guard isMemoryInteractionEvent(event), let callID = event["interaction_id"].stringValue else { return event }
            let call = projections[callID] ?? (try? entity("interaction",callID)) ?? .null
            projections[callID] = call
            var value = event.objectValue
            value["accepted_by_projection"] = .bool(call["integrity_state"] == .string("valid") && call["valid_event_ids"].arrayValue.contains(event["id"]))
            value["interaction_integrity_state"] = call["integrity_state"]
            return .object(value)
        }
        // read(session) is also an MCP reply (text + structured JSON). Keep a
        // bounded exact page when returned graph observations are substantial.
        var bounded = [JSONValue](), bytes = 0
        for event in page {
            let size = (try? event.encoded().count) ?? 0
            if !bounded.isEmpty && bytes+size > 1_000_000 { break }
            bounded.append(event); bytes += size
        }
        d["events"] = .array(bounded)
        d["page_limited_by_bytes"] = .bool(bounded.count < page.count)
        d["next_offset"] = offset + bounded.count < events.count ? .number(Double(offset + bounded.count)) : .null
        return .object(d)
    }
}
