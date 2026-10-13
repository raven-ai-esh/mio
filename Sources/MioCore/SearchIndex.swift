import Foundation

extension MioStore {
    func ensureSearchMapping() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS search_documents(fts_rowid INTEGER PRIMARY KEY,kind TEXT NOT NULL,id TEXT NOT NULL,content_hash TEXT NOT NULL,UNIQUE(kind,id))")
        try db.transaction {
            if try db.rows("SELECT value FROM metadata WHERE key='search_document_index_version'").first?["value"] != "1" {
                try rebuildSearchIndex()
                try db.exec("INSERT OR REPLACE INTO metadata VALUES('search_document_index_version','1')")
            }
        }
    }
    func rebuildSearchIndex() throws {
        try db.exec("DELETE FROM search_index")
        try db.exec("DELETE FROM search_documents")
        let spaces = Set(try all("space").filter { !$0["deleted"].boolValue }.compactMap { $0["id"].stringValue })
        for note in try all("note") where !note["deleted"].boolValue && note["status"].stringValue != "purged" && spaces.contains(note["space_id"].stringValue ?? "") {
            try indexDocument(kind:"note",id:note["id"].stringValue!,space:note["space_id"].stringValue!,revision:note["revision_id"].stringValue!,title:note["title"].stringValue!,text:note["body"].stringValue!,timestamp:note["updated_at"].stringValue!,status:note["status"].stringValue!)
        }
        let sessions = Set(try all("session").filter { !$0["deleted"].boolValue }.compactMap { $0["id"].stringValue })
        for event in try all("event") where !event["purged"].boolValue && spaces.contains(event["space_id"].stringValue ?? "") && sessions.contains(event["session_id"].stringValue ?? "") { try indexEvent(event) }
        // Mapping migration runs before the derived table's first creation.
        if try !db.rows("SELECT name FROM sqlite_master WHERE name='source_fragments'").isEmpty {
            let access=try scope(.human)
            for row in try db.rows("SELECT json FROM source_fragments WHERE current=1") {
                let fragment=try decode(row["json"]!)
                guard let live=try? requireFragment(fragment["id"].stringValue!,access),let note=try? requireEntity("note",live["note_id"].stringValue!,access),note["revision_id"]==live["indexed_note_revision"] else { continue }
                try indexDocument(kind:"fragment",id:live["id"].stringValue!,space:live["space_id"].stringValue!,revision:live["revision_id"].stringValue!,title:live["title"].stringValue ?? "",text:live["text"].stringValue ?? "",timestamp:live["timestamp"].stringValue ?? "",status:live["status"].stringValue ?? "")
            }
        }
    }
    func removeSearchDocument(kind: String, id: String) throws {
        guard let row = try db.rows("SELECT fts_rowid FROM search_documents WHERE kind=? AND id=?",[kind,id]).first else { return }
        try db.exec("DELETE FROM search_index WHERE rowid=?",[row["fts_rowid"]!])
        try db.exec("DELETE FROM search_documents WHERE kind=? AND id=?",[kind,id])
    }
    func indexDocument(kind: String, id: String, space: String, revision: String, title: String, text: String, timestamp: String, status: String) throws {
        let document: JSONValue = .object(["kind":.string(kind),"id":.string(id),"space_id":.string(space),"revision_id":.string(revision),"title":.string(title),"text":.string(text),"timestamp":.string(timestamp),"status":.string(status)])
        let digest = hash(try document.encoded())
        let existing = try db.rows("SELECT fts_rowid,content_hash FROM search_documents WHERE kind=? AND id=?",[kind,id]).first
        if existing?["content_hash"] == digest { return }
        let rowID: String
        if let existing {
            rowID = existing["fts_rowid"]!
            try db.exec("DELETE FROM search_index WHERE rowid=?",[rowID])
            try db.exec("UPDATE search_documents SET content_hash=? WHERE kind=? AND id=?",[digest,kind,id])
        } else {
            try db.exec("INSERT INTO search_documents(kind,id,content_hash) VALUES(?,?,?)",[kind,id,digest])
            rowID = try db.rows("SELECT last_insert_rowid() AS id").first!["id"]!
        }
        try db.exec("INSERT INTO search_index(rowid,id,kind,space_id,revision_id,title,text,timestamp,status) VALUES(?,?,?,?,?,?,?,?,?)",[rowID,id,kind,space,revision,title,text,timestamp,status])
    }
}
