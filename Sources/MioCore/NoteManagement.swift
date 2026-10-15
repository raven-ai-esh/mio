import Foundation

extension MioStore {
    /// Revisions keep their immutable origin. Current access follows the note's
    /// location, independently of which content head wins an offline merge.
    func currentOwnership(_ value: JSONValue, kind: String) throws -> JSONValue {
        let ownerID: String?
        switch kind {
        case "revision": ownerID=value["note_id"].stringValue
        case "attachment" where ["memory_file","pinned_asset"].contains(value["kind"].stringValue ?? ""): ownerID=value["note_id"].stringValue
        case "link": ownerID=value["from_note_id"].stringValue
        default: ownerID=nil
        }
        guard let ownerID,let note=try entity("note",ownerID) else { return value }
        var fields=value.objectValue;fields["space_id"]=note["space_id"]
        return .object(fields)
    }
    /// File bindings follow content ancestry, not location intent. In particular,
    /// a stale replica importing a new attachment cannot undo a user's move.
    func noteAssetBindings(_ noteID: String, revision: JSONValue, location: JSONValue?) throws -> [JSONValue] {
        var candidates=[String:[(String,[JSONValue])]]()
        if let location,!location["asset_ids"].arrayValue.isEmpty {
            let anchor=location["asset_revision_id"].stringValue ?? revision["id"].stringValue!
            candidates[anchor,default:[]].append(((location["record_timestamp"].stringValue ?? "")+(location["last_record"].stringValue ?? ""),location["asset_ids"].arrayValue))
        }
        for record in try records("note.assets",noteID) where try canApply(record) {
            candidates[record["data"]["revision_id"].stringValue!,default:[]].append(((record["timestamp"].stringValue ?? "")+(record["id"].stringValue ?? ""),record["data"]["asset_ids"].arrayValue))
        }
        var pending=[revision["id"].stringValue!],seen=Set<String>()
        while !pending.isEmpty {
            let matches=pending.flatMap { candidates[$0] ?? [] }
            if let winner=matches.max(by:{$0.0<$1.0}) { return winner.1 }
            var next=[String]()
            for id in pending where seen.insert(id).inserted {
                guard let parent=try entity("revision",id) else { continue }
                let chosen=parent["resolved_from"].stringValue ?? parent["restored_from"].stringValue
                if let chosen,let source=try entity("revision",chosen),source["note_id"].stringValue == noteID { if !seen.contains(chosen) { next.append(chosen) } }
                else { next += parent["parent_ids"].arrayValue.compactMap(\.stringValue).filter{!seen.contains($0)} }
            }
            pending=next
        }
        return location?["asset_ids"].arrayValue ?? []
    }
    func bulkNotes(_ p: [String:JSONValue], _ s: Scope) throws -> JSONValue {
        guard case .array(let input)=p["note_ids"],!input.isEmpty,input.count<=10000,input.allSatisfy({$0.stringValue != nil}) else { throw MioError("invalid_params","Select at least one note") }
        let ids=Set(input.compactMap(\.stringValue)).sorted(),action=p.string("action")
        guard ["move","status","delete"].contains(action) else { throw MioError("invalid_params","Unknown bulk action") }
        let destination=action == "move" ? try p.required("space_id"):""
        if action == "move" { try requireSpace(destination,s,write:true) }
        let status=p.string("status")
        if action == "status",status.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || status.count>100 { throw MioError("invalid_params","Choose a note status") }
        let notes=try ids.map { try requireEntity("note",$0,s,write:true,allowDeleted:action == "delete") }
        for note in notes {
            guard !note["purged"].boolValue,note["status"] != .string("purged") else { throw MioError("source_purged","A selected note was cleared") }
            if let expected=p["expected_spaces"]?.objectValue[note["id"].stringValue!],expected != note["space_id"] { throw MioError("selection_changed","A selected note moved. Refresh the selection and try again.") }
            if action == "status",note["has_conflict"].boolValue { throw MioError("revision_conflict","Resolve conflicting notes before changing their status") }
        }
        var changed=0
        for note in notes {
            let id=note["id"].stringValue!
            switch action {
            case "move" where note["space_id"].stringValue != destination:
                try preserveWikiBindings(note)
                let assets=try copyReferencedAssets(note,to:destination)
                _=try record("note.move",entityID:id,data:.object(["note_id":.string(id),"space_id":.string(destination),"asset_ids":.array(assets),"asset_revision_id":note["revision_id"]]));changed+=1
            case "status" where note["status"].stringValue != status:
                _=try changeNote("note.update",["note_id":.string(id),"expected_revision":note["revision_id"],"status":.string(status)],s);changed+=1
            case "delete" where !note["deleted"].boolValue:
                _=try record("note.delete",entityID:id,data:.object(["space_id":note["space_id"],"revision_id":note["revision_id"]]));changed+=1
            default:break
            }
        }
        return .object(["action":.string(action),"note_ids":.array(ids.map(JSONValue.string)),"changed_count":.number(Double(changed))])
    }
    /// Legacy imported Markdown assets can be shared by many notes. Copy only
    /// references found in this note's versions; never transfer a whole vault.
    @discardableResult func copyReferencedAssets(_ note: JSONValue, to destination: String) throws -> [JSONValue] {
        let assets=try all("attachment").filter { !$0["deleted"].boolValue && $0["kind"] != .string("memory_file") }
        let pattern=try NSRegularExpression(pattern:"!?\\[\\[([^\\]|#]+)(?:[^\\]]*)\\]\\]|!?\\[[^\\]]*\\]\\(([^)#]+)(?:[^)]*)\\)")
        var selected=[String:JSONValue]()
        for revision in try revisions(note["id"].stringValue!) {
            var owner=revision.objectValue;owner["space_id"]=note["space_id"];owner["asset_ids"]=note["asset_ids"]
            let body=revision["body"].stringValue ?? "",text=body as NSString
            for match in pattern.matches(in:body,range:NSRange(location:0,length:text.length)) {
                let range=match.range(at:match.range(at:1).location == NSNotFound ? 2:1)
                let matches=resolveExportAsset(text.substring(with:range),note:.object(owner),assets:assets)
                for asset in matches { selected[asset["id"].stringValue!]=asset }
            }
        }
        var result=[JSONValue]()
        for (id,asset) in selected.sorted(by:{$0.key<$1.key}) {
            if asset["space_id"].stringValue == destination { result.append(asset["id"]);continue }
            let copyID="asset-copy-"+hash(Data((id+"\u{0}"+(asset["sha256"].stringValue ?? "")+"\u{0}"+destination+"\u{0}"+(note["id"].stringValue ?? "")).utf8))
            result.append(.string(copyID))
            if try entity("attachment",copyID) != nil { continue }
            var fields=asset.objectValue;fields["id"] = .string(copyID);fields["space_id"] = .string(destination);fields["kind"] = .string("pinned_asset");fields["immutable"] = .bool(true);fields["note_id"] = note["id"]
            fields.removeValue(forKey:"last_record");fields.removeValue(forKey:"record_timestamp")
            _=try record("attachment",entityID:copyID,data:.object(fields))
        }
        return result
    }
}
