import XCTest
@testable import MioCore

final class RecordApplicationTests:XCTestCase {
    var directory:URL!,store:MioStore!
    override func setUpWithError() throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent("mio-application-tests-"+UUID().uuidString);store=try MioStore(directory:directory) }
    override func tearDownWithError() throws { store=nil;try FileManager.default.removeItem(at:directory) }
    func raw(_ kind:String,_ entity:String,_ data:JSONValue,time:String="2026-10-18T10:00:00.000Z") -> JSONValue {
        .object(["id":.string(UUID().uuidString),"kind":.string(kind),"entity_id":.string(entity),"data":data,"timestamp":.string(time),"device_id":.string("fictional-legacy-writer")])
    }
    func insertLegacy(_ r:JSONValue) throws { try store.db.exec("INSERT INTO records VALUES(?,?,?,?)",[r["id"].stringValue!,r["kind"].stringValue!,r["entity_id"].stringValue!,try store.encode(r)]) }
    func event(_ id:String,space:JSONValue,session:String) -> JSONValue { .object(["id":.string(id),"space_id":space,"session_id":.string(session),"source_id":.string(id),"text":.string("Fictional retained event"),"timestamp":.string("2026-10-18T10:00:00.000Z")]) }
    func session(_ id:String,space:JSONValue) throws { _=try store.record("session",entityID:id,data:.object(["id":.string(id),"space_id":space,"external_id":.string(id),"source":.string("synthetic_fixture")])) }
    func testMissingDependencyDrainsAfterLocalRecordAndSurvivesRestart() throws {
        let space=try store.execute("space.create",params:["name":.string("Deferred")])["id"]
        let r=raw("event","waiting",event("waiting",space:space,session:"later"))
        try store.db.transaction { try store.insertRecord(r,pending:false) }
        XCTAssertEqual(try store.db.rows("SELECT record_id FROM pending_record_applications").count,1)
        store=nil;store=try MioStore(directory:directory)
        XCTAssertNil(try store.entity("event","waiting"))
        try store.db.transaction { try session("later",space:space) }
        XCTAssertEqual(try store.entity("event","waiting")?["text"],.string("Fictional retained event"))
        XCTAssertTrue(try store.db.rows("SELECT record_id FROM pending_record_applications").isEmpty)
        store=nil;store=try MioStore(directory:directory)
        XCTAssertEqual(try store.entity("session","later")?["event_count"].intValue,1)
    }
    func testOlderWriterTriggersRecoverNewRecordsWithoutRepeatingBootstrap() throws {
        let space=try store.execute("space.create",params:["name":.string("Old writer")])["id"]
        try store.db.transaction { try session("existing",space:space) }
        try insertLegacy(raw("event","late-event",event("late-event",space:space,session:"existing")))
        XCTAssertEqual(try store.db.rows("SELECT record_id FROM pending_record_applications").count,1)
        store=nil;store=try MioStore(directory:directory)
        XCTAssertNotNil(try store.entity("event","late-event"))
        XCTAssertTrue(try store.db.rows("SELECT record_id FROM pending_record_applications").isEmpty)
    }
    func testLegacyBootstrapRecoversMissingProjectionAndOlderTombstone() throws {
        let space=try store.execute("space.create",params:["name":.string("Bootstrap")])["id"]
        let first=try store.execute("note.create",params:["space_id":space,"title":.string("A")]),second=try store.execute("note.create",params:["space_id":space,"title":.string("B")])
        let link:JSONValue = .object(["id":.string("legacy-link"),"from_note_id":first["id"],"to_note_id":second["id"],"deleted":.bool(false)])
        _=try store.record("link",entityID:"legacy-link",data:link)
        try store.db.exec("DROP TRIGGER application_insert");try store.db.exec("DROP TRIGGER application_update");try store.db.exec("DROP TRIGGER application_delete")
        try store.db.exec("DROP TABLE pending_record_applications");try store.db.exec("DELETE FROM metadata WHERE key='record_application_queue'")
        var tombstone=link.objectValue;tombstone["deleted"] = .bool(true)
        try insertLegacy(raw("link","legacy-link",.object(tombstone),time:"2020-01-01T00:00:00.000Z"))
        let revision=try XCTUnwrap(store.entity("revision",first["revision_id"].stringValue!));var child=revision.objectValue
        child["id"] = .string("legacy-child");child["parent_ids"] = .array([first["revision_id"]]);child["body"] = .string("Recovered child revision");child["timestamp"] = .string("2099-01-01T00:00:00.000Z")
        try insertLegacy(raw("revision","legacy-child",.object(child)))
        store=nil;store=try MioStore(directory:directory)
        XCTAssertEqual(try store.entity("link","legacy-link")?["deleted"],.bool(true))
        XCTAssertEqual(try store.entity("note",first["id"].stringValue!)?["body"],.string("Recovered child revision"))
        XCTAssertEqual(try store.entity("revision",revision["id"].stringValue!)?["body"],revision["body"])
        XCTAssertTrue(try store.db.rows("SELECT record_id FROM pending_record_applications").isEmpty)
    }
    func testQueueAndProjectionRollbackTogether() throws {
        let r=raw("space","rolled-back",.object(["id":.string("rolled-back"),"name":.string("Rollback")]))
        XCTAssertThrowsError(try store.db.transaction {
            try store.insertRecord(r,pending:true)
            XCTAssertNotNil(try store.entity("space","rolled-back"))
            throw MioError("controlled_failure","Rollback the complete write")
        })
        XCTAssertNil(try store.entity("space","rolled-back"))
        XCTAssertTrue(try store.db.rows("SELECT id FROM records WHERE id=?",[r["id"].stringValue!]).isEmpty)
        XCTAssertTrue(try store.db.rows("SELECT record_id FROM pending_record_applications").isEmpty)
    }
    func testQueuedRevisionCannotResurrectBodyAfterEarlierRedaction() throws {
        let space=try store.execute("space.create",params:["name":.string("Purged queue")])["id"]
        let note=try store.execute("note.create",params:["space_id":space,"title":.string("Private fictional note"),"body":.string("Fictional plaintext")])
        var child=try XCTUnwrap(store.entity("revision",note["revision_id"].stringValue!)).objectValue
        child["id"] = .string("queued-child");child["parent_ids"] = .array([note["revision_id"]]);child["timestamp"] = .string("2099-01-01T00:00:00.000Z")
        try insertLegacy(raw("revision","queued-child",.object(child)))
        try insertLegacy(raw("note.redact",note["id"].stringValue!,.object(["note_id":note["id"],"session_id":.string("fictional-purge")])))
        try store.db.transaction { try store.applyAvailableRecords() }
        XCTAssertEqual(try store.entity("revision","queued-child")?["body"],.string(""))
        XCTAssertEqual(try store.entity("note",note["id"].stringValue!)?["body"],.string(""))
        XCTAssertFalse(try store.execute("replica.export").encoded().contains(Data("Fictional plaintext".utf8)))
        XCTAssertTrue(try store.db.rows("SELECT record_id FROM pending_record_applications").isEmpty)
    }
    func testInvalidDeferredRecordCannotRollbackLocalDependencyOrBlockReopen() throws {
        let a=try store.execute("space.create",params:["name":.string("Event space")])["id"],b=try store.execute("space.create",params:["name":.string("Session space")])["id"]
        try store.db.transaction { try store.insertRecord(raw("event","foreign-event",event("foreign-event",space:a,session:"future-session")),pending:false) }
        try store.db.transaction { try session("future-session",space:b) }
        XCTAssertEqual(try store.entity("session","future-session")?["space_id"],b)
        XCTAssertNil(try store.entity("event","foreign-event"))
        XCTAssertEqual(try store.execute("sync.status")["pending_dependencies"].intValue,1)
        store=nil;store=try MioStore(directory:directory)
        XCTAssertNotNil(try store.entity("session","future-session"))
        XCTAssertThrowsError(try store.execute("replica.merge",params:["document":.object(["schema_version":.number(2),"format":.string("mio-records"),"records":.array([])])]))
        XCTAssertNil(try store.entity("event","foreign-event"))
    }
}
