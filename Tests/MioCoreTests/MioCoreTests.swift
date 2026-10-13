import XCTest
import Foundation
@testable import MioCore

final class MioCoreTests: XCTestCase {
    var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at:root) }; roots = []; super.tearDown() }
    func directory() throws -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("mio-core-test-" + UUID().uuidString); roots.append(u); try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true); return u }
    func store() throws -> MioStore { try MioStore(directory:directory()) }
    func call(_ store: MioStore, _ m: String, _ p: [String:JSONValue] = [:], _ context: AccessContext = .human) throws -> JSONValue { try store.execute(m,params:p,context:context) }
    func space(_ store: MioStore, _ name: String = "Test") throws -> JSONValue { try call(store,"space.create",["name":.string(name)])["id"] }
    func note(_ store: MioStore, _ sid: JSONValue, _ title: String = "Evidence", _ text: String = "source truth") throws -> JSONValue { try call(store,"note.create",["space_id":sid,"title":.string(title),"body":.string(text)]) }
    func history(_ store: MioStore, _ sid: JSONValue, _ text: String = "We chose SQLite because local transactions preserve revisions", external: String = "session-one") throws -> JSONValue {
        try call(store,"history.import",["space_id":sid,"source":.string("codex"),"external_id":.string(external),"title":.string("Decision session"),"completeness":.string("partial"),"events":.array([.object(["source_id":.string("event-one"),"kind":.string("message"),"role":.string("user"),"text":.string(text),"timestamp":.string("2026-10-11T12:00:00.000Z"),"outcome":.string("observed")]),.object(["source_id":.string("tool-one"),"kind":.string("tool_result"),"role":.string("tool"),"text":.string("Build exited 1"),"timestamp":.string("2026-10-11T12:01:00.000Z"),"tool_name":.string("exec_command"),"outcome":.string("failure")])])])
    }
    func testJSONBooleansAndDeterministicBytes() throws {
        let value = try JSONValue(any:["yes":NSNumber(value:true),"one":NSNumber(value:1),"no":NSNull(),"nested":["z":"last","a":"first"]])
        XCTAssertEqual(value["yes"],.bool(true)); XCTAssertEqual(value["one"],.number(1)); XCTAssertEqual(try JSONValue.decode(value.encoded()),value)
        XCTAssertEqual(try value.encoded(),try value.encoded())
    }
    func testBundledSQLitePersistenceReceiptsAndLostReplyRetry() throws {
        let root = try directory(); var first: MioStore? = try MioStore(directory:root)
        XCTAssertEqual(try call(first!,"diagnostics")["sqlite_version"],.string("3.53.4")); XCTAssertTrue(try call(first!,"diagnostics")["fts5"].boolValue)
        let sid = try space(first!)
        let payload: [String:JSONValue] = ["space_id":sid,"title":.string("Crash survivor"),"body":.string("durable bytes"),"idempotency_key":.string("lost-reply")]
        let created = try call(first!,"note.create",payload); XCTAssertEqual(created["receipt"]["status"],.string("local_committed"))
        first = nil
        let second = try MioStore(directory:root), replayed = try call(second,"note.create",payload)
        XCTAssertEqual(created,replayed); XCTAssertEqual(try call(second,"snapshot")["counts"]["notes"].intValue,1)
        XCTAssertEqual(try call(second,"read",["kind":.string("note"),"id":created["id"]])["body"],.string("durable bytes"))
        var changed = payload; changed["body"] = .string("other")
        XCTAssertThrowsError(try call(second,"note.create",changed)) { XCTAssertEqual(($0 as? MioError)?.code,"idempotency_mismatch") }
        XCTAssertEqual(try call(second,"diagnostics")["integrity"],.string("ok"))
    }
    func testStaleDraftIsCommittedThenResolvableAndRestorationCreatesVersion() throws {
        let db = try store(), sid = try space(db), n = try note(db,sid)
        let first = try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("winner")])
        var draftID = JSONValue.null
        XCTAssertThrowsError(try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("preserved draft"),"idempotency_key":.string("stale")])) { e in
            XCTAssertEqual((e as? MioError)?.code,"revision_conflict"); draftID = (e as! MioError).details["revision_id"]; XCTAssertEqual((e as! MioError).details["receipt"]["status"],.string("local_committed"))
        }
        let versions = try call(db,"note.history",["note_id":n["id"]])["revisions"].arrayValue
        XCTAssertEqual(versions.count,3); XCTAssertTrue(versions.contains { $0["body"] == .string("preserved draft") })
        XCTAssertTrue(try call(db,"read",["id":n["id"]])["has_conflict"].boolValue)
        let resolved = try call(db,"note.resolve",["note_id":n["id"],"revision_id":first["revision_id"]])
        XCTAssertFalse(resolved["note"]["has_conflict"].boolValue); XCTAssertEqual(resolved["note"]["body"],.string("winner")); XCTAssertNotEqual(resolved["revision_id"],draftID)
        _ = try call(db,"note.delete",["note_id":n["id"]])
        XCTAssertThrowsError(try call(db,"read",["id":n["id"]]))
        let restored = try call(db,"note.restore",["note_id":n["id"],"revision_id":n["revision_id"]])
        XCTAssertFalse(restored["note"]["deleted"].boolValue); XCTAssertEqual(restored["note"]["body"],.string("source truth")); XCTAssertNotEqual(restored["revision_id"],n["revision_id"])
    }
    func testDirectMountScopeReadWriteAndRevocation() throws {
        let db = try store(), a = try space(db,"A"), b = try space(db,"B"), c = try space(db,"C")
        let na = try note(db,a,"A","common A"), nb = try note(db,b,"Secret B","common B"), nc = try note(db,c,"Secret C","common C")
        _ = try history(db,c,"common hidden history",external:"hidden")
        let profile = try call(db,"profile.create",["space_id":a,"name":.string("agent")]), context = AccessContext.agent(token:profile["token"].stringValue!)
        XCTAssertEqual(try call(db,"search",["query":.string("common"),"scope":.string("notes")],context)["results"].arrayValue.count,1)
        XCTAssertThrowsError(try call(db,"read",["id":nb["id"]],context))
        _ = try call(db,"connection.create",["from_space_id":b,"to_space_id":c,"access":.string("write")])
        let mount = try call(db,"connection.create",["from_space_id":a,"to_space_id":b,"access":.string("read")])
        XCTAssertEqual(try call(db,"search",["query":.string("common"),"scope":.string("notes")],context)["results"].arrayValue.count,2)
        XCTAssertThrowsError(try call(db,"read",["id":nc["id"]],context)); XCTAssertThrowsError(try call(db,"note.create",["space_id":b,"title":.string("forbidden")],context))
        _ = try call(db,"link.create",["from_note_id":na["id"],"to_note_id":nb["id"]],context)
        XCTAssertThrowsError(try call(db,"link.create",["from_note_id":nb["id"],"to_note_id":na["id"]],context))
        _ = try call(db,"connection.delete",["connection_id":mount["id"]])
        XCTAssertThrowsError(try call(db,"read",["id":nb["id"]],context)); XCTAssertEqual(try call(db,"snapshot",[:],context)["links"].arrayValue.count,0)
        _ = try call(db,"connection.create",["from_space_id":a,"to_space_id":b,"access":.string("write")])
        _ = try call(db,"note.update",["note_id":nb["id"],"expected_revision":nb["revision_id"],"body":.string("authorized B")],context)
        XCTAssertThrowsError(try call(db,"profile.create",["space_id":a,"name":.string("bypass")],context))
        _ = try call(db,"profile.revoke",["profile_id":profile["id"]]); XCTAssertThrowsError(try call(db,"search",["query":.string("common"),"scope":.string("notes")],context))
    }
    func testHistoryRepeatChangedSourceRollsBackAndOutcomeReadable() throws {
        let db = try store(), sid = try space(db), first = try history(db,sid)
        let before = try call(db,"sync.pending")["count"]
        XCTAssertEqual(try history(db,sid)["imported"].intValue,0)
        XCTAssertEqual(try call(db,"sync.pending")["count"],before)
        XCTAssertThrowsError(try history(db,sid,"Changed source")) { XCTAssertEqual(($0 as? MioError)?.code,"source_conflict") }
        let session = try call(db,"read",["kind":.string("session"),"id":first["session_id"]])
        XCTAssertEqual(session["events"].arrayValue.count,2); XCTAssertEqual(session["completeness"],.string("partial"))
        XCTAssertTrue(session["events"].arrayValue.contains { $0["tool_name"] == .string("exec_command") && $0["outcome"] == .string("failure") })
        let found = try call(db,"search",["query":.string("SQLite transactions"),"scope":.string("history"),"include_legacy_history":.bool(true)])["results"].arrayValue
        XCTAssertEqual(found.count,1); XCTAssertEqual(found.first?["session_id"] ?? .null,first["session_id"]); XCTAssertEqual(found.first?["completeness"] ?? .null,.string("partial"))
        XCTAssertEqual(try call(db,"search",["query":.string("nonexistentword")])["results"].arrayValue.count,0)
    }
    func testSearchTemporalBudgetAndPrimaryEvidenceDedup() throws {
        let db = try store(), sid = try space(db), n = try note(db,sid,"Transport decision","SQLite old decision")
        let before = try call(db,"read",["id":n["id"]])["timestamp"]
        Thread.sleep(forTimeInterval:0.01)
        _ = try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("CloudKit current decision")])
        XCTAssertEqual(try call(db,"search",["query":.string("SQLite"),"scope":.string("notes")])["results"].arrayValue.count,0)
        XCTAssertEqual(try call(db,"search",["query":.string("SQLite"),"scope":.string("notes"),"as_of":before])["results"].arrayValue.first?["revision_id"],n["revision_id"])
        let small = try call(db,"search",["query":.string("decision"),"max_chars":.number(5)])
        XCTAssertLessThanOrEqual(small["returned_chars"].intValue,5)
        var events: [JSONValue] = [.object(["source_id":.string("primary"),"role":.string("tool"),"text":.string("factual primary evidence"),"outcome":.string("observed")])]
        for i in 0..<10 { events.append(.object(["source_id":.string("repeat\(i)"),"role":.string("assistant"),"text":.string("repeated factual evidence"),"outcome":.string("reported")])) }
        _ = try call(db,"history.import",["space_id":sid,"external_id":.string("repeats"),"events":.array(events)])
        let results = try call(db,"search",["query":.string("factual evidence"),"scope":.string("history"),"include_legacy_history":.bool(true)])["results"].arrayValue
        XCTAssertEqual(results.count,2); XCTAssertEqual(results.first?["role"],.string("tool"))
    }
    func testArchiveReplicaConflictAndDeletionSafeMerge() throws {
        let one = try store(), sid = try space(one), n = try note(one,sid)
        let old = try call(one,"replica.export")
        let two = try store(); _ = try call(two,"replica.merge",["document":old])
        _ = try call(one,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("left branch")])
        _ = try call(two,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("right branch")])
        _ = try call(one,"replica.merge",["document":try call(two,"replica.export")])
        XCTAssertTrue(try call(one,"read",["id":n["id"]])["has_conflict"].boolValue)
        _ = try call(one,"note.delete",["note_id":n["id"]]); _ = try call(one,"replica.merge",["document":old])
        XCTAssertThrowsError(try call(one,"read",["id":n["id"]]))
        let archive = try directory().appendingPathComponent("backup.mio")
        _ = try call(one,"archive.export",["path":.string(archive.path)])
        let empty = try store(); _ = try call(empty,"archive.import",["path":.string(archive.path),"mode":.string("restore")])
        XCTAssertEqual(try call(one,"snapshot")["notes"],try call(empty,"snapshot")["notes"])
        XCTAssertEqual(try call(empty,"archive.import",["path":.string(archive.path)])["imported_records"].intValue,0)
        var corrupt = try JSONValue.decode(Data(contentsOf:archive)).objectValue; corrupt["manifest"] = .object(["sha256":.string("broken")]); try JSONValue.object(corrupt).encoded().write(to:archive)
        let count = try call(empty,"snapshot")["counts"]
        XCTAssertThrowsError(try call(empty,"archive.import",["path":.string(archive.path)])); XCTAssertEqual(try call(empty,"snapshot")["counts"],count)
    }
    func testPurgeRedactsSourceDerivedNotesReceiptsAndLateAck() throws {
        let db = try store(), sid = try space(db), h = try history(db,sid,"sensitive UNIQUE_PURGE_PAYLOAD")
        let e = try call(db,"read",["kind":.string("session"),"id":h["session_id"]])["events"].arrayValue.first { $0["source_id"] == .string("event-one") }!
        let n = try call(db,"note.create",["space_id":sid,"title":.string("Derived"),"body":.string("sensitive UNIQUE_PURGE_PAYLOAD"),"source_ids":.array([e["id"]]),"idempotency_key":.string("derived")])
        let old = try call(db,"replica.export"), oldPending = try call(db,"sync.pending")
        _ = try call(db,"history.purge",["session_id":h["session_id"]])
        XCTAssertEqual(try call(db,"search",["query":.string("UNIQUE_PURGE_PAYLOAD")])["results"].arrayValue.count,0)
        XCTAssertFalse(String(decoding:try call(db,"replica.export").encoded(),as:UTF8.self).contains("UNIQUE_PURGE_PAYLOAD"))
        XCTAssertFalse(String(decoding:try call(db,"note.history",["note_id":n["id"]]).encoded(),as:UTF8.self).contains("UNIQUE_PURGE_PAYLOAD"))
        let ack = try call(db,"sync.ack",["records":oldPending["records"]]); XCTAssertGreaterThan(ack["rejected"].intValue,0)
        _ = try call(db,"replica.merge",["document":old]); XCTAssertFalse(String(decoding:try call(db,"replica.export").encoded(),as:UTF8.self).contains("UNIQUE_PURGE_PAYLOAD"))
        XCTAssertThrowsError(try history(db,sid,"sensitive UNIQUE_PURGE_PAYLOAD")) { XCTAssertEqual(($0 as? MioError)?.code,"source_purged") }
        let peer = try store(); _ = try call(peer,"replica.merge",["document":old]); _ = try call(peer,"replica.merge",["document":try call(db,"replica.export")]); _ = try call(peer,"replica.merge",["document":old])
        XCTAssertFalse(String(decoding:try call(peer,"replica.export").encoded(),as:UTF8.self).contains("UNIQUE_PURGE_PAYLOAD"))
        let receiptText = try db.db.rows("SELECT json FROM idempotency").map { $0["json"]! }.joined()
        XCTAssertFalse(receiptText.contains("UNIQUE_PURGE_PAYLOAD"))
        let restore = try call(db,"history.restore",["space_id":sid,"external_id":.string("session-one"),"source":.string("codex"),"events":.array([.object(["source_id":.string("event-one"),"text":.string("explicit restored bytes"),"role":.string("user")])])])
        XCTAssertEqual(restore["imported"].intValue,1); XCTAssertEqual(try call(db,"search",["query":.string("restored bytes"),"include_legacy_history":.bool(true)])["results"].arrayValue.count,1)
        _ = try call(db,"replica.merge",["document":old]); XCTAssertFalse(String(decoding:try call(db,"replica.export").encoded(),as:UTF8.self).contains("UNIQUE_PURGE_PAYLOAD"))
    }
    func testMarkdownRealVaultAttachmentsAmbiguityAndFullArchive() throws {
        let db = try store(), sid = try space(db), vault = try directory()
        try Data("# Start\n[[Target]]\n[[Missing]]\n![[image.png]]".utf8).write(to:vault.appendingPathComponent("Start.md"))
        try Data("Target body".utf8).write(to:vault.appendingPathComponent("Target.md")); let image = Data([0x89,0x50,0x4e,0x47]); try image.write(to:vault.appendingPathComponent("image.png"))
        let imported = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        XCTAssertEqual(try db.all("attachment").first?["relative_path"],.string("image.png")); XCTAssertEqual(imported["imported_notes"].intValue,2); XCTAssertEqual(imported["imported_attachments"].intValue,1); XCTAssertTrue(imported["warnings"].arrayValue.contains { $0["reason"] == .string("missing_target") })
        XCTAssertEqual(try call(db,"snapshot")["links"].arrayValue.count,1)
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid]); XCTAssertEqual(try call(db,"snapshot")["counts"]["notes"].intValue,2)
        let export = try directory(); _ = try call(db,"markdown.export",["path":.string(export.path)])
        XCTAssertEqual(try Data(contentsOf:export.appendingPathComponent(sid.stringValue!).appendingPathComponent("image.png")),image)
        let archive = try directory().appendingPathComponent("full.mio"); _ = try call(db,"archive.export",["path":.string(archive.path)])
        let peer = try store(); _ = try call(peer,"archive.import",["path":.string(archive.path),"mode":.string("restore")])
        let exportedPeer = try directory(); _ = try call(peer,"markdown.export",["path":.string(exportedPeer.path)])
        XCTAssertEqual(try Data(contentsOf:exportedPeer.appendingPathComponent(sid.stringValue!).appendingPathComponent("image.png")),image)
        XCTAssertEqual(try String(contentsOf:vault.appendingPathComponent("Target.md"),encoding:.utf8),"Target body")
    }
}

