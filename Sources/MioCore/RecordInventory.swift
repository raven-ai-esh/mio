import Foundation

extension MioStore {
    func ensureRecordInventory() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS record_hashes(record_id TEXT PRIMARY KEY,content_hash TEXT NOT NULL)")
        for action in ["INSERT","UPDATE","DELETE"] {
            let row=action == "DELETE" ? "old":"new"
            let condition=action == "UPDATE" ? " WHEN old.json IS NOT new.json":""
            try db.exec("CREATE TRIGGER IF NOT EXISTS record_hash_\(action.lowercased()) AFTER \(action) ON records\(condition) BEGIN DELETE FROM record_hashes WHERE record_id=\(row).id; END")
        }
    }
    /// Payloads are decoded/hashed only after insertion or canonical redaction.
    /// The cache is local derived state; record IDs and delivery proofs retain
    /// the same canonical JSON hashes as replica.export and sync.ack.
    func recordInventory() throws -> [JSONValue] {
        for row in try db.rows("SELECT records.id,records.json FROM records LEFT JOIN record_hashes hashes ON hashes.record_id=records.id WHERE hashes.record_id IS NULL ORDER BY records.id") {
            let digest=hash(try decode(row["json"]!).encoded())
            try db.exec("INSERT INTO record_hashes VALUES(?,?) ON CONFLICT(record_id) DO UPDATE SET content_hash=excluded.content_hash",[row["id"]!,digest])
        }
        return try db.rows("SELECT records.id,hashes.content_hash FROM records JOIN record_hashes hashes ON hashes.record_id=records.id ORDER BY records.id").map { .object(["id":.string($0["id"]!),"content_hash":.string($0["content_hash"]!)]) }
    }
}
