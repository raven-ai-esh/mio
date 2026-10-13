import XCTest
import Foundation
import Darwin
@testable import MioCore

final class MemoryInteractionTests: XCTestCase {
    var directories: [URL] = []
    override func tearDown() { for u in directories { try? FileManager.default.removeItem(at:u) }; super.tearDown() }
    func fixture() throws -> (MioStore,JSONValue,AccessContext) { let u=FileManager.default.temporaryDirectory.appendingPathComponent("mio-interaction-"+UUID().uuidString); directories.append(u); let s=try MioStore(directory:u), space=try s.execute("space.create",params:["name":.string("Agent memory")])["id"], profile=try s.execute("profile.create",params:["space_id":space,"name":.string("Agent")]); return(s,space,.agent(token:profile["token"].stringValue!)) }
    func metadata(_ request: String, session: String = "test-transport") -> JSONValue { .object(["transport_session_id":.string(session),"request_id":.string(request),"client_name":.string("Test MCP"),"client_version":.string("1")]) }
    func events(_ store: MioStore) throws -> [JSONValue] { try store.execute("snapshot")["events"].arrayValue.filter { $0["kind"].stringValue == "memory_operation" } }
    func testAgentLifecycleOnlyInsideMioNoBodyCopiesAndHumanPollNoise() throws {
        let (s,space,c)=try fixture(); let before=try events(s).count
        _=try s.execute("note.create",params:["space_id":space,"title":.string("Human note"),"body":.string("HUMAN_UI_BODY")]); _=try s.execute("snapshot",params:["projection":.string("compact")]); _=try s.currentChangeToken()
        XCTAssertEqual(try events(s).count,before)
        let created=try s.execute("note.create",params:["space_id":space,"title":.string("Agent note"),"body":.string("UNIQUE_CONTENT_NOT_IN_OPERATION_HISTORY"),"idempotency_key":.string("capture-one"),"_mio_interaction":metadata("capture")],context:c)
        let rows=try events(s), call=rows.filter{$0["interaction_id"]==created["interaction_id"]}
        XCTAssertEqual(call.count,2); XCTAssertEqual(Set(call.compactMap{$0["phase"].stringValue}),Set(["start","end"]))
        let end=try XCTUnwrap(call.first{$0["phase"] == .string("end")}); XCTAssertEqual(end["outcome"],.string("success")); XCTAssertEqual(end["receipt"],created["receipt"]); XCTAssertNotEqual(end["finished_at"],.null); XCTAssertGreaterThanOrEqual(end["duration_ms"].intValue,0)
        XCTAssertFalse(String(decoding:try JSONValue.array(rows).encoded(),as:UTF8.self).contains("UNIQUE_CONTENT_NOT_IN_OPERATION_HISTORY"))
        _=try s.execute("read",params:["id":created["id"],"_mio_interaction":metadata("read")],context:c)
        XCTAssertFalse(String(decoding:try JSONValue.array(events(s)).encoded(),as:UTF8.self).contains("UNIQUE_CONTENT_NOT_IN_OPERATION_HISTORY"))
        _=try s.execute("interaction.session.end",params:["_mio_interaction":metadata("end")],context:c)
        let session=try s.execute("read",params:["kind":.string("session"),"id":created["interaction_session_id"]]); XCTAssertEqual(session["session_state"],.string("closed")); XCTAssertEqual(session["source"],.string("memory_operations_v1")); XCTAssertNotEqual(session["closed_at"],.null)
    }
    func testNewRequestReplayHasNewSpanSameCommitAndSameRequestDeduplicates() throws {
        let (s,space,c)=try fixture(); var p:[String:JSONValue]=["space_id":space,"title":.string("Retry"),"body":.string("once"),"idempotency_key":.string("lost-reply"),"_mio_interaction":metadata("request-one")]
        let first=try s.execute("note.create",params:p,context:c); let count=try events(s).count
        XCTAssertEqual(try s.execute("note.create",params:p,context:c),first); XCTAssertEqual(try events(s).count,count)
        p["_mio_interaction"]=metadata("request-two",session:"new-transport")
        let replay=try s.execute("note.create",params:p,context:c)
        XCTAssertEqual(replay["id"],first["id"]); XCTAssertEqual(replay["revision_id"],first["revision_id"]); XCTAssertEqual(replay["receipt"],first["receipt"]); XCTAssertNotEqual(replay["interaction_id"],first["interaction_id"]); XCTAssertTrue(replay["replayed"].boolValue); XCTAssertEqual(replay["original_interaction_id"],first["interaction_id"])
        XCTAssertEqual(try events(s).count,count+2); XCTAssertEqual(try s.execute("snapshot")["counts"]["notes"].intValue,1)
    }
    func testFailureEndsObservedAndWritesNothing() throws {
        let (s,space,c)=try fixture()
        XCTAssertThrowsError(try s.execute("note.create",params:["space_id":space,"body":.string("FAILED_DRAFT_NOT_STORED"),"_mio_interaction":metadata("fail")],context:c))
        let rows=try events(s); XCTAssertEqual(rows.count,2); let end=try XCTUnwrap(rows.first{$0["phase"] == .string("end")}); XCTAssertEqual(end["outcome"],.string("error")); XCTAssertEqual(end["error_code"],.string("invalid_params")); XCTAssertEqual(end["receipt"],.null)
        XCTAssertEqual(try s.execute("snapshot")["counts"]["notes"].intValue,0); XCTAssertFalse(String(decoding:try JSONValue.array(rows).encoded(),as:UTF8.self).contains("FAILED_DRAFT_NOT_STORED"))
    }
    func testSearchTraceExcludesItselfAndLegacyChatIsNotDefaultHistory() throws {
        let (s,space,c)=try fixture()
        _=try s.execute("history.import",params:["space_id":space,"source":.string("codex"),"external_id":.string("legacy"),"events":.array([.object(["source_id":.string("old"),"text":.string("legacychat_only_keyword")])])])
        let first=try s.execute("search",params:["query":.string("operationquery_anchor"),"scope":.string("history"),"_mio_interaction":metadata("query")],context:c)
        XCTAssertEqual(first["results"].arrayValue.count,0)
        let after=try s.execute("search",params:["query":.string("operationquery_anchor"),"scope":.string("history")])
        XCTAssertEqual(after["results"].arrayValue.count,2); XCTAssertTrue(after["results"].arrayValue.allSatisfy{$0["interaction_id"]==first["interaction_id"]})
        XCTAssertEqual(try s.execute("search",params:["query":.string("legacychat_only_keyword"),"scope":.string("history")])["results"].arrayValue.count,0)
    }
    func testMixedSpaceCallHiddenAfterRevocationIncludingRefsAndCounts() throws {
        let (s,a,c)=try fixture(); let b=try s.execute("space.create",params:["name":.string("Mounted")])["id"], n=try s.execute("note.create",params:["space_id":b,"title":.string("Private"),"body":.string("private_query_marker")])
        let mount=try s.execute("connection.create",params:["from_space_id":a,"to_space_id":b,"access":.string("read")])
        let read=try s.execute("read",params:["id":n["id"],"_mio_interaction":metadata("private")],context:c)
        let privateEvents=try events(s); XCTAssertEqual(privateEvents.count,2)
        XCTAssertEqual(try s.execute("search",params:["query":.string("read"),"scope":.string("history"),"space_ids":.array([b])])["results"].arrayValue.count,2)
        _=try s.execute("connection.delete",params:["connection_id":mount["id"]])
        let snap=try s.execute("snapshot",context:c); XCTAssertEqual(snap["counts"]["events"].intValue,0); XCTAssertEqual(snap["sessions"].arrayValue.count,0); XCTAssertEqual(snap["interactions"].arrayValue.count,0)
        for e in privateEvents { XCTAssertThrowsError(try s.execute("read",params:["kind":.string("event"),"id":e["id"],"_mio_interaction":metadata("denied-"+e["phase"].stringValue!)],context:c)) }
        let session=try s.execute("read",params:["kind":.string("session"),"id":read["interaction_session_id"]],context:c)
        XCTAssertFalse(session["events"].arrayValue.contains{$0["interaction_id"]==read["interaction_id"]})
    }
    func testDurableBeginObservableFromSecondStoreWithoutFalseInterruption() throws {
        let (s,_,c)=try fixture(); let started=try s.execute("interaction.call.begin",params:["method":.string("search"),"_mio_interaction":metadata("still-running")],context:c)
        let second=try MioStore(directory:s.directory), visible=try second.execute("snapshot")["interactions"].arrayValue.first{$0["id"]==started["interaction_id"]}
        XCTAssertEqual(visible?["state"],.string("in_progress")); XCTAssertEqual(visible?["end_event_id"] ?? .null,.null)
    }
}

