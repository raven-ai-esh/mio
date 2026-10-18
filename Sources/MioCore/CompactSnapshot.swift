import Foundation

extension MioStore {
    func compactSnapshotNotes(_ scope: Scope) throws -> [JSONValue] {
        let removed = ["body","source_ids","parent_ids","cleared_deletions","timestamp","author","import_path","import_relative_path","import_source_namespace","restored_from","resolved_from"].map { "'$.\($0)'" }.joined(separator:",")
        let expression = "json_set(json_remove(json," + removed + "),'$.body_preview',coalesce(substr(json_extract(json,'$.body'),1,120),''),'$.body_omitted',json('true'))"
        let allowed: Set<String> = ["id","note_id","space_id","location_id","title","status","revision_id","head_revision_ids","updated_at","deleted","has_conflict","purged","body_preview","body_omitted","file_ids","content_kind"]
        let (condition,bindings) = snapshotScope(scope,kind:"note",excludeDeleted:!scope.human)
        return try db.rows("SELECT " + expression + " AS json FROM entities WHERE " + condition + " ORDER BY id",bindings).map { row in
            var values = try decodeProjected(row["json"]!).objectValue.filter { allowed.contains($0.key) }
            if values["purged"] == nil { values["purged"] = .bool(false) }
            return .object(values)
        }
    }
    func compactSnapshotEvents(_ scope: Scope) throws -> [JSONValue] {
        let expression = "json_set(json_remove(json,'$.text','$.request','$.issued_graph','$.result_refs','$.receipt','$.required_space_ids','$.target_space_ids'),'$.text_preview',coalesce(substr(json_extract(json,'$.text'),1,240),''),'$.text_omitted',json('true'))"
        let allowed: Set<String> = ["id","session_id","space_id","kind","role","timestamp","tool_name","outcome","source_id","source_sequence","generation","text_preview","text_omitted","interaction_id","phase","method","started_at","finished_at","duration_ms","outcome","replayed","delivery_state","observation_type","observed_at"]
        let (condition,bindings) = snapshotScope(scope,kind:"event",excludeDeleted:false)
        return try db.rows("SELECT " + expression + " AS json FROM entities WHERE " + condition + " ORDER BY json_extract(json,'$.timestamp') DESC LIMIT 200",bindings).map { .object(try decodeProjected($0["json"]!).objectValue.filter { allowed.contains($0.key) }) }
    }
    func decodeProjected(_ text: String) throws -> JSONValue { try autoreleasepool { try JSONValue(any:JSONSerialization.jsonObject(with:Data(text.utf8))) } }
    func snapshotScope(_ scope: Scope, kind: String, excludeDeleted: Bool) -> (String,[String]) {
        var condition = "kind=?", bindings = [kind]
        if !scope.human {
            guard !scope.readable.isEmpty else { return ("0",[]) }
            condition += " AND json_extract(json,'$.space_id') IN (" + Array(repeating:"?",count:scope.readable.count).joined(separator:",") + ")"
            bindings += scope.readable.sorted()
        }
        if kind == "event" { let (visibility,values) = eventVisibilitySQL(scope); condition += " AND " + visibility; bindings += values }
        if excludeDeleted { condition += " AND coalesce(json_extract(json,'$.deleted'),0)=0" }
        return (condition,bindings)
    }
}
