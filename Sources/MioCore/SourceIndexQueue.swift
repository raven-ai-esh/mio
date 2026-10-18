import Foundation

extension MioStore {
    /// A local derived queue. Triggers also cover replica/archive projection
    /// writes; immutable notes and vectors retain their existing identities.
    func ensureSourceIndexQueue() throws {
        try db.transaction {
            try db.exec("CREATE INDEX IF NOT EXISTS source_jobs_state ON source_index_jobs(state,note_id)")
            try db.exec("CREATE INDEX IF NOT EXISTS source_fragments_current ON source_fragments(current)")
            try db.exec("CREATE TABLE IF NOT EXISTS source_index_members(note_id TEXT PRIMARY KEY,space_id TEXT NOT NULL,live INTEGER NOT NULL)")
            let space="CASE WHEN json_type(json,'$.space_id')='text' THEN json_extract(json,'$.space_id') ELSE '' END"
            let live="CASE WHEN coalesce(json_type(json,'$.deleted'),'null')<>'true' AND coalesce(json_type(json,'$.purged'),'null')<>'true' AND coalesce(json_extract(json,'$.status'),'')<>'purged' THEN 1 ELSE 0 END"
            if try db.rows("SELECT value FROM metadata WHERE key='source_queue_version'").first?["value"] != "1" {
                try db.exec("INSERT OR REPLACE INTO source_index_members SELECT id,\(space),\(live) FROM entities WHERE kind='note'")
                // One compact migration validates existing completed vectors;
                // startup never blindly schedules the whole corpus again.
                for row in try db.rows("SELECT jobs.note_id,jobs.signature,jobs.model_id,json_object('id',notes.id,'space_id',json_extract(notes.json,'$.space_id'),'revision_id',json_extract(notes.json,'$.revision_id'),'file_ids',json_extract(notes.json,'$.file_ids')) AS note FROM source_index_jobs jobs JOIN entities notes ON notes.kind='note' AND notes.id=jobs.note_id") {
                    if row["signature"] != (try indexSignature(decode(row["note"]!),modelID:row["model_id"]!)) {
                        try db.exec("UPDATE source_index_jobs SET state='pending',error='' WHERE note_id=?",[row["note_id"]!])
                    }
                }
                try db.exec("INSERT OR REPLACE INTO metadata VALUES('source_queue_version','1')")
            }
            try db.exec("INSERT OR IGNORE INTO source_index_jobs SELECT id,'','','pending','' FROM entities WHERE kind='note'")
            try db.exec("UPDATE source_index_jobs SET state='pending',error='' WHERE state='indexing'")
            let newSpace=space.replacingOccurrences(of:"json,",with:"new.json,")
            let newLive=live.replacingOccurrences(of:"json,",with:"new.json,")
            let membership="INSERT INTO source_index_members VALUES(new.id,\(newSpace),\(newLive)) ON CONFLICT(note_id) DO UPDATE SET space_id=excluded.space_id,live=excluded.live;"
            try db.exec("CREATE TRIGGER IF NOT EXISTS source_queue_insert AFTER INSERT ON entities WHEN new.kind='note' BEGIN \(membership) INSERT OR IGNORE INTO source_index_jobs VALUES(new.id,'','','pending',''); END")
            try db.exec("CREATE TRIGGER IF NOT EXISTS source_queue_membership AFTER UPDATE ON entities WHEN new.kind='note' BEGIN \(membership) END")
            let changed=["revision_id","file_ids","deleted","purged"].map { "json_extract(old.json,'$.\($0)') IS NOT json_extract(new.json,'$.\($0)')" }.joined(separator:" OR ")
            try db.exec("CREATE TRIGGER IF NOT EXISTS source_queue_revision AFTER UPDATE ON entities WHEN new.kind='note' AND (\(changed) OR (coalesce(json_extract(old.json,'$.status'),'')='purged')<>(coalesce(json_extract(new.json,'$.status'),'')='purged')) BEGIN INSERT INTO source_index_jobs VALUES(new.id,'','','pending','') ON CONFLICT(note_id) DO UPDATE SET state='pending',error=''; END")
            try db.exec("CREATE TRIGGER IF NOT EXISTS source_queue_delete AFTER DELETE ON entities WHEN old.kind='note' BEGIN DELETE FROM source_index_members WHERE note_id=old.id; DELETE FROM source_index_jobs WHERE note_id=old.id; END")
        }
    }
    var liveSourceJobJoin: String {
        " FROM source_index_jobs jobs JOIN source_index_members members ON members.note_id=jobs.note_id AND members.live=1 JOIN entities spaces ON spaces.kind='space' AND spaces.id=members.space_id AND coalesce(json_type(spaces.json,'$.deleted'),'null')<>'true'"
    }
    func selectSourceModel(_ modelID:String) throws {
        let previous=try db.rows("SELECT key,value FROM metadata WHERE key IN ('source_queue_model','source_queue_extractor')")
        let values=Dictionary(uniqueKeysWithValues:previous.map{($0["key"]!,$0["value"]!)})
        guard values["source_queue_model"] != modelID || values["source_queue_extractor"] != MioDocumentExtraction.version else { return }
        try db.transaction {
            if let extractor=values["source_queue_extractor"],extractor != MioDocumentExtraction.version { try db.exec("UPDATE source_index_jobs SET state='pending',error=''") }
            else { try db.exec("UPDATE source_index_jobs SET state='pending',error='' WHERE model_id<>?",[modelID]) }
            try db.exec("INSERT OR REPLACE INTO metadata VALUES('source_queue_model',?)",[modelID])
            try db.exec("INSERT OR REPLACE INTO metadata VALUES('source_queue_extractor',?)",[MioDocumentExtraction.version])
        }
    }
    func queueSourceIndex(_ noteID:String) throws {
        try db.exec("INSERT INTO source_index_jobs VALUES(?,'','','pending','') ON CONFLICT(note_id) DO UPDATE SET state='pending',error=''",[noteID])
    }
}
