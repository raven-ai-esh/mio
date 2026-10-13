import XCTest
import Foundation
@testable import MioCore

final class SpaceCatalogTests: XCTestCase {
    var root: URL!
    var store: MioStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mio-space-catalog-" + UUID().uuidString)
        store = try MioStore(directory: root)
    }
    override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: root) }
    func call(_ method: String, _ params: [String:JSONValue] = [:], _ context: AccessContext = .human) throws -> JSONValue { try store.execute(method,params:params,context:context) }
    func space(_ name: String) throws -> JSONValue { try call("space.create",["name":.string(name)])["id"] }
    func mount(_ from: JSONValue, _ to: JSONValue, _ access: String) throws -> JSONValue { try call("connection.create",["from_space_id":from,"to_space_id":to,"access":.string(access)]) }
    func agent(_ home: JSONValue) throws -> (JSONValue,AccessContext) {
        let profile = try call("profile.create",["name":.string("Catalog agent"),"space_id":home])
        return (profile,.agent(token:profile["token"].stringValue!))
    }
    func catalog(_ context: AccessContext = .human, _ extra: [String:JSONValue] = [:]) throws -> JSONValue {
        var p = extra; p["kind"] = .string("spaces"); return try call("read",p,context)
    }
    func assertError(_ code: String, _ operation: () throws -> JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(),file:file,line:line) { XCTAssertEqual(($0 as? MioError)?.code,code,file:file,line:line) }
    }

    func testCatalogUsesCurrentProfilePermissionsAndNeverChainsOrLeaks() throws {
        let home = try space("Home"), read = try space("Shared"), write = try space("Shared"), hidden = try space("PRIVATE_NAME"), deleted = try space("DELETED_NAME")
        _ = try mount(home,read,"read"); _ = try mount(home,write,"write"); _ = try mount(read,hidden,"write"); _ = try mount(home,deleted,"read")
        _ = try call("space.delete",["space_id":deleted])
        let (profile,context) = try agent(home), value = try catalog(context), rows = value["spaces"].arrayValue
        XCTAssertEqual(rows.compactMap{$0["id"].stringValue}.sorted(),[home,read,write].compactMap(\.stringValue).sorted()); XCTAssertEqual(value["default_space_id"],home)
        XCTAssertEqual(value["total_count"],.number(3)); XCTAssertEqual(value["next_offset"],.null)
        XCTAssertEqual(rows.filter{$0["name"] == .string("Shared")}.count,2)
        XCTAssertTrue(rows.allSatisfy{$0["can_read"].boolValue})
        XCTAssertFalse(rows.first{$0["id"] == read}!["can_write"].boolValue)
        XCTAssertTrue(rows.first{$0["id"] == write}!["can_write"].boolValue)
        let encoded = String(decoding:try value.encoded(),as:UTF8.self)
        for text in ["PRIVATE_NAME","DELETED_NAME","token_hash",profile["token"].stringValue!] { XCTAssertFalse(encoded.contains(text)) }
        _ = try call("profile.revoke",["profile_id":profile["id"]])
        assertError("unauthorized") { try self.catalog(context) }
    }

    func testEmptyCatalogStablePaginationAndBounds() throws {
        let empty = try catalog(); XCTAssertEqual(empty["spaces"],.array([])); XCTAssertEqual(empty["total_count"],.number(0)); XCTAssertEqual(empty["default_space_id"],.null)
        _ = try space("B"); _ = try space("A"); _ = try space("A")
        let all = try catalog()["spaces"].arrayValue
        XCTAssertEqual(all.map{$0["name"]},[.string("A"),.string("A"),.string("B")])
        XCTAssertLessThan(all[0]["id"].stringValue!,all[1]["id"].stringValue!)
        let first = try catalog(.human,["limit":.number(2)])
        XCTAssertEqual(first["spaces"],.array(Array(all.prefix(2)))); XCTAssertEqual(first["next_offset"],.number(2))
        let last = try catalog(.human,["offset":first["next_offset"],"limit":.number(2)])
        XCTAssertEqual(last["spaces"],.array(Array(all.suffix(1)))); XCTAssertEqual(last["next_offset"],.null)
        XCTAssertEqual(try catalog(.human,["offset":.number(999)])["spaces"],.array([]))
        XCTAssertEqual(try catalog(.human,["limit":.number(999)])["limit"],.number(200))
        XCTAssertEqual(try catalog(.human,["limit":.number(0)])["spaces"].arrayValue.count,1)
        assertError("invalid_params") { try self.call("read",["kind":.string("note")]) }
    }

    func testFreshCatalogReflectsRenameGrantRemovalAndCachedReplyCannotLie() throws {
        let home = try space("Home"), shared = try space("Old name"), (_,context) = try agent(home)
        let connection = try mount(home,shared,"write")
        let params: [String:JSONValue] = ["_mio_interaction":.object(["transport_session_id":.string(UUID().uuidString),"request_id":.string("catalog")])]
        let initial = try catalog(context,params)
        XCTAssertEqual(try catalog(context,params)["spaces"],initial["spaces"])
        _ = try call("space.rename",["space_id":shared,"name":.string("New name")])
        assertError("catalog_changed") { try self.catalog(context,params) }
        XCTAssertEqual(try catalog(context)["spaces"].arrayValue.first{$0["id"] == shared}?["name"],.string("New name"))
        let cachedWrite: [String:JSONValue] = ["_mio_interaction":.object(["transport_session_id":.string(UUID().uuidString),"request_id":.string("write-catalog")])]
        _ = try catalog(context,cachedWrite)
        _ = try call("connection.delete",["connection_id":connection["id"]]); let read = try mount(home,shared,"read")
        assertError("catalog_changed") { try self.catalog(context,cachedWrite) }
        XCTAssertFalse(try catalog(context)["spaces"].arrayValue.first{$0["id"] == shared}!["can_write"].boolValue)
        _ = try call("connection.delete",["connection_id":read["id"]])
        XCTAssertEqual(try catalog(context)["spaces"].arrayValue.map{$0["id"]},[home])
        assertError("forbidden") { try self.catalog(context,params) }
    }

    func testCatalogHistoryIsScopedToEveryDisclosedSpace() throws {
        let home = try space("Home"), shared = try space("Shared"), (_,context) = try agent(home), mount = try mount(home,shared,"read")
        let value = try catalog(context,["limit":.number(1)])
        let event = try XCTUnwrap(try call("snapshot")["events"].arrayValue.first{$0["interaction_id"] == value["interaction_id"] && $0["phase"] == .string("end")})
        XCTAssertTrue(event["required_space_ids"].arrayValue.contains(shared))
        XCTAssertEqual(event["request"]["kind"],.string("spaces")); XCTAssertEqual(event["result_count"],.number(1))
        XCTAssertEqual(event["result_refs"].arrayValue.first?["kind"],.string("space"))
        _ = try call("connection.delete",["connection_id":mount["id"]])
        assertError("forbidden") { try self.call("read",["kind":.string("event"),"id":event["id"]],context) }
    }
}