extension MioCoreTests {
    func testSparseReplicaDoesNotExposeMissingAncestryAndEventuallyConverges() throws {
        let source = try store(), sid = try space(source), n = try note(source,sid)
        let changed = try call(source,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("dependent final bytes")])
        let full = try call(source,"replica.export"), records = full["records"].arrayValue
        let child = records.first { $0["entity_id"] == changed["revision_id"] }!
        let empty = try store()
        let sparse: JSONValue = .object(["format":.string("mio-records"),"schema_version":.number(1),"records":.array([child])])
        _ = try call(empty,"replica.merge",["document":sparse])
        XCTAssertEqual(try call(empty,"snapshot")["counts"]["notes"].intValue,0)
        _ = try call(empty,"replica.merge",["document":full])
        XCTAssertEqual(try call(empty,"read",["id":n["id"]])["body"],.string("dependent final bytes")); XCTAssertFalse(try call(empty,"read",["id":n["id"]])["has_conflict"].boolValue)
        let peek = try call(empty,"replica.record",["id":child["id"]]); XCTAssertEqual(peek["content_hash"],child["content_hash"])
    }
    func testSameTimestampSourceSequenceAndFailureAudit() throws {
        let db = try store(), sid = try space(db)
        let imported = try call(db,"history.import",["space_id":sid,"external_id":.string("ordering"),"events":.array([.object(["source_id":.string("z-user"),"source_sequence":.number(0),"text":.string("request"),"role":.string("user"),"timestamp":.string("2026-10-11T12:00:00Z")]),.object(["source_id":.string("a-tool"),"source_sequence":.number(1),"text":.string("result"),"role":.string("tool"),"timestamp":.string("2026-10-11T12:00:00Z")])])])
        let events = try call(db,"read",["kind":.string("session"),"id":imported["id"]])["events"].arrayValue
        XCTAssertEqual(events.map { $0["text"] },[.string("request"),.string("result")])
        XCTAssertThrowsError(try call(db,"read",["id":.string("absent")]))
        XCTAssertTrue(try call(db,"snapshot")["audit"].arrayValue.contains { $0["outcome"] == .string("error") && $0["error_code"] == .string("not_found") })
    }
    func testTwoConnectionsSerializeCommitsAndKeepActualBoundedSnapshotCounts() throws {
        let directory = try directory(), one = try MioStore(directory:directory), two = try MioStore(directory:directory), sid = try space(one)
        let group = DispatchGroup(), queue = DispatchQueue(label:"mio.test.concurrent",attributes:.concurrent), errors = LockedErrors()
        for i in 0..<40 { group.enter(); queue.async { defer { group.leave() }; do { _ = try (i % 2 == 0 ? one : two).execute("note.create",params:["space_id":sid,"title":.string("Parallel \(i)"),"body":.string("persisted \(i)")]) } catch { errors.append(error) } } }
        group.wait(); XCTAssertTrue(errors.values.isEmpty); XCTAssertEqual(try call(one,"snapshot")["counts"]["notes"].intValue,40)
        var events: [JSONValue] = []
        for i in 0..<220 { events.append(.object(["source_id":.string("e\(i)"),"text":.string("bounded event \(i)"),"source_sequence":.number(Double(i))])) }
        _ = try call(one,"history.import",["space_id":sid,"external_id":.string("bounded"),"events":.array(events)])
        let snapshot = try call(one,"snapshot"); XCTAssertEqual(snapshot["events"].arrayValue.count,200); XCTAssertEqual(snapshot["counts"]["events"].intValue,220)
        XCTAssertEqual(try call(one,"diagnostics")["integrity"],.string("ok"))
    }
}
private final class LockedErrors: @unchecked Sendable {
    let lock = NSLock(); var storage: [Error] = []
    func append(_ e: Error) { lock.lock(); storage.append(e); lock.unlock() }
    var values: [Error] { lock.lock(); defer { lock.unlock() }; return storage }
}

