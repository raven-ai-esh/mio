import XCTest
import Foundation
@testable import MioCore

extension MioCoreTests {
    func testSparseQueuePreservesBooleanAndOptionalArrayTypes() throws {
        let db=try store(),s=try space(db,"Typed references")
        let note=try call(db,"note.create",["space_id":s,"title":.string("Typed"),"body":.string("Retained")])
        let session=try call(db,"history.import",["space_id":s,"source":.string("synthetic-test"),"external_id":.string("empty-fixture"),"events":.array([])])["session_id"]
        func incoming(_ kind: String,_ entity: String,_ data: [String:JSONValue]) throws -> JSONValue {
            var r: [String:JSONValue] = ["id":.string(UUID().uuidString),"kind":.string(kind),"entity_id":.string(entity),"data":.object(data),"timestamp":.string("2026-10-15T00:00:00Z"),"device_id":.string("fixture")]
            r["content_hash"] = .string(db.hash(try JSONValue.object(r).encoded()));return .object(r)
        }
        let eventID="sparse-numeric-purge",event=try incoming("event",eventID,["id":.string(eventID),"space_id":s,"session_id":session,"source_id":.string(eventID),"text":.string(""),"kind":.string("memory_operation"),"phase":.string("delivery"),"purged":.number(1),"execution_end_event_id":.string("missing-end")])
        _=try call(db,"replica.merge",["document":.object(["schema_version":.number(2),"format":.string("mio-records"),"records":.array([event])])])
        XCTAssertEqual(try call(db,"sync.pending")["pending_dependencies"].intValue,1,"Only JSON true may bypass the execution-end dependency")
        let assets=try incoming("note.assets",note["id"].stringValue!,["space_id":s,"note_id":note["id"],"revision_id":note["revision_id"],"asset_ids":.object(["legacy":.string("missing-asset")])])
        _=try call(db,"replica.merge",["document":.object(["schema_version":.number(2),"format":.string("mio-records"),"records":.array([assets])])])
        XCTAssertEqual(try call(db,"sync.pending")["pending_dependencies"].intValue,1,"Non-array optional metadata must retain the canApply empty-array semantics")
    }
    func testQueueDependencyCountMatchesAllRecordKindsWithoutReadingBodies() throws {
        let body=String(repeating:"large evidence ",count:5000)
        let db=try store(),s=try space(db,"Dependencies"),note=try call(db,"note.create",["space_id":s,"title":.string("Kept"),"body":.string(body)])
        let cases: [(String,[String:JSONValue])]=[
            ("session",["space_id":.string("absent-space")]),
            ("revision",["space_id":s,"note_id":note["id"],"parent_ids":.array([.string("absent-revision")])]),
            ("note.move",["space_id":s,"note_id":note["id"],"asset_revision_id":.string("absent-revision")]),
            ("note.assets",["space_id":s,"note_id":note["id"],"revision_id":note["revision_id"],"asset_ids":.array([.string("absent-asset")])]),
            ("attachment",["space_id":s,"kind":.string("pinned_asset"),"note_id":.string("absent-note")]),
            ("attachment",["space_id":s,"kind":.string("memory_file"),"captured_revision_id":.string("absent-revision")]),
            ("event",["space_id":s,"session_id":.string("absent-session")]),
            ("link",["from_note_id":note["id"],"to_note_id":.string("absent-note")]),
            ("connection",["from_space_id":s,"to_space_id":.string("absent-space")])
        ]
        for (index,item) in cases.enumerated() {
            // Isolated incomplete record fixture; each missing dependency must
            // remain pending, regardless of the large unrelated note payload.
            let r: JSONValue = .object(["id":.string("deferred-\(index)"),"kind":.string(item.0),"entity_id":note["id"],"data":.object(item.1),"timestamp":.string("2026-10-15T00:00:00Z"),"device_id":.string("fixture")])
            XCTAssertFalse(try db.canApply(r));try db.insertRecord(r,pending:false)
        }
        let expected=try db.db.rows("SELECT json FROM records").map{try db.decode($0["json"]!)}.filter{try !db.canApply($0)}.count
        XCTAssertEqual(expected,cases.count)
        XCTAssertEqual(try call(db,"sync.pending")["pending_dependencies"].intValue,expected)
        let reopened=try MioStore(directory:db.directory)
        XCTAssertEqual(try call(reopened,"sync.pending")["pending_dependencies"].intValue,expected)
        XCTAssertTrue(try call(reopened,"read",["kind":.string("note"),"id":note["id"]])["body"] == .string(body),"Full evidence body changed")
    }
}