extension MemoryInteractionTests {
    func testReadingHistoricalTracePreservesDomainFieldsAndOwnReadIsSeparate() throws {
        let (s,space,c)=try fixture()
        let params:[String:JSONValue]=["space_id":space,"title":.string("Trace ref"),"body":.string("stored knowledge"),"idempotency_key":.string("trace-write"),"_mio_interaction":metadata("first-write")]
        let first=try s.execute("note.create",params:params,context:c); var replayParams=params; replayParams["_mio_interaction"]=metadata("replay-write")
        let replay=try s.execute("note.create",params:replayParams,context:c), original=try XCTUnwrap(events(s).first{$0["interaction_id"]==replay["interaction_id"] && $0["phase"] == .string("end")})
        let read=try s.execute("read",params:["kind":.string("source"),"id":original["id"],"_mio_interaction":metadata("inspect")],context:c)
        XCTAssertEqual(read["interaction_id"],original["interaction_id"]); XCTAssertEqual(read["replayed"],.bool(true)); XCTAssertEqual(read["receipt"],first["receipt"]); XCTAssertEqual(read["outcome"],original["outcome"])
        XCTAssertNotEqual(read["call_trace"]["interaction_id"],original["interaction_id"])
        let own=try XCTUnwrap(events(s).first{$0["interaction_id"]==read["call_trace"]["interaction_id"] && $0["phase"] == .string("end")})
        XCTAssertEqual(own["receipt"],.null); XCTAssertEqual(own["result_refs"].arrayValue.first?["id"],original["id"])
    }
}