extension MioCoreTests {
    func testDuplicateStableSourceInOneBatchRejectedAtomically() throws {
        let db = try store(), sid = try space(db), before = try call(db,"replica.export")["records"].arrayValue.count
        XCTAssertThrowsError(try call(db,"history.import",["space_id":sid,"external_id":.string("duplicate"),"events":.array([.object(["source_id":.string("same"),"text":.string("original evidence"),"role":.string("tool")]),.object(["source_id":.string("same"),"text":.string("changed evidence"),"role":.string("tool")])])])) { XCTAssertEqual(($0 as? MioError)?.code,"source_conflict") }
        XCTAssertEqual(try call(db,"replica.export")["records"].arrayValue.count,before); XCTAssertEqual(try call(db,"snapshot")["counts"]["events"].intValue,0)
    }
    func testCrossSpaceRevisionRejectedBeforeProjectionAndRevisionReadAuthorized() throws {
        let db = try store(), a = try space(db,"Allowed"), b = try space(db,"Hidden"), hidden = try note(db,b,"Hidden","PRIVATE_HIDDEN_REVISION"), allowed = try note(db,a,"Public","public bytes")
        let records = try call(db,"replica.export")["records"].arrayValue
        var forged = records.first { $0["entity_id"] == allowed["revision_id"] }!.objectValue, d = forged["data"]!.objectValue
        forged.removeValue(forKey:"content_hash"); forged["id"] = .string(UUID().uuidString.lowercased()); forged["entity_id"] = .string(UUID().uuidString.lowercased()); d["id"] = forged["entity_id"]; d["note_id"] = hidden["id"]; d["timestamp"] = .string("2099-01-01T00:00:00Z"); forged["timestamp"] = d["timestamp"]; forged["data"] = .object(d)
        forged["content_hash"] = .string(db.hash(try JSONValue.object(forged).encoded()))
        let doc: JSONValue = .object(["schema_version":.number(1),"format":.string("mio-records"),"records":.array([.object(forged)])])
        XCTAssertThrowsError(try call(db,"replica.merge",["document":doc]))
        XCTAssertEqual(try call(db,"read",["id":hidden["id"]])["space_id"],b)
        let profile = try call(db,"profile.create",["space_id":a,"name":.string("public")]), context = AccessContext.agent(token:profile["token"].stringValue!)
        XCTAssertThrowsError(try call(db,"note.history",["note_id":hidden["id"]],context)); XCTAssertThrowsError(try call(db,"read",["id":hidden["id"],"revision_id":hidden["revision_id"]],context))
    }
    func testExactHashRestagingQueueRejectsStaleBytes() throws {
        let db = try store(), sid = try space(db), n = try note(db,sid)
        let pending = try call(db,"sync.pending")["records"]
        _ = try call(db,"sync.ack",["records":pending]); XCTAssertEqual(try call(db,"sync.pending")["count"].intValue,0)
        let queued = try call(db,"sync.queue",["records":pending]); XCTAssertEqual(queued["queued"].intValue,pending.arrayValue.count)
        XCTAssertEqual(try call(db,"sync.pending")["count"].intValue,pending.arrayValue.count)
        var wrong = pending.arrayValue.first!.objectValue; wrong["content_hash"] = .string("stale")
        XCTAssertEqual(try call(db,"sync.queue",["records":.array([.object(wrong)])])["rejected"].intValue,1)
        XCTAssertEqual(try call(db,"read",["id":n["id"]])["body"],.string("source truth"))
    }
    func testLocalWikilinksRespectDirectMountsAmbiguityAndManualLinks() throws {
        let db = try store(), a = try space(db,"A"), b = try space(db,"B"), c = try space(db,"C")
        let target = try note(db,a,"Local target","target"), mounted = try note(db,b,"Mounted target","mounted"), hidden = try note(db,c,"Hidden target","secret")
        _ = try call(db,"connection.create",["from_space_id":b,"to_space_id":c,"access":.string("read")])
        _ = try call(db,"connection.create",["from_space_id":a,"to_space_id":b,"access":.string("read")])
        let created = try note(db,a,"Origin","[[Local target]] [[Mounted target|alias]] [[Hidden target]] [[Missing]]")
        let links = try call(db,"snapshot")["links"].arrayValue.filter { !$0["deleted"].boolValue && $0["from_note_id"] == created["id"] }
        XCTAssertEqual(Set(links.compactMap { $0["to_note_id"].stringValue }),Set([target["id"].stringValue!,mounted["id"].stringValue!])); XCTAssertFalse(links.contains { $0["to_note_id"] == hidden["id"] })
        XCTAssertTrue(created["link_warnings"].arrayValue.contains { $0["target"] == .string("Hidden target") && $0["reason"] == .string("missing_target") })
        _ = try call(db,"link.create",["from_note_id":created["id"],"to_note_id":target["id"],"kind":.string("related")])
        _ = try call(db,"note.update",["note_id":created["id"],"expected_revision":created["revision_id"],"body":.string("no links")])
        let remaining = try call(db,"snapshot")["links"].arrayValue.filter { !$0["deleted"].boolValue && $0["from_note_id"] == created["id"] }
        XCTAssertEqual(remaining.map { $0["to_note_id"] },[target["id"]])
        _ = try note(db,a,"Duplicate","first"); _ = try note(db,a,"Duplicate","second")
        let ambiguous = try note(db,a,"Ambiguous origin","[[Duplicate]]")
        XCTAssertTrue(ambiguous["link_warnings"].arrayValue.contains { $0["reason"] == .string("ambiguous_target") })
        XCTAssertFalse(try call(db,"snapshot")["links"].arrayValue.contains { !$0["deleted"].boolValue && $0["from_note_id"] == ambiguous["id"] })
    }
}

