import XCTest
import Foundation
@testable import MioCore

extension MioCoreTests {
    func testSpaceDragOrderNestingRestartAndReplica() throws {
        let db=try store(),a=try space(db,"Alpha"),b=try space(db,"Beta"),c=try space(db,"Gamma")
        let note=try call(db,"note.create",["space_id":b,"title":.string("Kept"),"body":.string("Exact evidence")])
        let profile=try call(db,"profile.create",["space_id":a,"name":.string("Scoped")]),ctx=AccessContext.agent(token:profile["token"].stringValue!)
        _=try call(db,"space.move",["space_id":c,"parent_id":.null,"before_space_id":a])
        func ids(_ store: MioStore) throws -> [JSONValue] { MioSpaceTree(spaces:try call(store,"snapshot")["spaces"].arrayValue).entries.map{$0.space["id"]} }
        XCTAssertEqual(try ids(db),[c,a,b])
        _=try call(db,"space.move",["space_id":b,"parent_id":a,"before_space_id":.null])
        XCTAssertEqual(try ids(db),[c,a,b])
        let catalog=try call(db,"read",["kind":.string("spaces")])
        XCTAssertEqual(catalog["spaces"].arrayValue.first{$0["id"]==b}?["parent_id"],a)
        XCTAssertEqual(try call(db,"read",["kind":.string("spaces")],ctx)["spaces"].arrayValue.map{$0["id"]},[a])
        XCTAssertEqual(try call(db,"read",["kind":.string("note"),"id":note["id"]])["revision_id"],note["revision_id"])
        let reopened=try MioStore(directory:db.directory);XCTAssertEqual(try ids(reopened),[c,a,b])
        let peer=try store();_=try call(peer,"replica.merge",["document":try call(db,"replica.export")])
        XCTAssertEqual(try ids(peer),[c,a,b])
        _=try call(db,"space.move",["space_id":b,"parent_id":.null,"before_space_id":c])
        XCTAssertEqual(try ids(db),[b,c,a])
        let before=try call(db,"snapshot")["spaces"]
        XCTAssertThrowsError(try call(db,"space.move",["space_id":a,"parent_id":b,"before_space_id":c]))
        XCTAssertEqual(try call(db,"snapshot")["spaces"],before)
        XCTAssertThrowsError(try call(db,"space.move",["space_id":a,"parent_id":a]))
        XCTAssertThrowsError(try call(db,"space.move",["space_id":b,"parent_id":.null],ctx))
    }
    func testCustomColorSurvivesReplicaAndCatalog() throws {
        let db=try store(),s=try call(db,"space.create",["name":.string("Custom"),"color":.string("#8F36D9")])["id"]
        let peer=try store();_=try call(peer,"replica.merge",["document":try call(db,"replica.export")])
        XCTAssertEqual(try call(peer,"read",["kind":.string("spaces")])["spaces"].arrayValue.first{$0["id"]==s}?["color"],.string("#8F36D9"))
    }
}
