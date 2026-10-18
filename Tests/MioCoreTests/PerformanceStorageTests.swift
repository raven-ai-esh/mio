import XCTest
@testable import MioCore

final class PerformanceStorageTests: XCTestCase {
    var directory:URL!
    var store:MioStore!
    override func setUpWithError() throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("mio-performance-tests-"+UUID().uuidString)
        store=try MioStore(directory:directory)
    }
    override func tearDownWithError() throws { store=nil;try FileManager.default.removeItem(at:directory) }
    func testCompletedIndexChecksUseBoundedSQLWork() throws {
        let space=try store.execute("space.create",params:["name":.string("Index regression")])["id"]
        for i in 0..<32 { _=try store.execute("note.create",params:["space_id":space,"title":.string("Note \(i)"),"body":.string("Fictional source")]) }
        while let job=try store.nextSourceIndexJob(modelID:"lexical-native-v1") {
            let published=try store.publishSourceIndex(job:job,documents:store.sourceDocuments(job:job),embeddings:[])
            XCTAssertTrue(published)
        }
        let before=store.db.statementCount
        XCTAssertNil(try store.nextSourceIndexJob(modelID:"lexical-native-v1"))
        XCTAssertEqual(try store.sourceIndexStatus()["lexical"].intValue,32)
        XCTAssertLessThan(store.db.statementCount-before,20,"Idle checks must not query every note/job")
    }
    func testHistoryPageDoesNotMaterializeTheCompleteSession() throws {
        let space=try store.execute("space.create",params:["name":.string("History regression")])["id"]
        let events=(0..<1000).map { i -> JSONValue in .object(["source_id":.string("event-\(i)"),"source_sequence":.number(Double(i)),"timestamp":.string("2026-10-18T10:00:00.000Z"),"role":.string("tool"),"text":.string("Fictional event \(i)")]) }
        let imported=try store.execute("history.import",params:["space_id":space,"source":.string("synthetic_fixture"),"external_id":.string("paged-history"),"events":.array(events)])
        let sid=imported["session_id"] == .null ? imported["id"]:imported["session_id"]
        let before=store.db.returnedRowCount
        let page=try store.execute("read",params:["kind":.string("session"),"id":sid,"offset":.number(300),"limit":.number(100)])
        XCTAssertEqual(page["event_count"].intValue,1000)
        XCTAssertEqual(page["events"].arrayValue.count,100)
        XCTAssertEqual(page["next_offset"].intValue,400)
        XCTAssertLessThan(store.db.returnedRowCount-before,300,"A page must decode bounded events, independently of session length")
    }
    func testPagedHistoryAppliesTypedVisibilityBeforeCountAndOffset() throws {
        let space=try store.execute("space.create",params:["name":.string("Visible")])["id"]
        let profile=try store.execute("profile.create",params:["space_id":space,"name":.string("Scoped")])
        let scope=AccessContext.agent(token:profile["token"].stringValue!)
        let sid="typed-history"
        try store.put("session",.object(["id":.string(sid),"space_id":space,"source":.string("synthetic_fixture"),"deleted":.bool(false)]))
        let variants:[[String:JSONValue]]=[[:],["required_space_ids":.array([space,.null])],["required_space_ids":.array([.string("hidden")])],["required_space_ids":.string("ignored-non-array")],["event_kind":.string("memory_operation")],["integrity_state":.bool(false)],["integrity_state":.string("invalid")]]
        for (i,fields) in variants.enumerated() {
            var e=fields;e["id"] = .string("typed-\(i)");e["session_id"] = .string(sid);e["space_id"]=space;e["kind"] = .string("message");e["source_sequence"] = .number(Double(i));e["timestamp"] = .string("2026-10-18T10:00:00.000Z")
            try store.put("event",.object(e))
        }
        let first=try store.execute("read",params:["kind":.string("session"),"id":.string(sid),"limit":.number(2)],context:scope)
        XCTAssertEqual(first["event_count"].intValue,3)
        XCTAssertEqual(first["events"].arrayValue.map{$0["id"].stringValue!},["typed-0","typed-3"])
        let second=try store.execute("read",params:["kind":.string("session"),"id":.string(sid),"offset":first["next_offset"],"limit":.number(2)],context:scope)
        XCTAssertEqual(second["events"].arrayValue.map{$0["id"].stringValue!},["typed-5"])
        XCTAssertEqual(second["next_offset"],.null)
    }
    func testWorkspaceDeltaDoesNotReloadNotesAndLinksForMCPReads() throws {
        let space=try store.execute("space.create",params:["name":.string("Workspace")])["id"]
        _=try store.execute("note.create",params:["space_id":space,"title":.string("Stable note")])
        let profile=try store.execute("profile.create",params:["space_id":space,"name":.string("Reader")])
        let first=try store.workspaceSnapshot(since:[:])
        XCTAssertEqual(first["notes"].arrayValue.count,1)
        let tokens=first["workspace_tokens"].objectValue.mapValues{$0.stringValue!}
        _=try store.execute("read",params:["kind":.string("spaces")],context:.agent(token:profile["token"].stringValue!))
        let delta=try store.workspaceSnapshot(since:tokens)
        XCTAssertEqual(delta["notes"],.null);XCTAssertEqual(delta["links"],.null);XCTAssertEqual(delta["spaces"],.null)
        XCTAssertEqual(delta["sessions"].arrayValue.count,1)
        XCTAssertEqual(delta["events"].arrayValue.count,2)
        let unchanged=try store.workspaceSnapshot(since:delta["workspace_tokens"].objectValue.mapValues{$0.stringValue!})
        XCTAssertEqual(Set(unchanged.objectValue.keys),["workspace_tokens"])
        _=try store.execute("note.create",params:["space_id":space,"title":.string("Second note")])
        let changed=try store.workspaceSnapshot(since:delta["workspace_tokens"].objectValue.mapValues{$0.stringValue!})
        XCTAssertEqual(changed["notes"].arrayValue.count,2);XCTAssertEqual(changed["sessions"],.null)
    }
    func testSemanticEncodingReleasesStoreLockAndRechecksRevokedAccess() throws {
        let space=try store.execute("space.create",params:["name":.string("Inference")])["id"]
        let note=try store.execute("note.create",params:["space_id":space,"title":.string("Exact evidence"),"body":.string("Fictional proof")])
        let profile=try store.execute("profile.create",params:["space_id":space,"name":.string("Search reader")])
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
        let result=SearchOutcome(),db=store!
        db.configureSemanticSearch(queryEncoder:{ _ in
            entered.signal();_=release.wait(timeout:.now()+2)
            return MioSemanticQuery(modelID:"controlled",values:[1]+[Float](repeating:0,count:767))
        },imageRenderer:{_,_,_ in Data()})
        DispatchQueue.global().async {
            do { _=try db.execute("search",params:["query":.string("proof")],context:.agent(token:profile["token"].stringValue!));result.code="success" }
            catch { result.code=(error as? MioError)?.code ?? "unexpected" }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout:.now()+3),.success)
        let start=ContinuousClock.now
        XCTAssertEqual(try db.execute("read",params:["id":note["id"]])["id"],note["id"])
        XCTAssertLessThan(start.duration(to:.now),.milliseconds(500),"A note read must not wait for inference")
        _=try db.execute("profile.revoke",params:["profile_id":profile["id"]])
        release.signal();XCTAssertEqual(finished.wait(timeout:.now()+3),.success)
        XCTAssertEqual(result.code,"unauthorized","Inference must not retain the old profile grant")
    }
    func testQueueSurvivesRestartWithoutReindexingAndRequeuesChangedExtractor() throws {
        let space=try store.execute("space.create",params:["name":.string("Restart")])["id"]
        _=try store.execute("note.create",params:["space_id":space,"title":.string("Indexed")])
        let job=try XCTUnwrap(store.nextSourceIndexJob(modelID:"lexical-native-v1"))
        XCTAssertTrue(try store.publishSourceIndex(job:job,documents:store.sourceDocuments(job:job)))
        store=nil;store=try MioStore(directory:directory)
        XCTAssertNil(try store.nextSourceIndexJob(modelID:"lexical-native-v1"))
        XCTAssertEqual(try store.sourceIndexStatus()["lexical"].intValue,1)
        try store.db.exec("UPDATE metadata SET value='old-extractor' WHERE key='source_queue_extractor'")
        let fresh=try XCTUnwrap(store.nextSourceIndexJob(modelID:"lexical-native-v1"))
        XCTAssertEqual(fresh["note"]["id"],job["note"]["id"])
        try store.failSourceIndex(job:fresh,error:"Controlled failure")
        XCTAssertNil(try store.nextSourceIndexJob(modelID:"lexical-native-v1"))
        try store.resetSourceIndexErrors()
        XCTAssertNotNil(try store.nextSourceIndexJob(modelID:"lexical-native-v1"))
    }
    func testRecordInventoryKeepsCanonicalHashesAndInvalidatesOnPurge() throws {
        let space=try store.execute("space.create",params:["name":.string("Inventory")])["id"]
        let note=try store.execute("note.create",params:["space_id":space,"title":.string("Fictional evidence"),"body":.string("Fictional content")])
        func hashes(_ method:String) throws -> [String:JSONValue] {
            Dictionary(uniqueKeysWithValues:try store.execute(method)["records"].arrayValue.map{($0["id"].stringValue!,$0["content_hash"])})
        }
        let initial=try hashes("sync.inventory")
        XCTAssertEqual(initial,try hashes("replica.export"))
        let rows=store.db.returnedRowCount
        XCTAssertEqual(initial,try hashes("sync.inventory"))
        XCTAssertLessThan(store.db.returnedRowCount-rows,initial.count+10)
        _=try store.db.transaction { try store.record("note.redact",entityID:note["id"].stringValue!,data:.object(["note_id":note["id"],"session_id":.string("fixture-purge")])) }
        XCTAssertEqual(try hashes("sync.inventory"),try hashes("replica.export"))
        XCTAssertNotEqual(initial,try hashes("sync.inventory"))
        let profile=try store.execute("profile.create",params:["space_id":space,"name":.string("Restricted internal API")])
        for method in ["sync.inventory","sync.status"] { XCTAssertThrowsError(try store.execute(method,context:.agent(token:profile["token"].stringValue!))) }
    }
}

private final class SearchOutcome: @unchecked Sendable { var code="" }