extension MioCoreTests {
    func testMarkdownCollisionsPreserveBothBodiesAndRefreshRemovesDerivedLinks() throws {
        let db = try store(), sid = try space(db), base = try directory()
        for (name,text) in [("one","FIRST_DISTINCT_EXPORT_BODY"),("two","SECOND_DISTINCT_EXPORT_BODY")] { let folder = base.appendingPathComponent(name); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try Data(text.utf8).write(to:folder.appendingPathComponent("Same.md")); _ = try call(db,"markdown.import",["space_id":sid,"path":.string(folder.path)]) }
        let exported = base.appendingPathComponent("export"); _ = try call(db,"markdown.export",["path":.string(exported.path)])
        let files = FileManager.default.enumerator(at:exported,includingPropertiesForKeys:nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count,2); let content = try files.map { try String(contentsOf:$0,encoding:.utf8) }.joined()
        XCTAssertTrue(content.contains("FIRST_DISTINCT_EXPORT_BODY")); XCTAssertTrue(content.contains("SECOND_DISTINCT_EXPORT_BODY"))
        let vault = base.appendingPathComponent("links"); try FileManager.default.createDirectory(at:vault,withIntermediateDirectories:true)
        try Data("[[Target]]".utf8).write(to:vault.appendingPathComponent("Start.md")); try Data("Target body".utf8).write(to:vault.appendingPathComponent("Target.md"))
        _ = try call(db,"markdown.import",["space_id":sid,"path":.string(vault.path)]); XCTAssertEqual(try call(db,"snapshot")["links"].arrayValue.filter { !$0["deleted"].boolValue }.count,1)
        try Data("no target links".utf8).write(to:vault.appendingPathComponent("Start.md")); _ = try call(db,"markdown.import",["space_id":sid,"path":.string(vault.path)])
        XCTAssertEqual(try call(db,"snapshot")["links"].arrayValue.filter { !$0["deleted"].boolValue }.count,0)
    }
    func testPurgeRemovesSessionTitleAndPathAcrossReplay() throws {
        let db = try store(), sid = try space(db), secret = "UNIQUE_PURGED_SESSION_TITLE"
        let imported = try call(db,"history.import",["space_id":sid,"external_id":.string("title-purge"),"title":.string(secret),"source_path":.string("/selected/" + secret),"events":.array([.object(["source_id":.string("e"),"text":.string("source body")])])])
        let old = try call(db,"replica.export"); _ = try call(db,"history.purge",["session_id":imported["id"]])
        XCTAssertFalse(String(decoding:try call(db,"snapshot").encoded(),as:UTF8.self).contains(secret)); XCTAssertFalse(String(decoding:try call(db,"replica.export").encoded(),as:UTF8.self).contains(secret))
        _ = try call(db,"replica.merge",["document":old]); XCTAssertFalse(String(decoding:try call(db,"replica.export").encoded(),as:UTF8.self).contains(secret))
    }
    func testEventMustBelongToSessionSpaceBeforeMerge() throws {
        let db = try store(), a = try space(db,"Allowed"), b = try space(db,"Hidden"), open = try call(db,"history.import",["space_id":a,"external_id":.string("open"),"events":.array([])])
        _ = try history(db,b,"PRIVATE_COUNT_SOURCE")
        var r = try call(db,"replica.export")["records"].arrayValue.first { $0["kind"] == .string("event") }!.objectValue; r.removeValue(forKey:"content_hash"); var d = r["data"]!.objectValue
        r["id"] = .string(UUID().uuidString.lowercased()); r["entity_id"] = .string(UUID().uuidString.lowercased()); d["id"] = r["entity_id"]; d["session_id"] = open["id"]; r["data"] = .object(d); r["content_hash"] = .string(db.hash(try JSONValue.object(r).encoded()))
        XCTAssertThrowsError(try call(db,"replica.merge",["document":.object(["format":.string("mio-records"),"schema_version":.number(1),"records":.array([.object(r)])])]))
        XCTAssertEqual(try call(db,"read",["kind":.string("session"),"id":open["id"]])["event_count"].intValue,0)
    }
}

