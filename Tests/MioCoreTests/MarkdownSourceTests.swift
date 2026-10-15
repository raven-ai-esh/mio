import XCTest
import Foundation
@testable import MioCore

extension MioCoreTests {
    func markdownFixture(_ root: URL, metadata: [String:JSONValue], body: String = "---\noriginal: retained\n---\nExact body\r\n") throws {
        let text = "---\nmio: " + String(decoding:try JSONValue.object(metadata).encoded(),as:UTF8.self) + "\n---\n" + body
        try Data(text.utf8).write(to:root.appendingPathComponent("Evidence.md"))
    }
    func testMarkdownSourceRoundTripPreservesEvidenceAndBody() throws {
        let db = try store(), sid = try space(db), source = try note(db,sid,"Source"), vault = try directory()
        let refs: JSONValue = .array([.string("https://example.org/evidence"),source["id"]])
        let body = "---\noriginal: retained\n---\nExact body\r\n"
        try markdownFixture(vault,metadata:["title":.string("Research/Exact title"),"status":.string("verified"),"source_ids":refs],body:body)
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        let imported = try XCTUnwrap(try db.all("note").first{$0["title"] == .string("Research/Exact title")})
        XCTAssertEqual(imported["body"],.string(body)); XCTAssertEqual(imported["source_ids"],refs); XCTAssertEqual(imported["status"],.string("verified"))
        let export = try directory(); _ = try call(db,"markdown.export",["path":.string(export.path)])
        let peer = try store(), peerSpace = try space(peer)
        // URLs remain portable; internal IDs are preserved as metadata in a human import.
        _ = try call(peer,"markdown.import",["path":.string(export.path),"space_id":peerSpace])
        let restored = try XCTUnwrap(try peer.all("note").first{$0["title"] == imported["title"]})
        XCTAssertEqual(restored["body"],imported["body"]); XCTAssertEqual(restored["source_ids"],refs); XCTAssertEqual(restored["status"],imported["status"])
    }
    func testMarkdownReimportUpdatesMetadataOnceAndPreservesAbsentSources() throws {
        let db = try store(), sid = try space(db), vault = try directory()
        var meta: [String:JSONValue] = ["title":.string("Evidence"),"source_ids":.array([.string("https://example.org/old")])]
        try markdownFixture(vault,metadata:meta)
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        let first = try XCTUnwrap(try db.all("note").first), id = first["id"]
        meta["source_ids"] = .array([.string("https://example.org/new")]); meta["status"] = .string("verified")
        try markdownFixture(vault,metadata:meta)
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        let changed = try call(db,"read",["id":id])
        XCTAssertEqual(changed["source_ids"],meta["source_ids"]); XCTAssertEqual(changed["status"],.string("verified")); XCTAssertNotEqual(changed["revision_id"],first["revision_id"])
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        XCTAssertEqual(try call(db,"read",["id":id])["revision_id"],changed["revision_id"])
        meta.removeValue(forKey:"source_ids"); try markdownFixture(vault,metadata:meta,body:"Changed body")
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        XCTAssertEqual(try call(db,"read",["id":id])["source_ids"],changed["source_ids"])
        meta["source_ids"] = .array([]); try markdownFixture(vault,metadata:meta,body:"Changed body")
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        XCTAssertEqual(try call(db,"read",["id":id])["source_ids"],.array([])); XCTAssertEqual(try db.all("note").count,1)
    }
    func testMarkdownInvalidSourceMetadataRollsBackAndCanRetry() throws {
        for invalid: JSONValue in [.string("not-an-array"),.array([.number(7)])] {
            let db = try store(), sid = try space(db), vault = try directory()
            try Data("First body".utf8).write(to:vault.appendingPathComponent("A.md"))
            try markdownFixture(vault,metadata:["source_ids":invalid])
            XCTAssertThrowsError(try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])) { XCTAssertEqual(($0 as? MioError)?.code,"invalid_params") }
            XCTAssertEqual(try db.all("note").count,0)
            try markdownFixture(vault,metadata:["source_ids":.array([])])
            XCTAssertEqual(try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])["imported_notes"],.number(2))
        }
    }
    func testMarkdownReimportWithoutStatusPreservesUserStatus() throws {
        let db = try store(), sid = try space(db), vault = try directory()
        try Data("Original body".utf8).write(to:vault.appendingPathComponent("Evidence.md"))
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        let first = try XCTUnwrap(try db.all("note").first)
        let edited = try call(db,"note.update",["note_id":first["id"],"expected_revision":first["revision_id"],"status":.string("confirmed")])
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        XCTAssertEqual(try call(db,"read",["id":first["id"]])["revision_id"],edited["revision_id"])
        try Data("Updated body".utf8).write(to:vault.appendingPathComponent("Evidence.md"))
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        XCTAssertEqual(try call(db,"read",["id":first["id"]])["status"],.string("confirmed"))
    }
    func testMarkdownConflictedMetadataUpdateFailsWithoutNewRevision() throws {
        let db = try store(), sid = try space(db), vault = try directory()
        try markdownFixture(vault,metadata:["source_ids":.array([.string("https://example.org/old")])])
        _ = try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])
        let first = try XCTUnwrap(try db.all("note").first)
        _ = try call(db,"note.update",["note_id":first["id"],"expected_revision":first["revision_id"],"body":.string("User edit")])
        XCTAssertThrowsError(try call(db,"note.update",["note_id":first["id"],"expected_revision":first["revision_id"],"body":.string("Other edit")]))
        let before = try call(db,"note.history",["note_id":first["id"]])
        try markdownFixture(vault,metadata:["source_ids":.array([.string("https://example.org/new")])])
        XCTAssertThrowsError(try call(db,"markdown.import",["path":.string(vault.path),"space_id":sid])) { XCTAssertEqual(($0 as? MioError)?.code,"revision_conflict") }
        XCTAssertEqual(try call(db,"note.history",["note_id":first["id"]]),before)
    }
}
