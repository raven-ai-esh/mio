import Foundation

extension MioStore {
    static let workspaceSections:Set<String>=["catalog","memory","history","activity","queue"]
    func ensureWorkspaceGenerations() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS workspace_generations(section TEXT PRIMARY KEY,generation INTEGER NOT NULL)")
        let kinds:[String:[String]]=["catalog":["space","connection","profile"],"memory":["space","note","link","connection"],"history":["session","event","interaction"],"activity":["event","interaction"]]
        for section in Self.workspaceSections { try db.exec("INSERT OR IGNORE INTO workspace_generations VALUES(?,0)",[section]) }
        for (section,values) in kinds {
            let names=values.map{"'"+$0+"'"}.joined(separator:",")
            for action in ["INSERT","UPDATE","DELETE"] {
                let row=action == "DELETE" ? "old":"new"
                try db.exec("CREATE TRIGGER IF NOT EXISTS workspace_\(section)_\(action.lowercased()) AFTER \(action) ON entities WHEN \(row).kind IN (\(names)) BEGIN UPDATE workspace_generations SET generation=generation+1 WHERE section='\(section)'; END")
            }
        }
        for table in ["outbox","records","audit"] {
            let section=table == "audit" ? "activity":"queue"
            for action in ["INSERT","UPDATE","DELETE"] { try db.exec("CREATE TRIGGER IF NOT EXISTS workspace_\(table)_\(action.lowercased()) AFTER \(action) ON \(table) BEGIN UPDATE workspace_generations SET generation=generation+1 WHERE section='\(section)'; END") }
        }
    }
    /// Native-owner projection. Public MCP tools continue to use their scoped
    /// routes; no workspace or administration method is added to the bridge.
    public func workspaceSnapshot(since:[String:String]) throws -> JSONValue {
        lock.lock();defer { lock.unlock() }
        try recoverMemoryInteractions()
        return try db.transaction {
            let versions=try db.rows("SELECT section,generation FROM workspace_generations")
            let tokens=Dictionary(uniqueKeysWithValues:versions.map{($0["section"]!,$0["generation"]!)})
            let changed=Set(tokens.keys.filter { since[$0] != tokens[$0] })
            var value=changed.isEmpty ? [:]:try snapshot(scope(.human),projection:"compact",sections:changed).objectValue
            value["workspace_tokens"] = .object(tokens.mapValues(JSONValue.string))
            return .object(value)
        }
    }
    func snapshotSessions(_ scope:Scope) throws -> [JSONValue] {
        let sessions=try all("session").filter { scope.human || (!$0["deleted"].boolValue && scope.readable.contains($0["space_id"].stringValue ?? "")) }
        guard scope.human else { return try sessions.compactMap { try visibleSession($0,scope) } }
        // Owner aggregates have no ACL filter. One pass per table replaces
        // three queries per session, including sessions with no new activity.
        let events=try db.rows("SELECT json_extract(json,'$.session_id') AS session,count(*) AS n,max(json_extract(json,'$.timestamp')) AS latest FROM entities WHERE kind='event' GROUP BY json_extract(json,'$.session_id')")
        let calls=try db.rows("SELECT json_extract(json,'$.session_id') AS session,count(*) AS n FROM entities WHERE kind='interaction' GROUP BY json_extract(json,'$.session_id')")
        let targets=try db.rows("SELECT json_extract(entities.json,'$.session_id') AS session,target.value AS space FROM entities JOIN json_each(entities.json,'$.target_space_ids') target WHERE entities.kind='event' AND target.type='text' GROUP BY session,space ORDER BY session,space")
        let eventByID=Dictionary(events.compactMap { row in row["session"].map{($0,row)} },uniquingKeysWith:{_,last in last})
        let callByID=Dictionary(calls.compactMap { row in row["session"].map{($0,row["n"] ?? "0")} },uniquingKeysWith:{_,last in last})
        var targetByID=[String:[JSONValue]]()
        for row in targets { if let id=row["session"],let space=row["space"] { targetByID[id,default:[]].append(.string(space)) } }
        return sessions.map { session in
            guard session["source"].stringValue == Self.interactionSource else { return session }
            let id=session["id"].stringValue!,event=eventByID[id]
            var value=session.objectValue
            value["event_count"] = .number(Double(event?["n"] ?? "0") ?? 0)
            value["updated_at"] = .string(event?["latest"] ?? session["opened_at"].stringValue ?? "")
            value["interaction_count"] = .number(Double(callByID[id] ?? "0") ?? 0)
            value["target_space_ids"] = .array(targetByID[id] ?? [])
            return .object(value)
        }
    }
}
