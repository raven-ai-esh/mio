import XCTest
import Foundation
@testable import MioCore

extension MioCoreTests {
    func testSpaceDetailsHierarchyAndScopedCatalog() throws {
        let db=try store(),parent=try space(db,"Personal")
        let child=try call(db,"space.create",["name":.string("Genealogy"),"description":.string("Family research"),"color":.string("purple"),"parent_id":parent])["id"]
        let profile=try call(db,"profile.create",["space_id":parent,"name":.string("Personal agent")]),ctx=AccessContext.agent(token:profile["token"].stringValue!)
        XCTAssertEqual(try call(db,"read",["kind":.string("spaces")],ctx)["spaces"].arrayValue.map{$0["id"]},[parent])
        _=try call(db,"connection.create",["from_space_id":parent,"to_space_id":child,"access":.string("read")])
        let catalog=try call(db,"read",["kind":.string("spaces")],ctx)
        let entry=try XCTUnwrap(catalog["spaces"].arrayValue.first{$0["id"]==child})
        XCTAssertEqual(entry["parent_id"],parent);XCTAssertEqual(entry["description"],.string("Family research"));XCTAssertEqual(entry["color"],.string("purple"))
        XCTAssertEqual(entry["path"].arrayValue.map{$0["id"]},[parent,child])
        XCTAssertEqual(catalog["connections"].arrayValue.first?["to_space_id"],child)
        XCTAssertFalse(entry["can_write"].boolValue)
        _=try call(db,"space.update",["space_id":child,"name":.string("Family"),"description":.string("Updated research"),"color":.string("green")])
        let changed=try call(db,"read",["kind":.string("spaces")],ctx)["spaces"].arrayValue.first{$0["id"]==child}!
        XCTAssertEqual(changed["name"],.string("Family"));XCTAssertEqual(changed["description"],.string("Updated research"));XCTAssertEqual(changed["color"],.string("green"));XCTAssertEqual(changed["parent_id"],parent)
        XCTAssertThrowsError(try call(db,"space.update",["space_id":child,"name":.string("Not allowed")],ctx))
    }
    func testHierarchyValidationAndHiddenParentMetadata() throws {
        let db=try store(),parent=try space(db,"HIDDEN_PARENT"),child=try call(db,"space.create",["name":.string("Visible child"),"parent_id":parent])["id"]
        let profile=try call(db,"profile.create",["space_id":child,"name":.string("Child agent")]),ctx=AccessContext.agent(token:profile["token"].stringValue!)
        let scoped=try call(db,"read",["kind":.string("spaces")],ctx)
        XCTAssertEqual(scoped["spaces"].arrayValue.first?["parent_id"],.null)
        XCTAssertFalse(String(decoding:try scoped.encoded(),as:UTF8.self).contains("HIDDEN_PARENT"));XCTAssertFalse(String(decoding:try scoped.encoded(),as:UTF8.self).contains(parent.stringValue!))
        for params:[String:JSONValue] in [["space_id":parent,"parent_id":child],["space_id":child,"parent_id":child],["space_id":child,"parent_id":.string("missing")],["space_id":child,"name":.string("  ")]] {
            XCTAssertThrowsError(try call(db,"space.update",params))
        }
        let after=try call(db,"read",["kind":.string("spaces")])["spaces"].arrayValue.first{$0["id"]==parent}!
        XCTAssertEqual(after["parent_id"],.null)
        _=try call(db,"space.update",["space_id":child,"parent_id":.null])
        XCTAssertEqual(try call(db,"read",["kind":.string("spaces")])["spaces"].arrayValue.first{$0["id"]==child}?["parent_id"],.null)
    }
}