extension MioCoreTests {
    func testImmutableEntityPayloadCannotBeReplacedThroughNewTransportRecordID() throws {
        let db = try store(), sid = try space(db), n = try note(db,sid,"Immutable","ORIGINAL_REVISION_BYTES")
        let history = try history(db,sid,"ORIGINAL_EVENT_BYTES")
        let records = try call(db,"replica.export")["records"].arrayValue
        for kind in ["revision","event"] {
            var r = records.first { $0["kind"] == .string(kind) && (kind == "event" || $0["entity_id"] == n["revision_id"]) }!.objectValue; r.removeValue(forKey:"content_hash"); r["id"] = .string(UUID().uuidString.lowercased()); var d = r["data"]!.objectValue; d[kind == "revision" ? "body" : "text"] = .string("REPLACED_IMMUTABLE_BYTES"); r["data"] = .object(d); r["content_hash"] = .string(db.hash(try JSONValue.object(r).encoded()))
            XCTAssertThrowsError(try call(db,"replica.merge",["document":.object(["format":.string("mio-records"),"schema_version":.number(1),"records":.array([.object(r)])])]))
        }
        XCTAssertEqual(try call(db,"read",["id":n["id"],"revision_id":n["revision_id"]])["body"],.string("ORIGINAL_REVISION_BYTES"))
        XCTAssertTrue(try call(db,"read",["kind":.string("session"),"id":history["id"]])["events"].arrayValue.contains { $0["text"] == .string("ORIGINAL_EVENT_BYTES") })
    }
}

