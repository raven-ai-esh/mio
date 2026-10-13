import XCTest
import Foundation
import CoreGraphics
import CoreText
@testable import MioCore

final class FileMemoryTests: XCTestCase {
    var root: URL!
    var store: MioStore!
    override func setUpWithError() throws { root=FileManager.default.temporaryDirectory.appendingPathComponent("mio-files-"+UUID().uuidString);store=try MioStore(directory:root) }
    override func tearDownWithError() throws { store=nil;try FileManager.default.removeItem(at:root) }
    func call(_ m:String,_ p:[String:JSONValue]=[:],_ c:AccessContext = .human)throws->JSONValue { try store.execute(m,params:p,context:c) }
    func space(_ name:String)throws->JSONValue { try call("space.create",["name":.string(name)])["id"] }
    func pdf(_ text:String = "The cancellation window closes seven days before arrival.") -> Data {
        let bytes=NSMutableData();let consumer=CGDataConsumer(data:bytes as CFMutableData)!
        var box=CGRect(x:0,y:0,width:500,height:500);let context=CGContext(consumer:consumer,mediaBox:&box,nil)!
        context.beginPDFPage(nil);context.textPosition=CGPoint(x:30,y:450)
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.init(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,12,nil)]))
        CTLineDraw(line,context);context.endPDFPage();context.closePDF();return bytes as Data
    }
    func capture(_ s:JSONValue,_ data:Data,_ key:String = "file")throws->JSONValue { try call("note.create",["space_id":s,"title":.string("Policy PDF"),"body":.string("Original policy"),"file_name":.string("policy.pdf"),"mime_type":.string("application/pdf"),"file_base64":.string(data.base64EncodedString()),"idempotency_key":.string(key)]) }
    func testCapturedOriginalIsBoundToGraphNoteAndReplicaWithNoDuplicateOnRetry() throws {
        let s=try space("Files"),data=pdf(),n=try capture(s,data)
        XCTAssertEqual(n["file_id"],n["note"]["file_ids"].arrayValue.first)
        XCTAssertNotEqual(n["file_id"],.null)
        let source=try call("read",["kind":.string("source"),"id":n["file_id"]])
        XCTAssertEqual(source["note_id"],n["id"]);XCTAssertEqual(source["sha256"],.string(store.hash(data)));XCTAssertEqual(source["mime_type"],.string("application/pdf"));XCTAssertEqual(source["byte_count"],.number(Double(data.count)))
        XCTAssertEqual(source["bytes"],.null)
        XCTAssertEqual(try capture(s,data)["id"],n["id"])
        let attachments=try call("replica.export")["records"].arrayValue.filter{$0["kind"] == .string("attachment")}
        XCTAssertEqual(attachments.count,1);XCTAssertEqual(Data(base64Encoded:attachments[0]["data"]["bytes"].stringValue!),data)
    }
    func testInvalidMimeBytesOrUnsafeNameLeaveNoPartialCapture() throws {
        let s=try space("Invalid")
        let count=try call("snapshot")["counts"]["notes"]
        XCTAssertThrowsError(try capture(s,Data("not a PDF".utf8)))
        XCTAssertThrowsError(try call("note.create",["space_id":s,"title":.string("Bad"),"file_name":.string("../escape.pdf"),"mime_type":.string("application/pdf"),"file_base64":.string(pdf().base64EncodedString())]))
        XCTAssertEqual(try call("snapshot")["counts"]["notes"],count);XCTAssertEqual(try store.all("attachment").count,0)
    }
    func testSourceAccessFollowsParentNoteGrantDeletionAndRestore() throws {
        let a=try space("A"),b=try space("B"),data=pdf(),n=try capture(b,data)
        let p=try call("profile.create",["space_id":a,"name":.string("reader")]),c=AccessContext.agent(token:p["token"].stringValue!)
        XCTAssertThrowsError(try call("read",["kind":.string("source"),"id":n["file_id"]],c))
        let mount=try call("connection.create",["from_space_id":a,"to_space_id":b,"access":.string("read")])
        XCTAssertEqual(try call("read",["kind":.string("source"),"id":n["file_id"]],c)["note_id"],n["id"])
        _=try call("note.delete",["note_id":n["id"]]);XCTAssertThrowsError(try call("read",["kind":.string("source"),"id":n["file_id"]],c))
        _=try call("note.restore",["note_id":n["id"],"revision_id":n["revision_id"]])
        XCTAssertEqual(try call("read",["kind":.string("source"),"id":n["file_id"]],c)["sha256"],.string(store.hash(data)))
        _=try call("connection.delete",["connection_id":mount["id"]]);XCTAssertThrowsError(try call("read",["kind":.string("source"),"id":n["file_id"]],c))
    }
    func testImmutableFileRetargetAndReplacementRejectedBeforeMerge() throws {
        let s=try space("Identity"),n=try capture(s,pdf()),doc=try call("replica.export")
        let original=try XCTUnwrap(doc["records"].arrayValue.first{$0["kind"] == .string("attachment")})
        var record=original.objectValue;record.removeValue(forKey:"content_hash");record["id"] = .string(UUID().uuidString)
        var data=record["data"]!.objectValue;data["note_id"] = .string(UUID().uuidString);record["data"] = .object(data)
        record["content_hash"] = .string(store.hash(try JSONValue.object(record).encoded()))
        var altered=doc.objectValue;altered["records"] = .array([.object(record)])
        XCTAssertThrowsError(try call("replica.merge",["document":.object(altered)]))
        XCTAssertEqual(try call("read",["kind":.string("source"),"id":n["file_id"]])["note_id"],n["id"])
    }
    func testPurgeErasesFileBytesAndOldReplicaCannotRestoreThem() throws {
        let s=try space("Purge"),profile=try call("profile.create",["space_id":s,"name":.string("agent")]),context=AccessContext.agent(token:profile["token"].stringValue!)
        let trace=try call("search",["query":.string("source witness")],context)
        let session=try call("read",["kind":.string("session"),"id":trace["interaction_session_id"]])
        let end=try XCTUnwrap(session["events"].arrayValue.first{$0["phase"] == .string("end")})
        var p:[String:JSONValue] = ["space_id":s,"title":.string("Sensitive PDF"),"body":.string("Derived annotation"),"file_name":.string("SENSITIVE_FILENAME.pdf"),"mime_type":.string("application/pdf"),"file_base64":.string(pdf("SENSITIVE_FILE_TEXT").base64EncodedString()),"source_ids":.array([end["id"]])]
        p["idempotency_key"] = .string("sensitive")
        let n=try call("note.create",p),old=try call("replica.export")
        _=try call("interaction.session.end",["_mio_interaction":.object(["transport_session_id":session["transport_session_id"]])],context)
        _=try call("history.purge",["session_id":session["id"]])
        XCTAssertThrowsError(try call("read",["kind":.string("source"),"id":n["file_id"]]))
        let before=try call("replica.export"),file=try XCTUnwrap(before["records"].arrayValue.first{$0["kind"] == .string("attachment")})
        XCTAssertEqual(file["data"]["bytes"],.string(""));XCTAssertTrue(file["data"]["purged"].boolValue)
        XCTAssertFalse(String(decoding:try before.encoded(),as:UTF8.self).contains("SENSITIVE_FILENAME"))
        _=try call("replica.merge",["document":old])
        XCTAssertEqual(try store.entity("attachment",n["file_id"].stringValue!)?["bytes"],.string(""))
    }
}
