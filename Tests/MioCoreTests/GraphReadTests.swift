import XCTest
import Foundation
@testable import MioCore

final class GraphReadTests: XCTestCase {
    var root: URL!
    var db: MioStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mio-graph-read-" + UUID().uuidString)
        db = try MioStore(directory: root)
    }
    override func tearDownWithError() throws { db = nil; try FileManager.default.removeItem(at: root) }
    func call(_ method: String, _ params: [String: JSONValue] = [:], _ context: AccessContext = .human) throws -> JSONValue { try db.execute(method, params: params, context: context) }
    func space(_ name: String) throws -> JSONValue { try call("space.create", ["name": .string(name)])["id"] }
    func note(_ space: JSONValue, _ title: String, _ body: String = "") throws -> JSONValue { try call("note.create", ["space_id": space, "title": .string(title), "body": .string(body)]) }
    func read(_ note: JSONValue, _ context: AccessContext = .human, extra: [String: JSONValue] = [:]) throws -> JSONValue {
        var p = extra; p["kind"] = .string("note"); p["id"] = note["id"]; return try call("read", p, context)
    }
    func link(_ from: JSONValue, _ to: JSONValue, _ kind: String = "related") throws -> JSONValue { try call("link.create", ["from_note_id": from["id"], "to_note_id": to["id"], "kind": .string(kind)]) }
    func agent(_ space: JSONValue) throws -> (JSONValue, AccessContext) {
        let p = try call("profile.create", ["space_id": space, "name": .string("graph reader")]); return (p, .agent(token: p["token"].stringValue!))
    }

    func testSearchReadWalksSameWikiAndExplicitGraphInBothDirections() throws {
        let s = try space("Walk"), d = try note(s, "D", "EXACT_D_ONLY_FACT"), c = try note(s, "C", "Choose neighbor D"), a = try note(s, "A", "ENTRY_ANCHOR [[C]]")
        let cd = try link(c, d, "supports"), (_, context) = try agent(s)
        let found = try call("search", ["query": .string("ENTRY_ANCHOR"), "scope": .string("notes")], context)["results"].arrayValue
        XCTAssertEqual(found.map { $0["id"] }, [a["id"]])
        let ar = try read(a, context)
        XCTAssertEqual(ar["links_state"], .string("current")); XCTAssertEqual(ar["links_revision_id"], a["revision_id"])
        XCTAssertEqual(ar["links"].arrayValue.count, 1)
        let ac = try XCTUnwrap(ar["links"].arrayValue.first)
        XCTAssertEqual(ac["note"]["id"], c["id"]); XCTAssertEqual(ac["note"]["kind"], .string("note")); XCTAssertEqual(ac["direction"], .string("outgoing")); XCTAssertEqual(ac["origin"], .string("wikilink"))
        XCTAssertEqual(ac["note"]["body"], .null)
        let cr = try call("read", ["kind": .string("note"), "id": ac["note"]["id"]], context)
        XCTAssertTrue(cr["links"].arrayValue.contains { $0["note"]["id"] == a["id"] && $0["direction"] == .string("incoming") })
        let edge = try XCTUnwrap(cr["links"].arrayValue.first { $0["note"]["id"] == d["id"] })
        XCTAssertEqual(edge["id"], cd["id"]); XCTAssertEqual(edge["kind"], .string("supports")); XCTAssertEqual(edge["origin"], .string("explicit"))
        XCTAssertEqual(try call("read", ["kind": .string("note"), "id": edge["note"]["id"]], context)["body"], .string("EXACT_D_ONLY_FACT"))
        let graphIDs = Set(try call("snapshot")["links"].arrayValue.compactMap { $0["id"].stringValue })
        XCTAssertTrue(graphIDs.contains(ac["id"].stringValue!)); XCTAssertTrue(graphIDs.contains(edge["id"].stringValue!))
        XCTAssertEqual(try read(d, context)["links"].arrayValue.first?["direction"], .string("incoming"))
        XCTAssertFalse(String(decoding: try ar.encoded(), as: UTF8.self).contains("EXACT_D_ONLY_FACT"))
    }

    func testWikiRemovalAndExplicitAdoptionKeepOneRelationAndIdentity() throws {
        let s = try space("Links"), b = try note(s, "B"), a = try note(s, "A", "[[B]]")
        let wiki = try XCTUnwrap(try read(a)["links"].arrayValue.first)
        let adopted = try link(a, b)
        XCTAssertEqual(adopted["id"], wiki["id"])
        XCTAssertEqual(try link(a, b)["id"], wiki["id"])
        _ = try call("note.update", ["note_id": a["id"], "expected_revision": a["revision_id"], "body": .string("No text link")])
        let kept = try read(a)["links"].arrayValue
        XCTAssertEqual(kept.count, 1); XCTAssertEqual(kept.first?["id"], wiki["id"]); XCTAssertEqual(kept.first?["origin"], .string("explicit"))
        let automatic = try note(s, "Automatic", "[[B]]")
        _ = try call("note.update", ["note_id": automatic["id"], "expected_revision": automatic["revision_id"], "body": .string("Removed wiki")])
        XCTAssertEqual(try read(automatic)["links"], .array([]))
        XCTAssertFalse(try read(b)["links"].arrayValue.contains { $0["note"]["id"] == automatic["id"] })
    }

    func testHiddenIncomingAndOutgoingNeighborsAreFilteredAndGrantsNeverChain() throws {
        let sa = try space("A"), sb = try space("B"), sc = try space("C")
        let a = try note(sa, "Root"), b = try note(sb, "PRIVATE_B_NAME"), c = try note(sc, "PRIVATE_C_NAME")
        _ = try link(a, b); _ = try link(c, a); _ = try link(b, c)
        let (_, context) = try agent(sa)
        XCTAssertEqual(try read(a, context)["links"], .array([]))
        _ = try call("connection.create", ["from_space_id": sb, "to_space_id": sc, "access": .string("read")])
        let mount = try call("connection.create", ["from_space_id": sa, "to_space_id": sb, "access": .string("read")])
        XCTAssertEqual(try read(a, context)["links"].arrayValue.map { $0["note"]["id"] }, [b["id"]])
        XCTAssertFalse(String(decoding: try read(b, context).encoded(), as: UTF8.self).contains("PRIVATE_C_NAME"))
        XCTAssertFalse(try read(b, context)["links"].arrayValue.contains { $0["note"]["id"] == c["id"] })
        _ = try call("connection.delete", ["connection_id": mount["id"]])
        XCTAssertEqual(try read(a, context)["links"], .array([])); XCTAssertEqual(try read(a, context)["links_next_offset"], .null)
    }

    func testDeletedPurgedAndRemovedEdgesDoNotExposeNeighbors() throws {
        let s = try space("Deletion"), a = try note(s, "A"), b = try note(s, "B")
        let edge = try link(a, b)
        _ = try call("note.delete", ["note_id": b["id"]])
        XCTAssertEqual(try read(a)["links"], .array([]))
        _ = try call("note.restore", ["note_id": b["id"], "revision_id": b["revision_id"]])
        XCTAssertEqual(try read(a)["links"].arrayValue.first?["id"], edge["id"])
        _ = try call("link.delete", ["link_id": edge["id"]])
        XCTAssertEqual(try read(a)["links"], .array([])); XCTAssertEqual(try read(b)["links"], .array([]))
        let (_, context) = try agent(s)
        let trace = try read(a, context)
        let end = try XCTUnwrap(try call("snapshot")["events"].arrayValue.first { $0["interaction_id"] == trace["interaction_id"] && $0["phase"] == .string("end") })
        let derived = try call("note.create", ["space_id": s, "title": .string("PURGED_TITLE"), "body": .string("PURGED_BODY"), "source_ids": .array([end["id"]])])
        _ = try link(a, derived)
        let session = try call("read", ["kind": .string("session"), "id": end["session_id"]])
        _ = try call("interaction.session.end", ["_mio_interaction": .object(["transport_session_id": session["transport_session_id"]])], context)
        _ = try call("history.purge", ["session_id": end["session_id"]])
        XCTAssertEqual(try read(a)["links"], .array([])); XCTAssertFalse(String(decoding: try read(a).encoded(), as: UTF8.self).contains("PURGED_TITLE"))
    }

    func testVisiblePaginationAndMetadataBoundsDoNotCountHiddenNeighbors() throws {
        let s = try space("Page"), hidden = try space("Hidden"), a = try note(s, "A")
        for i in 0..<5 { _ = try link(a, try note(s, "Visible \(i) " + String(repeating: "x", count: 400))) }
        for i in 0..<4 { _ = try link(a, try note(hidden, "HIDDEN_\(i)")) }
        let (_, context) = try agent(s)
        let all = try read(a, context, extra: ["limit": .number(200)])["links"].arrayValue
        XCTAssertEqual(all.count, 5); XCTAssertTrue(all.allSatisfy { ($0["note"]["title"].stringValue?.count ?? 0) <= 300 && $0["note"]["title_truncated"].boolValue })
        let first = try read(a, context, extra: ["limit": .number(2)])
        XCTAssertEqual(first["links"].arrayValue.map { $0["id"] }, Array(all.prefix(2)).map { $0["id"] }); XCTAssertEqual(first["links_next_offset"], .number(2))
        let second = try read(a, context, extra: ["offset": first["links_next_offset"], "limit": .number(2)])
        XCTAssertEqual(second["links"].arrayValue.map { $0["id"] }, Array(all.dropFirst(2).prefix(2)).map { $0["id"] }); XCTAssertEqual(second["links_next_offset"], .number(4))
        let pageEnd = try XCTUnwrap(try call("snapshot")["events"].arrayValue.first { $0["interaction_id"] == second["interaction_id"] && $0["phase"] == .string("end") })
        XCTAssertEqual(pageEnd["request"]["offset"], .number(2)); XCTAssertEqual(pageEnd["request"]["limit"], .number(2))
        let last = try read(a, context, extra: ["offset": .number(4), "limit": .number(2)])
        XCTAssertEqual(last["links"].arrayValue.count, 1); XCTAssertEqual(last["links_next_offset"], .null)
        XCTAssertEqual(try read(a, context, extra: ["offset": .number(50)])["links"], .array([]))
        XCTAssertFalse(String(decoding: try first.encoded(), as: UTF8.self).contains("HIDDEN_"))
    }

    func testExactHistoricalVersionsDoNotGainCurrentGraphButCurrentSourcesDo() throws {
        let s = try space("Versions"), c = try note(s, "C"), d = try note(s, "D"), a = try note(s, "A", "[[C]]")
        let changed = try call("note.update", ["note_id": a["id"], "expected_revision": a["revision_id"], "body": .string("[[D]]")])
        for params: [String: JSONValue] in [["kind": .string("note"), "id": a["id"], "revision_id": a["revision_id"]], ["kind": .string("source"), "id": a["revision_id"]]] {
            let old = try call("read", params)
            XCTAssertEqual(old["body"], .string("[[C]]")); XCTAssertEqual(old["links_state"], .string("unavailable_for_historical_revision")); XCTAssertEqual(old["links"], .array([])); XCTAssertEqual(old["links_next_offset"], .null)
            XCTAssertFalse(String(decoding: try old.encoded(), as: UTF8.self).contains(d["id"].stringValue!))
        }
        for params: [String: JSONValue] in [["kind": .string("note"), "id": a["id"], "revision_id": changed["revision_id"]], ["kind": .string("source"), "id": a["id"]], ["kind": .string("source"), "id": changed["revision_id"]]] {
            let current = try call("read", params)
            XCTAssertEqual(current["links_state"], .string("current")); XCTAssertEqual(current["links"].arrayValue.map { $0["note"]["id"] }, [d["id"]]); XCTAssertEqual(current["links_revision_id"], changed["revision_id"])
        }
        XCTAssertEqual(try read(c)["links"], .array([]))
        let revisedD = try call("note.update", ["note_id": d["id"], "expected_revision": d["revision_id"], "title": .string("D new"), "body": .string("not echoed")])
        XCTAssertEqual(try read(a)["links"].arrayValue.first?["note"]["revision_id"], revisedD["revision_id"])
        XCTAssertThrowsError(try call("note.update", ["note_id": d["id"], "expected_revision": d["revision_id"], "body": .string("conflicting draft")]))
        XCTAssertEqual(try read(a)["links"].arrayValue.first?["note"]["has_conflict"], .bool(true))
    }

    func testCachedRepliesAndPastTraceRequireAllNeighborSpacesAndLiveEdges() throws {
        let sa = try space("A"), sb = try space("B"), a = try note(sa, "A"), b = try note(sb, "B")
        let edge = try link(a, b), (_, context) = try agent(sa)
        let mount = try call("connection.create", ["from_space_id": sa, "to_space_id": sb, "access": .string("read")])
        let metadata: JSONValue = .object(["transport_session_id": .string(UUID().uuidString), "request_id": .string("same-read")])
        let p: [String: JSONValue] = ["kind": .string("note"), "id": a["id"], "_mio_interaction": metadata]
        let original = try call("read", p, context)
        XCTAssertEqual(try call("read", p, context)["links"], original["links"])
        let end = try XCTUnwrap(try call("snapshot")["events"].arrayValue.first { $0["interaction_id"] == original["interaction_id"] && $0["phase"] == .string("end") })
        XCTAssertTrue(end["required_space_ids"].arrayValue.contains(sb))
        _ = try call("connection.delete", ["connection_id": mount["id"]])
        XCTAssertThrowsError(try call("read", p, context))
        XCTAssertThrowsError(try call("read", ["kind": .string("event"), "id": end["id"]], context))
        XCTAssertEqual(try read(a, context)["links"], .array([]))
        _ = try call("connection.create", ["from_space_id": sa, "to_space_id": sb, "access": .string("read")])
        _ = try call("link.delete", ["link_id": edge["id"]])
        XCTAssertThrowsError(try call("read", p, context))
        XCTAssertEqual(try read(a, context)["links"], .array([]))
    }

    func testReplicaDuplicateRelationsAndSelfEdgesStayDeterministic() throws {
        let s = try space("Duplicates"), a = try note(s, "A"), b = try note(s, "B"), edge = try link(a, b)
        var duplicate = edge.objectValue; duplicate["id"] = .string(UUID().uuidString.lowercased())
        _ = try db.record("link", entityID: duplicate["id"]!.stringValue!, data: .object(duplicate))
        let different = try link(a, b, "supports"), selfEdge = try link(a, a)
        let links = try read(a)["links"].arrayValue
        XCTAssertEqual(links.count, 3); XCTAssertEqual(links.filter { $0["direction"] == .string("self") }.map { $0["id"] }, [selfEdge["id"]])
        XCTAssertTrue(links.contains { $0["id"] == different["id"] })
        let related = try XCTUnwrap(links.first { $0["to_note_id"] == b["id"] && $0["kind"] == .string("related") })
        XCTAssertEqual(related["id"].stringValue, [edge["id"].stringValue!, duplicate["id"]!.stringValue!].sorted().first)
    }

    func testCachedNeighborDeletionAndRetargetedRelationAreRejected() throws {
        let s = try space("Cache"), a = try note(s, "A"), b = try note(s, "B"), c = try note(s, "C")
        let edge = try link(a, b), (_, context) = try agent(s)
        func params(_ request: String) -> [String: JSONValue] { ["kind": .string("note"), "id": a["id"], "_mio_interaction": .object(["transport_session_id": .string("live-cache"), "request_id": .string(request)])] }
        let deletedRead = params("before-delete")
        XCTAssertEqual(try call("read", deletedRead, context)["links"].arrayValue.first?["note"]["id"], b["id"])
        _ = try call("note.delete", ["note_id": b["id"]])
        XCTAssertThrowsError(try call("read", deletedRead, context))
        _ = try call("note.restore", ["note_id": b["id"], "revision_id": b["revision_id"]])
        let retargetedRead = params("before-retarget")
        _ = try call("read", retargetedRead, context)
        var replacement = edge.objectValue; replacement["to_note_id"] = c["id"]
        _ = try db.record("link", entityID: edge["id"].stringValue!, data: .object(replacement))
        XCTAssertThrowsError(try call("read", retargetedRead, context))
        XCTAssertEqual(try read(a, context)["links"].arrayValue.first?["note"]["id"], c["id"])
    }
}
