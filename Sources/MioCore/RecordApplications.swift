import Foundation

extension MioStore {
    /// Derived, transactional work queue. Retained records are not a work list:
    /// replaying them on every cloud batch repeatedly rebuilds all history.
    func ensureRecordApplications() throws {
        try db.transaction {
            try db.exec("CREATE TABLE IF NOT EXISTS pending_record_applications(record_id TEXT PRIMARY KEY)")
            try db.exec("CREATE TRIGGER IF NOT EXISTS application_insert AFTER INSERT ON records BEGIN INSERT OR IGNORE INTO pending_record_applications VALUES(new.id); END")
            try db.exec("CREATE TRIGGER IF NOT EXISTS application_update AFTER UPDATE ON records WHEN old.json IS NOT new.json BEGIN INSERT OR IGNORE INTO pending_record_applications VALUES(new.id); END")
            try db.exec("CREATE TRIGGER IF NOT EXISTS application_delete AFTER DELETE ON records BEGIN DELETE FROM pending_record_applications WHERE record_id=old.id; END")
            guard try db.rows("SELECT value FROM metadata WHERE key='record_application_queue'").first?["value"] != "1" else { return }
            // Legacy stores applied each record on insertion. Recover missing
            // projections and newer/tombstone latest values, not all history.
            // Derived-only operations have no per-record projection to inspect.
            try db.exec("""
                INSERT OR IGNORE INTO pending_record_applications
                SELECT r.id FROM records r WHERE
                  r.kind IN ('note.assets','note.delete','note.redact','session.purge')
                  OR (r.kind IN ('revision','event') AND NOT EXISTS
                    (SELECT 1 FROM entities e WHERE e.kind=r.kind AND e.id=r.entity_id)
                    AND (r.kind!='event' OR coalesce(json_type(r.json,'$.data.purged'),'null')!='true'))
                  OR (r.kind='session.restore' AND NOT EXISTS
                    (SELECT 1 FROM entities e WHERE e.kind='session_restore' AND e.id=r.id))
                  OR (r.kind IN ('space','session','link','connection','profile','attachment','note.move') AND NOT EXISTS
                    (SELECT 1 FROM entities e WHERE e.kind=CASE r.kind WHEN 'note.move' THEN 'note_location' ELSE r.kind END AND e.id=r.entity_id
                      AND coalesce(json_extract(e.json,'$.record_timestamp'),'') || coalesce(json_extract(e.json,'$.last_record'),'') >= json_extract(r.json,'$.timestamp') || r.id
                      AND (coalesce(json_type(r.json,'$.data.deleted'),'null')!='true' OR json_type(e.json,'$.deleted')='true')
                      AND (coalesce(json_type(r.json,'$.data.revoked'),'null')!='true' OR json_type(e.json,'$.revoked')='true')))
                """)
            try applyAvailableRecords(rejectInvalid:false)
            try db.exec("INSERT OR REPLACE INTO metadata VALUES('record_application_queue','1')")
        }
    }
}
