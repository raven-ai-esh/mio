import XCTest
@testable import MioCore

final class GraphTraceTests: XCTestCase {
    var directories = [URL]()
    override func tearDown() { for path in directories { try? FileManager.default.removeItem(at:path) }; super.tearDown() }
    func fixture() throws -> (MioStore,JSONValue,AccessContext) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mio-graph-trace-"+UUID().uuidString)
        directories.append(path)
        let store = try MioStore(directory:path)
        let space = try store.execute("space.create",params:["name":.string("Graph")])["id"]
        let profile = try store.execute("profile.create",params:["space_id":space,"name":.string("Graph agent")])
        return (store,space,.agent(token:profile["token"].stringValue!))
    }
    func meta(_ request: String) -> JSONValue { .object(["transport_session_id":.string("graph-test"),"request_id":.string(request)]) }
    func note(_ store: MioStore, _ space: JSONValue, _ title: String) throws -> JSONValue {
        try store.execute("note.create",params:["space_id":space,"title":.string(title),"body":.string("BODY_MUST_NOT_BE_COPIED_IN_TRACE")])
    }
    func testReadRetainsExactlyIssuedLinkPageAndPurgeClearsIt() throws {
        let (store,space,context) = try fixture()
        let a = try note(store,space,"A"), b = try note(store,space,"B"), c = try note(store,space,"C")
        for target in [b,c] { _ = try store.execute("link.create",params:["from_note_id":a["id"],"to_note_id":target["id"],"kind":.string("related")]) }
        let returned = try store.execute("read",params:["kind":.string("note"),"id":a["id"],"limit":.number(1),"_mio_interaction":meta("first-page")],context:context)
        let end = try XCTUnwrap(store.all("event").first { $0["interaction_id"] == returned["interaction_id"] && $0["phase"] == .string("end") })
        XCTAssertEqual(end["issued_graph"]["state"],.string("recorded"))
        XCTAssertEqual(end["issued_graph"]["note_id"],a["id"])
        XCTAssertEqual(end["issued_graph"]["revision_id"],returned["revision_id"])
        XCTAssertEqual(end["issued_graph"]["links"].arrayValue.map { $0["id"] },returned["links"].arrayValue.map { $0["id"] })
        XCTAssertEqual(end["issued_graph"]["next_offset"],returned["links_next_offset"])
        XCTAssertFalse(String(decoding:try end.encoded(),as:UTF8.self).contains("BODY_MUST_NOT_BE_COPIED_IN_TRACE"))
        _ = try store.execute("interaction.session.end",params:["_mio_interaction":meta("close")],context:context)
        _ = try store.execute("history.purge",params:["session_id":returned["interaction_session_id"]])
        XCTAssertFalse(String(decoding:try JSONValue.array(store.records("event",end["id"].stringValue!)).encoded(),as:UTF8.self).contains("recorded"))
    }
    func testTraceReplicaAndLateArrivalAfterPurgeCannotResurrectGraph() throws {
        let (store,space,context) = try fixture()
        let a = try note(store,space,"A"), b = try note(store,space,"GRAPH_TRACE_PRIVATE_MARKER")
        _ = try store.execute("link.create",params:["from_note_id":a["id"],"to_note_id":b["id"]])
        let returned = try store.execute("read",params:["kind":.string("note"),"id":a["id"],"_mio_interaction":meta("read")],context:context)
        _ = try store.execute("interaction.session.end",params:["_mio_interaction":meta("close")],context:context)
        let original = try store.execute("replica.export"), sid = returned["interaction_session_id"]
        let copyURL = FileManager.default.temporaryDirectory.appendingPathComponent("mio-graph-replica-"+UUID().uuidString); directories.append(copyURL)
        let copy = try MioStore(directory:copyURL)
        _ = try copy.execute("replica.merge",params:["document":original])
        let copied = try copy.execute("read",params:["kind":.string("session"),"id":sid])
        XCTAssertEqual(copied["events"].arrayValue.first{$0["issued_graph"]["state"] == .string("recorded") }?["issued_graph"]["links"].arrayValue.first?["to_note_id"],b["id"])
        _ = try store.execute("history.purge",params:["session_id":sid])
        XCTAssertNoThrow(try store.execute("replica.merge",params:["document":original]))
        let clean = try store.execute("replica.export")
        let traces = clean["records"].arrayValue.filter{$0["kind"] == .string("event")}
        XCTAssertTrue(traces.allSatisfy{$0["data"]["issued_graph"] == .null})
        var purgeFirst = original.objectValue
        purgeFirst["records"] = .array(clean["records"].arrayValue.filter{$0["kind"] == .string("session.purge")})
        purgeFirst["profiles"] = .array([]); purgeFirst["audit"] = .array([])
        let lateURL = FileManager.default.temporaryDirectory.appendingPathComponent("mio-graph-late-"+UUID().uuidString); directories.append(lateURL)
        let late = try MioStore(directory:lateURL)
        _ = try late.execute("replica.merge",params:["document":.object(purgeFirst)])
        _ = try late.execute("replica.merge",params:["document":original])
        XCTAssertTrue(try late.execute("replica.export")["records"].arrayValue.filter{$0["kind"] == .string("event")}.allSatisfy{$0["data"]["issued_graph"] == .null})
    }
    func testAuthorizedPageExcludesPrivateNeighborsAndRevocationHidesTrace() throws {
        let (store,space,context) = try fixture()
        let outside = try store.execute("space.create",params:["name":.string("Outside")])["id"]
        let hidden = try store.execute("space.create",params:["name":.string("Hidden")])["id"]
        let a = try note(store,space,"A"), b = try note(store,outside,"B"), secret = try note(store,hidden,"HIDDEN_GRAPH_MARKER")
        let connection = try store.execute("connection.create",params:["from_space_id":space,"to_space_id":outside,"access":.string("read")])
        for target in [b,secret] { _ = try store.execute("link.create",params:["from_note_id":a["id"],"to_note_id":target["id"]]) }
        let returned = try store.execute("read",params:["kind":.string("note"),"id":a["id"],"_mio_interaction":meta("scope")],context:context)
        let events = try store.execute("read",params:["kind":.string("session"),"id":returned["interaction_session_id"]])["events"].arrayValue
        let end = try XCTUnwrap(events.first{$0["phase"] == .string("end")})
        XCTAssertTrue(end["accepted_by_projection"].boolValue)
        XCTAssertEqual(end["issued_graph"]["links"].arrayValue.count,1)
        XCTAssertFalse(String(decoding:try end.encoded(),as:UTF8.self).contains("HIDDEN_GRAPH_MARKER"))
        _ = try store.execute("connection.delete",params:["connection_id":connection["id"]])
        let denied = try store.execute("read",params:["kind":.string("session"),"id":returned["interaction_session_id"],"_mio_interaction":meta("after-revoke")],context:context)
        XCTAssertFalse(denied["events"].arrayValue.contains{$0["id"] == end["id"]})
    }
}