extension MemoryInteractionTests {
    func testActualProcessDeathKeepsStartThenMarksInterruptedNeverSuccessful() throws {
        let (s,_,context)=try fixture(); guard case .agent(let token)=context else { return XCTFail("No test profile") }
        let package=URL(fileURLWithPath:#filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable=package.appendingPathComponent(".build/debug/MioBench")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { return XCTFail("Build the actual MioBench helper before this test") }
        let child=Process(); child.executableURL=executable; child.arguments=["trace-crash","--state",s.directory.path]; var environment=ProcessInfo.processInfo.environment; environment["MIO_BENCH_AGENT_TOKEN"]=token; child.environment=environment; child.standardOutput=Pipe(); child.standardError=Pipe()
        try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationReason,.uncaughtSignal); XCTAssertEqual(child.terminationStatus,SIGKILL)
        let snap=try s.execute("snapshot"), interrupted=try XCTUnwrap(snap["interactions"].arrayValue.first)
        XCTAssertEqual(interrupted["state"],.string("interrupted")); XCTAssertEqual(interrupted["finished_at"],.null); XCTAssertEqual(interrupted["receipt"],.null)
        XCTAssertEqual(snap["counts"]["notes"].intValue,0)
        let session=try XCTUnwrap(snap["sessions"].arrayValue.first); XCTAssertEqual(session["session_state"],.string("interrupted")); XCTAssertEqual(session["closed_at"],.null)
        let rows=try events(s); XCTAssertEqual(rows.count,2); XCTAssertTrue(rows.contains{$0["phase"] == .string("start")}); XCTAssertTrue(rows.contains{$0["outcome"] == .string("interrupted")})
    }
    func testSessionSequenceMonotoneAcrossFastCallsAndNoUITrace() throws {
        let (s,space,c)=try fixture()
        for i in 0..<5 { _=try s.execute("note.create",params:["space_id":space,"title":.string("Call \(i)"),"body":.string("x"),"idempotency_key":.string("seq-\(i)"),"_mio_interaction":metadata("seq-\(i)")],context:c) }
        let session=try XCTUnwrap(s.execute("snapshot")["sessions"].arrayValue.first), rows=try s.execute("read",params:["kind":.string("session"),"id":session["id"]])["events"].arrayValue
        XCTAssertEqual(rows.map{$0["source_sequence"].intValue},Array(0..<10)); XCTAssertEqual(rows.map{$0["phase"].stringValue!},(0..<5).flatMap{_ in ["start","end"]})
        let count=rows.count; _=try s.execute("snapshot"); _=try s.execute("read",params:["kind":.string("session"),"id":session["id"]]); XCTAssertEqual(try events(s).count,count)
    }
}