extension MioCoreTests {
    func testDifferentVaultAttachmentsAndEmbedsSurviveExportAndArchive() throws {
        let db = try store(), sid = try space(db), base = try directory(), first = Data([0x89,0x50,0x4e,0x47,1]), second = Data([0x89,0x50,0x4e,0x47,2])
        for (folder,bytes,label) in [("one",first,"ONE_SOURCE"),("two",second,"TWO_SOURCE")] {
            let root = base.appendingPathComponent(folder); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try Data((label + "\n![[image.png]]\n![Standard](image.png)").utf8).write(to:root.appendingPathComponent("Same.md")); try bytes.write(to:root.appendingPathComponent("image.png"))
            _ = try call(db,"markdown.import",["space_id":sid,"path":.string(root.path)])
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("image.png")),bytes)
        }
        XCTAssertEqual(try db.all("attachment").count,2)
        func checkExport(_ store: MioStore, _ destination: URL) throws {
            _ = try call(store,"markdown.export",["path":.string(destination.path)])
            let files = FileManager.default.enumerator(at:destination,includingPropertiesForKeys:nil)!.compactMap { $0 as? URL }
            let pngs = try files.filter { $0.pathExtension == "png" }.map { try Data(contentsOf:$0) }; XCTAssertTrue(pngs.contains(first)); XCTAssertTrue(pngs.contains(second))
            for file in files where file.pathExtension == "md" {
                let text = try String(contentsOf:file,encoding:.utf8), expected = text.contains("ONE_SOURCE") ? first : second
                let regex = try NSRegularExpression(pattern:"!\\[\\[([^\\]]+)\\]\\]"); let ns = text as NSString
                let match = try XCTUnwrap(regex.firstMatch(in:text,range:NSRange(location:0,length:ns.length)))
                XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent(ns.substring(with:match.range(at:1)))),expected)
                let standard = try NSRegularExpression(pattern:"!\\[Standard\\]\\(([^)]+)\\)")
                let standardMatch = try XCTUnwrap(standard.firstMatch(in:text,range:NSRange(location:0,length:ns.length)))
                XCTAssertEqual(try Data(contentsOf:file.deletingLastPathComponent().appendingPathComponent(ns.substring(with:standardMatch.range(at:1)))),expected)
            }
        }
        try checkExport(db,base.appendingPathComponent("export"))
        let backup = base.appendingPathComponent("archive.mio"); _ = try call(db,"archive.export",["path":.string(backup.path)])
        let peer = try store(); _ = try call(peer,"archive.import",["path":.string(backup.path),"mode":.string("restore")]); try checkExport(peer,base.appendingPathComponent("restored"))
    }
}

