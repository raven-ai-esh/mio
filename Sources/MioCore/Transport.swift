import Foundation

extension MioStore {
    func replicaDocument() throws -> JSONValue {
        let records = try db.rows("SELECT json FROM records ORDER BY id").map { row -> JSONValue in
            let r = try decode(row["json"]!); var d = r.objectValue; d["content_hash"] = .string(hash(try r.encoded())); return .object(d)
        }
        let profiles = try all("profile").map { p -> JSONValue in var d = p.objectValue; d.removeValue(forKey:"token_hash"); d["revoked"] = .bool(true); return .object(d) }
        let audit = try db.rows("SELECT json FROM audit ORDER BY id").map { try decode($0["json"]!) }
        return .object(["schema_version": .number(Double(Self.schema)),"format": .string("mio-records"),"records": .array(records),"profiles": .array(profiles),"audit":.array(audit)])
    }
    func validateDocument(_ doc: JSONValue, strict: Bool = true) throws -> [JSONValue] {
        guard [1,Self.schema].contains(doc["schema_version"].intValue), doc["format"].stringValue == "mio-records", case .array = doc["records"] else { throw MioError("archive_incompatible", "Unsupported Mio document schema") }
        let allowed: Set<String> = ["space","revision","note.move","note.assets","note.delete","note.redact","link","connection","session","session.purge","session.restore","event","attachment"]
        var result: [JSONValue] = [], seen: Set<String> = []
        for raw in doc["records"].arrayValue {
            var d = raw.objectValue; let expected = d.removeValue(forKey:"content_hash")?.stringValue
            let r = JSONValue.object(d)
            guard let id = r["id"].stringValue, !id.isEmpty, id.count < 200, seen.insert(id).inserted, let kind = r["kind"].stringValue, allowed.contains(kind), let entityID = r["entity_id"].stringValue, !entityID.isEmpty, r["timestamp"].stringValue != nil, case .object = r["data"], let expected, expected == hash(try r.encoded()) else { throw MioError("archive_corrupt", "A record is invalid or its SHA256 does not match") }
            let data = r["data"]
            if let relative = data["import_relative_path"].stringValue { guard !relative.hasPrefix("/"), !relative.split(separator:"/").contains("..") else { throw MioError("archive_corrupt","Invalid Markdown path") } }
            switch kind {
            case "revision":
                guard data["id"].stringValue == entityID, data["note_id"].stringValue != nil, data["space_id"].stringValue != nil, data["title"].stringValue != nil, data["body"].stringValue != nil, data["timestamp"].stringValue != nil, data["status"].stringValue != nil, case .array = data["parent_ids"] else { throw MioError("archive_corrupt", "Invalid note revision") }
            case "note.move", "note.assets": guard data["note_id"] == .string(entityID),data["space_id"].stringValue != nil else { throw MioError("archive_corrupt","Invalid note location or attachment binding") }
                if kind == "note.assets",data["revision_id"].stringValue == nil { throw MioError("archive_corrupt","Missing attachment binding revision") }
            case "event":
                guard data["id"].stringValue == entityID, data["session_id"].stringValue != nil, data["space_id"].stringValue != nil, data["source_id"].stringValue != nil, data["text"].stringValue != nil else { throw MioError("archive_corrupt", "Invalid history event") }
            case "space": guard data["name"].stringValue != nil else { throw MioError("archive_corrupt", "Invalid space") }
            case "session", "session.restore": guard data["space_id"].stringValue != nil, data["external_id"].stringValue != nil else { throw MioError("archive_corrupt", "Invalid session") }
            case "link": guard data["from_note_id"].stringValue != nil, data["to_note_id"].stringValue != nil else { throw MioError("archive_corrupt", "Invalid link") }
            case "connection": guard data["from_space_id"].stringValue != nil, data["to_space_id"].stringValue != nil, ["read","write"].contains(data["access"].stringValue ?? "") else { throw MioError("archive_corrupt", "Invalid connection") }
            case "attachment":
                guard let b64 = data["bytes"].stringValue, let bytes = Data(base64Encoded:b64), data["sha256"].stringValue == hash(bytes), let path = data["relative_path"].stringValue, !path.hasPrefix("/"), !path.split(separator:"/").contains(".."), bytes.count <= 20_000_000 else { throw MioError("archive_corrupt", "Invalid attachment bytes or path") }
                if data["kind"] == .string("pinned_asset") { guard data["id"] == .string(entityID),data["immutable"].boolValue,data["note_id"].stringValue != nil else { throw MioError("archive_corrupt","Invalid pinned asset owner") } }
                if data["kind"] == .string("memory_file") {
                    guard data["id"] == .string(entityID),data["immutable"].boolValue,data["note_id"].stringValue != nil,data["captured_revision_id"].stringValue != nil,data["space_id"].stringValue != nil,data["file_version"].stringValue != nil,data["byte_count"].intValue==bytes.count else { throw MioError("archive_corrupt","Invalid immutable file identity") }
                    if !data["purged"].boolValue {
                        guard data["file_version"]==data["sha256"] else { throw MioError("archive_corrupt","Original file version differs from its content hash") }
                        _ = try prepareCapturedFile(["file_name":data["file_name"],"mime_type":data["mime_type"],"file_base64":data["bytes"]],noteID:entityID,revisionID:entityID,spaceID:data["space_id"].stringValue!,maximumBytes:20_000_000)
                    }
                }
            default: break
            }
            result.append(r)
        }
        let allRecords = try db.rows("SELECT json FROM records").map { try decode($0["json"]!) } + result
        let redactedNotes = Set(allRecords.filter { $0["kind"].stringValue == "note.redact" }.compactMap { $0["entity_id"].stringValue })
        let purgeRecords = allRecords.filter { $0["kind"].stringValue == "session.purge" }
        let purgedEvents = Set(purgeRecords.flatMap { $0["data"]["event_ids"].arrayValue.compactMap(\.stringValue) })
        let clearedPurges = Set(allRecords.filter { $0["kind"].stringValue == "session.restore" }.flatMap { $0["data"]["purge_ids"].arrayValue.compactMap(\.stringValue) })
        let activePurgedSessions = Set(purgeRecords.filter { !clearedPurges.contains($0["id"].stringValue!) }.compactMap { $0["entity_id"].stringValue })
        var immutableEntities: [String:JSONValue] = [:]
        let boundFileIDs=Set(allRecords.filter{$0["kind"] == .string("attachment") && $0["data"]["kind"] == .string("memory_file")}.compactMap{$0["entity_id"].stringValue})
        let pinnedIDs=Set(allRecords.filter{$0["kind"] == .string("attachment") && $0["data"]["kind"] == .string("pinned_asset")}.compactMap{$0["entity_id"].stringValue})
        guard allRecords.filter({$0["kind"] == .string("attachment") && pinnedIDs.contains($0["entity_id"].stringValue ?? "")}).allSatisfy({$0["data"]["kind"] == .string("pinned_asset")}) else { throw MioError("invalid_replica","A pinned asset cannot become another attachment kind") }
        guard allRecords.filter({$0["kind"] == .string("attachment") && boundFileIDs.contains($0["entity_id"].stringValue ?? "")}).allSatisfy({$0["data"]["kind"] == .string("memory_file")}) else { throw MioError("invalid_replica","An immutable file cannot become a legacy attachment") }
        for record in allRecords where ["revision","event"].contains(record["kind"].stringValue ?? "") || (record["kind"] == .string("attachment") && ["memory_file","pinned_asset"].contains(record["data"]["kind"].stringValue ?? "")) {
            let kind = record["kind"].stringValue!, entityID = record["entity_id"].stringValue!, key = kind + ":" + entityID
            var data = record["data"].objectValue
            let purgeAllowed = ["revision","attachment"].contains(kind) ? redactedNotes.contains(data["note_id"]?.stringValue ?? "") : (purgedEvents.contains(entityID) || activePurgedSessions.contains(data["session_id"]?.stringValue ?? ""))
            let erasedFields = kind == "revision" ? ["title","body","status","source_ids","purged"] : kind == "attachment" ? ["bytes","sha256","file_name","relative_path","byte_count","mime_type","purged"] : ["text","purged","request","result_refs","issued_graph"]
            if purgeAllowed { for field in erasedFields { data.removeValue(forKey:field) } }
            let payload = JSONValue.object(data)
            if let old = immutableEntities[key], old != payload { throw MioError("record_conflict","An immutable entity ID has conflicting content") }
            immutableEntities[key] = payload
        }
        let spaces = Set(allRecords.filter { $0["kind"].stringValue == "space" }.compactMap { $0["entity_id"].stringValue })
        let revisions = allRecords.filter { $0["kind"].stringValue == "revision" }.map { $0["data"] }
        var noteSpaces: [String:Set<String>] = [:], sessionSpaces: [String:Set<String>] = [:]
        for revision in revisions { noteSpaces[revision["note_id"].stringValue!,default:[]].insert(revision["space_id"].stringValue!) }
        for record in allRecords where ["session","session.restore"].contains(record["kind"].stringValue ?? "") { sessionSpaces[record["entity_id"].stringValue!,default:[]].insert(record["data"]["space_id"].stringValue!) }
        guard noteSpaces.values.allSatisfy({ $0.count == 1 }),sessionSpaces.values.allSatisfy({ $0.count == 1 }) else { throw MioError("invalid_replica","Entity ownership cannot change between spaces") }
        for record in allRecords where record["kind"].stringValue == "event" { let event = record["data"]; if let owner = sessionSpaces[event["session_id"].stringValue ?? ""]?.first, owner != event["space_id"].stringValue { throw MioError("invalid_replica","Event belongs to a different session space") } }
        let revisionIDs = Set(revisions.compactMap { $0["id"].stringValue })
        let files=Dictionary(allRecords.filter{$0["kind"] == .string("attachment") && $0["data"]["kind"] == .string("memory_file")}.map{($0["entity_id"].stringValue!,$0["data"])},uniquingKeysWith:{first,_ in first})
        for file in files.values { if let owner=revisions.first(where:{$0["id"]==file["captured_revision_id"]}) { guard owner["note_id"]==file["note_id"],owner["space_id"]==file["space_id"],owner["file_ids"].arrayValue.contains(file["id"]) else { throw MioError("invalid_replica","Original file binding does not match its captured revision") } } }
        for revision in revisions {
            for ref in revision["file_ids"].arrayValue {
                guard let id=ref.stringValue else { throw MioError("archive_corrupt","File references must be IDs") }
                if let file=files[id] { guard file["note_id"]==revision["note_id"],file["space_id"]==revision["space_id"] else { throw MioError("archive_corrupt","A file cannot be retargeted to another note") } }
                else if strict { throw MioError("archive_corrupt","Original file is missing from the archive") }
            }
        }
        let noteIDs = Set(revisions.compactMap { $0["note_id"].stringValue })
        let sessions = Set(allRecords.filter { ["session","session.restore"].contains($0["kind"].stringValue ?? "") }.compactMap { $0["entity_id"].stringValue })
        for r in result where strict {
            let kind = r["kind"].stringValue!, data = r["data"]
            if ["revision","session","session.restore","event","attachment"].contains(kind) { guard spaces.contains(data["space_id"].stringValue ?? "") else { throw MioError("archive_corrupt", "Record references a missing space") } }
            if ["note.move","note.assets"].contains(kind) {
                for id in data["asset_ids"].arrayValue { guard allRecords.contains(where:{$0["kind"] == .string("attachment") && $0["entity_id"] == id && $0["data"]["kind"] == .string("pinned_asset") && $0["data"]["note_id"] == data["note_id"]}) else { throw MioError("archive_corrupt","Missing or foreign pinned attachment") } }
                if let anchor=data["asset_revision_id"].stringValue { guard revisions.contains(where:{$0["id"] == .string(anchor) && $0["note_id"]==data["note_id"]}) else { throw MioError("archive_corrupt","Missing location attachment revision") } }
                if kind == "note.assets" { guard revisions.contains(where:{$0["id"]==data["revision_id"] && $0["note_id"]==data["note_id"]}) else { throw MioError("archive_corrupt","Missing attachment binding revision") } }
            }
            if ["note.move","note.assets"].contains(kind) { guard noteIDs.contains(r["entity_id"].stringValue ?? ""),spaces.contains(data["space_id"].stringValue ?? "") else { throw MioError("archive_corrupt","Missing note location endpoint") } }
            if kind == "revision" { guard data["parent_ids"].arrayValue.allSatisfy({ revisionIDs.contains($0.stringValue ?? "") }) else { throw MioError("archive_corrupt", "Missing revision parent") } }
            if kind == "event" { guard sessions.contains(data["session_id"].stringValue ?? "") else { throw MioError("archive_corrupt", "Missing history session") } }
            if kind == "event",data["kind"].stringValue == "memory_operation",data["phase"].stringValue == "delivery",!data["purged"].boolValue {
                guard let endID=data["execution_end_event_id"].stringValue, let end=allRecords.first(where:{$0["kind"].stringValue == "event" && $0["entity_id"].stringValue == endID})?["data"],end["phase"].stringValue == "end",end["interaction_id"] == data["interaction_id"],end["session_id"] == data["session_id"],end["space_id"] == data["space_id"] else { throw MioError("archive_corrupt","Delivery is missing its matching execution end") }
            }
            if kind == "link" { guard noteIDs.contains(data["from_note_id"].stringValue ?? ""),noteIDs.contains(data["to_note_id"].stringValue ?? "") else { throw MioError("archive_corrupt", "Missing link endpoint") } }
            if kind == "attachment",data["kind"] == .string("pinned_asset") { guard noteIDs.contains(data["note_id"].stringValue ?? "") else { throw MioError("archive_corrupt","Missing pinned asset owner") } }
            if kind == "attachment", data["kind"] == .string("memory_file") {
                guard let noteID=data["note_id"].stringValue, let revisionID=data["captured_revision_id"].stringValue,
                      let owner=revisions.first(where:{$0["id"] == .string(revisionID)}), owner["note_id"] == .string(noteID), owner["space_id"] == data["space_id"],
                      owner["file_ids"].arrayValue.contains(data["id"]) else { throw MioError("archive_corrupt","File binding does not match its immutable parent revision") }
            }
            if kind == "connection" { guard spaces.contains(data["from_space_id"].stringValue ?? ""),spaces.contains(data["to_space_id"].stringValue ?? "") else { throw MioError("archive_corrupt", "Missing mount endpoint") } }
        }
        let revisionMap = Dictionary(revisions.map { ($0["id"].stringValue!, $0) },uniquingKeysWith:{ first,_ in first })
        var visiting = Set<String>(), visited = Set<String>()
        func visit(_ id: String) throws {
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted else { throw MioError("archive_corrupt", "Revision ancestry cycle") }
            for parent in revisionMap[id]?["parent_ids"].arrayValue ?? [] { try visit(parent.stringValue ?? "") }
            visiting.remove(id); visited.insert(id)
        }
        for id in revisionMap.keys { try visit(id) }
        return result
    }
    func mergeDocument(_ doc: JSONValue, restore: Bool) throws -> JSONValue {
        let records = try validateDocument(doc,strict:restore)
        if try restore && !all("space").isEmpty { throw MioError("restore_requires_empty", "Restore requires an empty Mio database; use merge for existing memory") }
        // Install deletion records first so old source payload can never enter projections.
        let priority: [String:Int] = ["session.purge":0,"note.redact":0,"space":1,"session.restore":2,"session":3,"revision":4,"note.delete":5,"event":6]
        var inserted = 0
        for record in records.sorted(by: { (priority[$0["kind"].stringValue!] ?? 7) < (priority[$1["kind"].stringValue!] ?? 7) }) {
            let existed = try db.rows("SELECT id FROM records WHERE id=?", [record["id"].stringValue!]).isEmpty == false
            try insertRecord(record,pending:true)
            if !existed { inserted += 1 }
        }
        try applyAvailableRecords()
        for p in doc["profiles"].arrayValue {
            guard let id = p["id"].stringValue, try entity("profile",id) == nil else { continue }
            var d = p.objectValue; d.removeValue(forKey:"token_hash"); d.removeValue(forKey:"token"); d["revoked"] = .bool(true); try put("profile",.object(d))
        }
        for audit in doc["audit"].arrayValue {
            guard let id = audit["id"].stringValue, audit["timestamp"].stringValue != nil, audit["method"].stringValue != nil else { throw MioError("archive_corrupt","Invalid audit event") }
            try db.exec("INSERT OR IGNORE INTO audit VALUES(?,?)",[id,try encode(audit)])
        }
        for note in try all("note") { try refreshNote(note["id"].stringValue!) }
        for session in try all("session") { try purgeProjection(session["id"].stringValue!); try refreshSession(session["id"].stringValue!) }
        return .object(["imported_records": .number(Double(inserted)),"total_records": .number(Double(records.count)),"profiles_active": .bool(false)])
    }
    func archiveExport(_ p: [String: JSONValue]) throws -> JSONValue {
        let path = try p.required("path"), document = try replicaDocument(), payload = try document.encoded()
        _ = try validateDocument(document,strict:true)
        let archive: JSONValue = .object(["format": .string("mio-archive"),"schema_version": .number(Double(Self.schema)),"manifest": .object(["sha256": .string(hash(payload)),"record_count": .number(Double(document["records"].arrayValue.count)),"created_at": .string(now())]),"document": document])
        try archive.encoded().write(to:URL(fileURLWithPath:path),options:.atomic)
        return .object(["path": .string(path),"sha256": .string(hash(payload)),"record_count": .number(Double(document["records"].arrayValue.count)),"excluded": .array([.string("credentials"),.string("cloud_cursors")])])
    }
    func archiveImport(_ p: [String: JSONValue]) throws -> JSONValue {
        let path = try p.required("path"), url = URL(fileURLWithPath:path)
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size < 250_000_000 else { throw MioError("archive_too_large", "Archive exceeds the import size limit") }
        let a = try JSONValue.decode(Data(contentsOf:url))
        guard a["format"].stringValue == "mio-archive", a["manifest"]["sha256"].stringValue == hash(try a["document"].encoded()) else { throw MioError("archive_corrupt", "Archive manifest hash does not match") }
        let mode = p.string("mode","merge"); guard ["merge","restore"].contains(mode) else { throw MioError("invalid_params", "Archive mode must be merge or restore") }
        // Validation runs completely before applying and execute encloses all changes in one SQLite transaction.
        _ = try validateDocument(a["document"],strict:true)
        return try mergeDocument(a["document"],restore:mode == "restore")
    }
}