extension MemoryInteractionTests {
    func testDistinctRepeatedSearchAttemptsStayDiscoverableAndTraceURICredentialsAreRemoved() throws {
        let (s,space,c)=try fixture()
        let first=try s.execute("search",params:["query":.string("repeated-attempt-marker"),"scope":.string("history"),"_mio_interaction":metadata("repeat-one")],context:c)
        let second=try s.execute("search",params:["query":.string("repeated-attempt-marker"),"scope":.string("history"),"_mio_interaction":metadata("repeat-two")],context:c)
        let found=try s.execute("search",params:["query":.string("repeated-attempt-marker"),"scope":.string("history"),"limit":.number(100),"max_chars":.number(20000)])["results"].arrayValue
        for phase in ["start","end"] { XCTAssertEqual(Set(found.filter{$0["phase"] == .string(phase)}.compactMap{$0["interaction_id"].stringValue}),Set([first["call_trace"]["interaction_id"].stringValue!,second["call_trace"]["interaction_id"].stringValue!])) }
        let raw="https://trace-user:URI_PASS_SECRET@example.org/source?token=URI_QUERY_SECRET&q=visible#access_token=URI_FRAGMENT_SECRET"
        let read=try s.execute("read",params:["kind":.string("source"),"id":.string(raw),"_mio_interaction":metadata("url-source")],context:c)
        XCTAssertEqual(read["url"],.string(raw),"The explicit API URL response remains unchanged")
        _=try s.execute("search",params:["query":.string("source URI "+raw),"scope":.string("notes"),"_mio_interaction":metadata("url-query")],context:c)
        let note=try s.execute("note.create",params:["space_id":space,"title":.string("Explicit source"),"body":.string(raw),"source_ids":.array([.string(raw)]),"_mio_interaction":metadata("explicit-url-note")],context:c)
        XCTAssertEqual(try s.execute("read",params:["id":note["id"]])["body"],.string(raw))
        XCTAssertEqual(try s.execute("read",params:["id":note["id"]])["source_ids"],.array([.string(raw)]))
        let journal=String(decoding:try JSONValue.array(s.all("event")+s.all("interaction")).encoded(),as:UTF8.self)
        for marker in ["trace-user","URI_PASS_SECRET","URI_QUERY_SECRET","URI_FRAGMENT_SECRET"] { XCTAssertFalse(journal.contains(marker)); XCTAssertFalse(try s.db.rows("SELECT json FROM audit").contains{$0["json"]?.contains(marker)==true}) }
        XCTAssertTrue(journal.contains("credentials_removed")); XCTAssertTrue(journal.contains("original_hash")); XCTAssertTrue(journal.contains("q=visible"))
        let harmless="https://example.org/paper?id=42#section-one"; XCTAssertEqual(s.traceString(harmless),harmless)
        let punctuationURI="https://trace-user:prefix)PRIVATE_PASSWORD_SUFFIX@example.org/source"
        XCTAssertEqual(s.traceString(punctuationURI),"https://example.org/source"); XCTAssertFalse(s.traceString("URI "+punctuationURI).contains("PRIVATE_PASSWORD_SUFFIX"))
    }
    func testCachedSessionReplyRechecksNestedMountGrantsAndExternallyPurgedSource() throws {
        let (s,a,c)=try fixture(), b=try s.execute("space.create",params:["name":.string("Mounted history")])["id"]
        let mount=try s.execute("connection.create",params:["from_space_id":a,"to_space_id":b,"access":.string("read")])
        let source=try s.execute("search",params:["query":.string("NESTED_PRIVATE_QUERY"),"scope":.string("history"),"space_ids":.array([b]),"_mio_interaction":metadata("source-query",session:"source")],context:c)
        let p:[String:JSONValue]=["kind":.string("session"),"id":source["call_trace"]["session_id"],"_mio_interaction":metadata("reader",session:"reader")]
        let reply=try s.execute("read",params:p,context:c)
        XCTAssertTrue(String(decoding:try reply.encoded(),as:UTF8.self).contains("NESTED_PRIVATE_QUERY"))
        _=try s.execute("connection.delete",params:["connection_id":mount["id"]])
        XCTAssertThrowsError(try s.execute("read",params:p,context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") }
        _=try s.execute("connection.create",params:["from_space_id":a,"to_space_id":b,"access":.string("read")])
        _=try s.execute("interaction.session.end",params:["_mio_interaction":metadata("close",session:"source")],context:c)
        let external=try MioStore(directory:s.directory)
        _=try external.execute("history.purge",params:["session_id":source["call_trace"]["session_id"]])
        XCTAssertNotNil(s.interactionReplies[reply["call_trace"]["interaction_id"].stringValue!],"An external store cannot clear this connection's volatile cache")
        XCTAssertThrowsError(try s.execute("read",params:p,context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") }
    }
    func testTrustedDeliveryAndAdapterReportPreserveExecutionAndSparseReplay() throws {
        let (s,space,c)=try fixture(); var meta=metadata("delivery").objectValue; meta["adapter_pid"] = .number(Double(getpid())); let stamped=JSONValue.object(meta)
        let created=try s.execute("note.create",params:["space_id":space,"title":.string("Delivery"),"body":.string("DRAFT_NOT_IN_DELIVERY"),"_mio_interaction":stamped],context:c)
        let before=try XCTUnwrap(s.entity("interaction",created["call_trace"]["interaction_id"].stringValue!))
        try s.observeMemoryDelivery(metadata:stamped,context:c,peerPID:getpid(),state:"frame_too_large",errorCode:"frame_too_large")
        let current=try XCTUnwrap(s.entity("interaction",before["id"].stringValue!)); XCTAssertEqual(current["state"],.string("completed")); XCTAssertEqual(current["end_event_id"],before["end_event_id"]); XCTAssertEqual(current["receipt"],created["receipt"]); XCTAssertEqual(current["response_delivery"],.string("frame_too_large"))
        let count=try s.all("event").count; try s.observeMemoryDelivery(metadata:stamped,context:c,peerPID:getpid(),state:"frame_too_large"); XCTAssertEqual(try s.all("event").count,count)
        _=try s.execute("interaction.call.delivery",params:["state":.string("stdout_written"),"_mio_interaction":stamped],context:c)
        XCTAssertThrowsError(try s.execute("interaction.call.delivery",params:["state":.string("socket_written"),"_mio_interaction":stamped],context:c))
        XCTAssertThrowsError(try s.observeMemoryDelivery(metadata:stamped,context:c,peerPID:getpid()+1,state:"socket_written"))
        let delivery=try XCTUnwrap(s.all("event").first{$0["phase"] == .string("delivery")}); XCTAssertEqual(delivery["request"],.object([:])); XCTAssertEqual(delivery["result_refs"],.array([])); XCTAssertFalse(delivery["consumption_observed"].boolValue)
        XCTAssertFalse(String(decoding:try delivery.encoded(),as:UTF8.self).contains("DRAFT_NOT_IN_DELIVERY"))
        let replica=try s.execute("replica.export"), targetURL=FileManager.default.temporaryDirectory.appendingPathComponent("mio-delivery-replica-"+UUID().uuidString); directories.append(targetURL); let target=try MioStore(directory:targetURL)
        func subset(_ records:[JSONValue]) -> JSONValue { var d=replica.objectValue; d["records"] = .array(records); d["audit"] = .array([]); d["profiles"] = .array([]); return .object(d) }
        let records=replica["records"].arrayValue, deliveries=records.filter{$0["data"]["phase"] == .string("delivery")}, foundations=records.filter{["space","session"].contains($0["kind"].stringValue ?? "")}
        _=try target.execute("replica.merge",params:["document":subset(foundations+deliveries)])
        XCTAssertEqual(try target.execute("sync.pending")["pending_dependencies"].intValue,deliveries.count)
        XCTAssertThrowsError(try target.execute("archive.export",params:["path":.string(target.directory.appendingPathComponent("incomplete.mio").path)])) { XCTAssertEqual(($0 as? MioError)?.code,"archive_corrupt") }
        _=try target.execute("replica.merge",params:["document":replica]); let restored=try XCTUnwrap(target.entity("interaction",before["id"].stringValue!))
        XCTAssertEqual(restored["state"],.string("completed")); XCTAssertEqual(restored["response_delivery"],.string("frame_too_large")); XCTAssertEqual(restored["adapter_delivery"],.string("stdout_written")); XCTAssertEqual(restored["receipt"],created["receipt"])
        _=try target.execute("replica.merge",params:["document":replica]); XCTAssertEqual(try target.entity("interaction",before["id"].stringValue!)?["response_delivery"],.string("frame_too_large"))
    }
    func testKnownRevokedCredentialRecordsDeniedAttemptWithoutPermissionOrReplay() throws {
        let (s,space,c)=try fixture()
        let p:[String:JSONValue]=["space_id":space,"title":.string("Original"),"body":.string("ONLY_NOTE_BODY"),"idempotency_key":.string("known-replay"),"_mio_interaction":metadata("before-revoke")]
        let first=try s.execute("note.create",params:p,context:c), profile=try XCTUnwrap(s.execute("snapshot")["profiles"].arrayValue.first)
        _=try s.execute("profile.revoke",params:["profile_id":profile["id"]])
        let originalEvents=try events(s), revisions=try s.all("revision").count
        XCTAssertThrowsError(try s.execute("note.create",params:p,context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"unauthorized") }
        XCTAssertEqual(try events(s),originalEvents)
        var denied=p; denied["_mio_interaction"]=metadata("after-revoke"); denied["body"] = .string("DENIED_BODY_NOT_RETAINED")
        XCTAssertThrowsError(try s.execute("note.create",params:denied,context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"unauthorized") }
        let rows=try events(s), rejected=rows.filter{$0["interaction_id"] != first["call_trace"]["interaction_id"]}
        XCTAssertEqual(rejected.count,2); XCTAssertTrue(rejected.allSatisfy{$0["actor"]==profile["id"]}); XCTAssertEqual(rejected.first{$0["phase"] == .string("end") }?["error_code"],.string("unauthorized"))
        XCTAssertTrue(rejected.allSatisfy{$0["receipt"] == .null && $0["result_refs"].arrayValue.isEmpty}); XCTAssertFalse(String(decoding:try JSONValue.array(rejected).encoded(),as:UTF8.self).contains("DENIED_BODY_NOT_RETAINED"))
        XCTAssertEqual(try s.all("revision").count,revisions); XCTAssertEqual(try s.execute("snapshot")["counts"]["notes"].intValue,1)
        XCTAssertThrowsError(try s.execute("read",params:["kind":.string("event"),"id":rejected.first?["id"] ?? .string("missing-denied-trace"),"_mio_interaction":metadata("denied-trace-read")],context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"unauthorized") }
        let beforeUnknown=try events(s).count
        XCTAssertThrowsError(try s.execute("search",params:["query":.string("UNKNOWN_QUERY_NOT_STORED"),"_mio_interaction":metadata("unknown")],context:.agent(token:"unknown")))
        XCTAssertEqual(try events(s).count,beforeUnknown)
        let beforeControl=try events(s).count
        XCTAssertThrowsError(try s.execute("interaction.call.reject",params:["method":.string("search"),"error_code":.string("unauthorized"),"_mio_interaction":metadata("first-revoked-tool",session:"fresh-revoked-transport")],context:c))
        XCTAssertEqual(try events(s).count,beforeControl+2)
        XCTAssertThrowsError(try s.execute("interaction.session.end",params:["_mio_interaction":metadata("end")],context:c))
        XCTAssertEqual(try s.execute("read",params:["kind":.string("session"),"id":first["call_trace"]["session_id"]])["session_state"],.string("open"))
    }
    func testLiveSpanPreventsSessionCloseAndClosedSessionRejectsNewRequests() throws {
        let (s,_,c)=try fixture()
        let open=try s.execute("interaction.call.begin",params:["method":.string("search"),"_mio_interaction":metadata("pending")],context:c)
        XCTAssertThrowsError(try s.execute("interaction.session.end",params:["_mio_interaction":metadata("end")],context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"interaction_active") }
        XCTAssertEqual(try s.execute("read",params:["kind":.string("session"),"id":open["session_id"]])["session_state"],.string("open"))
        let other=try s.execute("search",params:["query":.string("closed-transport"),"scope":.string("notes"),"_mio_interaction":metadata("finished",session:"closed-transport")],context:c)
        _=try s.execute("interaction.session.end",params:["_mio_interaction":metadata("end",session:"closed-transport")],context:c)
        XCTAssertThrowsError(try s.execute("search",params:["query":.string("new"),"_mio_interaction":metadata("new",session:"closed-transport")],context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"session_closed") }
        XCTAssertEqual(try s.execute("read",params:["kind":.string("session"),"id":other["call_trace"]["session_id"]])["event_count"].intValue,2)
    }
    func testRevokedMixedSpaceEventCannotBeAttachedAndExistingSourceRefIsHidden() throws {
        let (s,a,c)=try fixture(), b=try s.execute("space.create",params:["name":.string("Mounted source")])["id"]
        let privateNote=try s.execute("note.create",params:["space_id":b,"title":.string("Private"),"body":.string("private")]), mount=try s.execute("connection.create",params:["from_space_id":a,"to_space_id":b,"access":.string("read")])
        let read=try s.execute("read",params:["id":privateNote["id"],"_mio_interaction":metadata("source-read")],context:c), event=try XCTUnwrap(events(s).first{$0["interaction_id"]==read["call_trace"]["interaction_id"] && $0["phase"] == .string("end")})
        let saved=try s.execute("note.create",params:["space_id":a,"title":.string("Evidence note"),"body":.string("general saved knowledge"),"source_ids":.array([event["id"]]),"_mio_interaction":metadata("save-with-source")],context:c)
        _=try s.execute("connection.delete",params:["connection_id":mount["id"]])
        XCTAssertFalse(try s.execute("snapshot",context:c)["events"].arrayValue.contains{$0["interaction_id"]==saved["call_trace"]["interaction_id"]})
        XCTAssertEqual(try s.execute("read",params:["id":saved["id"],"_mio_interaction":metadata("source-after-revoke")],context:c)["source_ids"],.array([]))
        XCTAssertThrowsError(try s.execute("note.create",params:["space_id":a,"title":.string("Denied attachment"),"source_ids":.array([event["id"]]),"_mio_interaction":metadata("denied-source")],context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") }
        XCTAssertEqual(try s.execute("snapshot")["counts"]["notes"].intValue,2)
    }
    func testClearingClosedTraceErasesNestedQueryProjectionCacheArchiveAndOldReplay() throws {
        let (s,_,c)=try fixture(), marker="QUERY_ONLY_ERASURE_"+UUID().uuidString
        var stamped=metadata("query-erase").objectValue; stamped["adapter_pid"] = .number(Double(getpid()))
        let p:[String:JSONValue]=["query":.string(marker),"scope":.string("history"),"_mio_interaction":.object(stamped)]
        let result=try s.execute("search",params:p,context:c), sessionID=result["call_trace"]["session_id"]
        try s.observeMemoryDelivery(metadata:.object(stamped),context:c,peerPID:getpid(),state:"socket_written")
        XCTAssertThrowsError(try s.execute("history.purge",params:["session_id":sessionID])) { XCTAssertEqual(($0 as? MioError)?.code,"session_active") }
        _=try s.execute("interaction.session.end",params:["_mio_interaction":metadata("close")],context:c)
        let old=try s.execute("replica.export")
        _=try s.execute("history.purge",params:["session_id":sessionID])
        XCTAssertFalse(String(decoding:try s.execute("replica.export").encoded(),as:UTF8.self).contains(marker))
        XCTAssertFalse(try s.db.rows("SELECT json FROM entities").contains{$0["json"]?.contains(marker)==true})
        XCTAssertEqual(try s.execute("search",params:["query":.string(marker),"scope":.string("history")])["results"].arrayValue.count,0)
        XCTAssertThrowsError(try s.execute("search",params:p,context:c)) { XCTAssertEqual(($0 as? MioError)?.code,"source_purged") }
        _=try s.execute("replica.merge",params:["document":old])
        XCTAssertFalse(String(decoding:try s.execute("replica.export").encoded(),as:UTF8.self).contains(marker))
        let archive=s.directory.appendingPathComponent("clean.mio"); _=try s.execute("archive.export",params:["path":.string(archive.path)])
        XCTAssertFalse(String(decoding:try Data(contentsOf:archive),as:UTF8.self).contains(marker))
        XCTAssertTrue(s.interactionReplies.isEmpty)
    }
}