extension MioCoreTests {
    func testUpdateOfPurgedDerivedNoteRejectsDiscardedDraft() throws {
        let db = try store(), sid = try space(db), h = try history(db,sid,"erased source"), event = try call(db,"read",["kind":.string("session"),"id":h["id"]])["events"].arrayValue.first!
        let n = try call(db,"note.create",["space_id":sid,"title":.string("Derived"),"body":.string("erased source"),"source_ids":.array([event["id"]])])
        _ = try call(db,"history.purge",["session_id":h["id"]])
        let current = try call(db,"read",["id":n["id"]])
        XCTAssertThrowsError(try call(db,"note.update",["note_id":n["id"],"expected_revision":current["revision_id"],"body":.string("new user draft")])) { XCTAssertEqual(($0 as? MioError)?.code,"source_purged") }
        XCTAssertEqual(try call(db,"read",["id":n["id"]])["body"],.string(""))
    }
}

extension MioCoreTests {
    func testDerivedSearchRowMappingMigrationReplacementPurgeAndRebuild() throws {
        let root = try directory(); var db: MioStore? = try MioStore(directory:root); let sid = try space(db!), n = try note(db!,sid,"Indexed replacement","previousuniqueterm")
        _ = try call(db!,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("currentuniqueterm")])
        let history = try history(db!,sid,"sourceuniqueterm")
        XCTAssertEqual(try call(db!,"search",["query":.string("previousuniqueterm")])["results"].arrayValue.count,0)
        XCTAssertEqual(try call(db!,"search",["query":.string("currentuniqueterm")])["results"].arrayValue.count,1)
        // Simulate a real pre-mapping database: persisted entities and FTS remain,
        // but the derived mapping and its migration marker are absent.
        try db!.db.exec("DROP TABLE search_documents")
        try db!.db.exec("DELETE FROM metadata WHERE key='search_document_index_version'")
        db = nil; let reopened = try MioStore(directory:root)
        XCTAssertEqual(try call(reopened,"search",["query":.string("currentuniqueterm")])["results"].arrayValue.count,1)
        _ = try call(reopened,"history.purge",["session_id":history["id"]])
        XCTAssertEqual(try call(reopened,"search",["query":.string("sourceuniqueterm")])["results"].arrayValue.count,0)
        _ = try call(reopened,"note.delete",["note_id":n["id"]])
        _ = try call(reopened,"search.rebuild")
        XCTAssertEqual(try call(reopened,"search",["query":.string("currentuniqueterm")])["results"].arrayValue.count,0)
        _ = try call(reopened,"note.restore",["note_id":n["id"],"revision_id":n["revision_id"]])
        _ = try call(reopened,"search.rebuild")
        XCTAssertEqual(try call(reopened,"search",["query":.string("previousuniqueterm")])["results"].arrayValue.count,1)
        XCTAssertEqual(try call(reopened,"search",["query":.string("sourceuniqueterm")])["results"].arrayValue.count,0)
        let documents = try reopened.db.rows("SELECT count(*) AS n FROM search_documents").first?["n"]
        XCTAssertEqual(documents,"1")
    }
}

extension MioCoreTests {
    func testCompactSnapshotMetadataPreviewsScopeAndFullReads() throws {
        let db = try store(), a = try space(db,"Allowed"), b = try space(db,"Hidden"), body = String(repeating:"body-character ",count:1000)
        let n = try note(db,a,"Compact note",body); _ = try note(db,b,"Private compact title","PRIVATE_COMPACT_BODY")
        let h = try history(db,a,String(repeating:"event-character ",count:1000)); _ = try history(db,b,"PRIVATE_COMPACT_EVENT",external:"private")
        let profile = try call(db,"profile.create",["space_id":a,"name":.string("public")]), context = AccessContext.agent(token:profile["token"].stringValue!)
        let compact = try call(db,"snapshot",["projection":.string("compact")],context)
        XCTAssertEqual(compact["projection"],.string("compact")); XCTAssertTrue(compact["bodies_omitted"].boolValue); XCTAssertEqual(compact["counts"]["notes"].intValue,1)
        let meta = try XCTUnwrap(compact["notes"].arrayValue.first)
        XCTAssertEqual(meta["id"],n["id"]); XCTAssertEqual(meta["revision_id"],n["revision_id"]); XCTAssertEqual(meta["body"],.null); XCTAssertEqual(meta["source_ids"],.null); XCTAssertTrue(meta["body_omitted"].boolValue); XCTAssertLessThanOrEqual((meta["body_preview"].stringValue?.count ?? 999),120)
        XCTAssertEqual(try call(db,"read",["id":n["id"]],context)["body"],.string(body))
        let events = compact["events"].arrayValue
        XCTAssertEqual(events.count,2); XCTAssertTrue(events.allSatisfy { $0["text"] == .null && $0["text_omitted"].boolValue && ($0["text_preview"].stringValue?.count ?? 999) <= 240 })
        XCTAssertFalse(String(decoding:try compact.encoded(),as:UTF8.self).contains("PRIVATE_COMPACT"))
        XCTAssertEqual(try call(db,"read",["kind":.string("session"),"id":h["id"]],context)["events"].arrayValue.first?["text"],.string(String(repeating:"event-character ",count:1000)))
        XCTAssertEqual(try call(db,"snapshot")["notes"].arrayValue.first { $0["id"] == n["id"] }?["body"],.string(body))
        let source = try call(db,"read",["kind":.string("session"),"id":h["id"]])["events"].arrayValue.first!["id"]
        let derived = try call(db,"note.create",["space_id":a,"title":.string("Derived preview"),"body":.string("cleared-source-preview"),"source_ids":.array([source])])
        _ = try call(db,"history.purge",["session_id":h["id"]])
        let purged = try call(db,"snapshot",["projection":.string("compact")])["notes"].arrayValue.first { $0["id"] == derived["id"] }!
        XCTAssertTrue(purged["purged"].boolValue); XCTAssertEqual(purged["status"],.string("purged")); XCTAssertEqual(purged["body_preview"],.string("")); XCTAssertTrue(purged["body_omitted"].boolValue)
    }
}

