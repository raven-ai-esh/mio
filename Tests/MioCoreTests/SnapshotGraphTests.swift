import XCTest
import Foundation
@testable import MioCore

extension MioCoreTests {
    func testOwnerSnapshotGraphDoesNotDecodeBodiesForEveryEdge() throws {
        let db = try store(), sid = try space(db), a = try note(db,sid,"Large A",String(repeating:"large evidence ",count:35000)), b = try note(db,sid,"Large B",String(repeating:"second evidence ",count:35000))
        for index in 0..<6000 {
            try db.put("link",.object(["id":.string("edge-\(index)"),"space_id":sid,"from_note_id":a["id"],"to_note_id":b["id"],"kind":.string("relation-\(index)"),"deleted":.bool(false)]))
        }
        let started = Date(), snapshot = try call(db,"snapshot",["projection":.string("compact")])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(snapshot["links"].arrayValue.count,6000)
        XCTAssertTrue(snapshot["notes"].arrayValue.allSatisfy{$0["body"] == .null && $0["body_omitted"].boolValue})
        XCTAssertLessThan(elapsed,2,"Metadata-only owner snapshot repeatedly decoded large note bodies: \(elapsed)s")
    }
    func testSnapshotGraphRetainsEndpointAndSpaceAccessBoundaries() throws {
        let db = try store(), a = try space(db,"Allowed"), b = try space(db,"Other"), c = try space(db,"Deleted space")
        let one = try note(db,a,"One"), two = try note(db,a,"Two"), hidden = try note(db,b,"Hidden"), deleted = try note(db,a,"Deleted"), retired = try note(db,c,"Retired")
        let edges:[(String,JSONValue,JSONValue,Bool)] = [("live",one["id"],two["id"],false),("cross",one["id"],hidden["id"],false),("deleted-note",one["id"],deleted["id"],false),("deleted-space",one["id"],retired["id"],false),("missing",one["id"],.string("missing-note"),false),("tombstone",one["id"],two["id"],true)]
        for (id,from,to,removed) in edges { try db.put("link",.object(["id":.string(id),"space_id":a,"from_note_id":from,"to_note_id":to,"kind":.string("related"),"deleted":.bool(removed)])) }
        _ = try call(db,"note.delete",["note_id":deleted["id"]]); _ = try call(db,"space.delete",["space_id":c])
        let profile = try call(db,"profile.create",["space_id":a,"name":.string("Scoped")]), context = AccessContext.agent(token:profile["token"].stringValue!)
        for projection in ["compact","full"] {
            let owner = try call(db,"snapshot",["projection":.string(projection)]), agent = try call(db,"snapshot",["projection":.string(projection)],context)
            XCTAssertEqual(Set(owner["links"].arrayValue.compactMap{$0["id"].stringValue}),Set(["live","cross","tombstone"]))
            XCTAssertEqual(agent["links"].arrayValue.map{$0["id"]},[.string("live")])
            XCTAssertFalse(String(decoding:try agent.encoded(),as:UTF8.self).contains(hidden["id"].stringValue!))
        }
    }
}