extension MioCoreTests {
    func testChangeTokenStableSnapshotsAndTracksOwnAuditQueueAndExternalCommits() throws {
        let root = try directory(), one = try MioStore(directory:root), sid = try space(one), two = try MioStore(directory:root)
        let before = try one.currentChangeToken()
        _ = try call(one,"snapshot"); _ = try call(one,"snapshot",["projection":.string("compact")])
        XCTAssertEqual(try one.currentChangeToken(),before)
        let n = try note(one,sid,"Token note","own commit")
        let afterOwn = try one.currentChangeToken(); XCTAssertNotEqual(afterOwn,before)
        _ = try call(one,"read",["id":n["id"]]); let afterAudit = try one.currentChangeToken(); XCTAssertNotEqual(afterAudit,afterOwn)
        let pending = try call(one,"sync.pending")["records"]; XCTAssertEqual(try one.currentChangeToken(),afterAudit)
        _ = try call(one,"sync.ack",["records":pending]); let afterQueue = try one.currentChangeToken(); XCTAssertNotEqual(afterQueue,afterAudit)
        _ = try note(two,sid,"External commit","second connection")
        XCTAssertNotEqual(try one.currentChangeToken(),afterQueue)
        XCTAssertEqual(try call(one,"snapshot",["projection":.string("compact")])["counts"]["notes"].intValue,2)
    }
}

extension MioCoreTests {
    func testReadSourceResolvesNotesRevisionsEventsURLsAndAuthorizesEach() throws {
        let db = try store(), a = try space(db,"Allowed"), b = try space(db,"Hidden"), source = try note(db,a,"Source note","original revision source"), hidden = try note(db,b,"Private source","PRIVATE_RESOLVED_SOURCE")
        _ = try call(db,"note.update",["note_id":source["id"],"expected_revision":source["revision_id"],"body":.string("current note source")])
        let h = try history(db,a,"exact event source"), event = try call(db,"read",["kind":.string("session"),"id":h["id"]])["events"].arrayValue.first!
        let profile = try call(db,"profile.create",["space_id":a,"name":.string("Source reader")]), context = AccessContext.agent(token:profile["token"].stringValue!)
        let note = try call(db,"read",["kind":.string("source"),"id":source["id"]],context)
        XCTAssertEqual(note["kind"],.string("note")); XCTAssertEqual(note["body"],.string("current note source"))
        let revision = try call(db,"read",["kind":.string("source"),"id":source["revision_id"]],context)
        XCTAssertEqual(revision["kind"],.string("revision")); XCTAssertEqual(revision["id"],source["revision_id"]); XCTAssertEqual(revision["note_id"],source["id"]); XCTAssertEqual(revision["body"],.string("original revision source"))
        let evidence = try call(db,"read",["kind":.string("source"),"id":event["id"]],context)
        XCTAssertEqual(evidence["kind"],.string("event")); XCTAssertEqual(evidence["event_kind"],event["kind"]); XCTAssertEqual(evidence["text"],event["text"])
        let url = try call(db,"read",["kind":.string("source"),"id":.string("https://example.org/evidence")],context)
        XCTAssertEqual(url["kind"],.string("url")); XCTAssertEqual(url["url"],.string("https://example.org/evidence")); XCTAssertFalse(url["content_fetched"].boolValue)
        for ref in [hidden["id"],hidden["revision_id"],.string("unknown-source-id")] { XCTAssertThrowsError(try call(db,"read",["kind":.string("source"),"id":ref],context)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") } }
        XCTAssertThrowsError(try call(db,"read",["kind":.string("source"),"id":.string("http://")]))
        XCTAssertThrowsError(try call(db,"read",["kind":.string("source"),"id":.string("missing-source")])) { XCTAssertEqual(($0 as? MioError)?.code,"not_found") }
        let derived = try call(db,"note.create",["space_id":a,"title":.string("Derived source"),"body":.string("exact event source"),"source_ids":.array([event["id"]])])
        _ = try call(db,"history.purge",["session_id":h["id"]])
        for ref in [event["id"],derived["id"],derived["revision_id"]] { XCTAssertThrowsError(try call(db,"read",["kind":.string("source"),"id":ref])) { XCTAssertEqual(($0 as? MioError)?.code,"source_purged") } }
        // The established note-read contract is unchanged and exposes the
        // canonical empty/purged note for human inspection.
        XCTAssertEqual(try call(db,"read",["id":derived["id"]])["body"],.string(""))
    }
}

extension MioCoreTests {
    func testSourceReadIndependentlyChecksEventSessionOwnership() throws {
        let db = try store(), a = try space(db,"Allowed"), b = try space(db,"Hidden"), publicSession = try history(db,a,"public event"), hiddenSession = try history(db,b,"PRIVATE_SOURCE_SESSION",external:"hidden-session")
        var event = try call(db,"read",["kind":.string("session"),"id":publicSession["id"]])["events"].arrayValue.first!.objectValue
        event["session_id"] = hiddenSession["id"]
        // Emulate legacy/corrupt state without passing the current merge guard;
        // the read boundary must still independently authorize its parent.
        try db.put("event",.object(event))
        let profile = try call(db,"profile.create",["space_id":a,"name":.string("Source scope")]), context = AccessContext.agent(token:profile["token"].stringValue!)
        XCTAssertThrowsError(try call(db,"read",["kind":.string("source"),"id":event["id"]!],context)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") }
    }
}
