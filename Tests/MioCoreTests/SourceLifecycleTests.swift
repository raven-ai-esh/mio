import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import MioCore

final class SourceLifecycleTests: XCTestCase {
    var directory:URL!,store:MioStore!
    override func setUpWithError() throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent("mio-source-lifecycle-"+UUID().uuidString);store=try MioStore(directory:directory) }
    override func tearDownWithError() throws { store=nil;try FileManager.default.removeItem(at:directory) }
    func call(_ m:String,_ p:[String:JSONValue]=[:],_ c:AccessContext = .human)throws->JSONValue { try store.execute(m,params:p,context:c) }
    func space(_ name:String)throws->JSONValue { try call("space.create",["name":.string(name)])["id"] }
    func fixture(_ name:String)throws->Data { try Data(contentsOf:Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Hybrid/"+name)) }
    func file(_ space:JSONValue,_ name:String = "record-01.pdf",body:String="annotation")throws->JSONValue {
        try call("note.create",["space_id":space,"title":.string("Original record"),"body":.string(body),"file_name":.string(name),"mime_type":.string(name.hasSuffix("pdf") ? "application/pdf":"image/png"),"file_base64":.string(try fixture(name).base64EncodedString()),"idempotency_key":.string(UUID().uuidString)])
    }
    func indexLexical()throws {
        while let job=try store.nextSourceIndexJob(modelID:"lexical-native-v1") {
            let bytes=Data(base64Encoded:job["file"]["bytes"].stringValue ?? "")!
            let fragments=job["file"] == .null ? []:try MioDocumentExtraction.fragments(file:job["file"],bytes:bytes)
            XCTAssertTrue(try store.publishSourceIndex(job:job,documents:store.sourceDocuments(job:job,fileFragments:fragments)))
        }
    }
    func testRealPDFAndOCRRemainSearchableWithoutModelAndSurviveFTSRebuild() throws {
        let s=try space("Sources"),pdf=try file(s),image=try file(s,"record-02.png",body:"annotation_unique")
        try indexLexical();store.configureSourceImages{try MioDocumentExtraction.preview(file:$0,bytes:$1,locator:$2)}
        let hit=try XCTUnwrap(try call("search",["query":.string("cancellation costs"),"scope":.string("files")])["results"].arrayValue.first)
        XCTAssertEqual(hit["id"],pdf["id"]);XCTAssertEqual(hit["locator"]["page"],.number(2))
        let source=try call("read",["kind":.string("source"),"id":hit["source_id"]]);XCTAssertTrue(source["text"].stringValue!.contains("costs one night"))
        let ocr=try XCTUnwrap(try call("search",["query":.string("quiet hours"),"scope":.string("files")])["results"].arrayValue.first)
        XCTAssertEqual(ocr["id"],image["id"])
        let text=try call("read",["kind":.string("source"),"id":ocr["source_id"]]);XCTAssertTrue(text["text"].stringValue!.contains("07:00"));XCTAssertEqual(text["locator"]["line_boxes"].arrayValue.count,3)
        XCTAssertEqual(try call("search",["query":.string("annotation_unique"),"scope":.string("files")])["results"].arrayValue.first?["id"],image["id"])
        _=try call("search.rebuild")
        XCTAssertEqual(try call("search",["query":.string("cancellation costs"),"scope":.string("files")])["results"].arrayValue.first?["source_id"],hit["source_id"])
        let preview=try call("read",["kind":.string("source"),"id":pdf["file_id"],"offset":.number(1)])
        let data=try XCTUnwrap(Data(base64Encoded:preview["media"]["data"].stringValue!))
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData,nil));XCTAssertEqual(preview["page_count"],.number(3));XCTAssertLessThan(data.count,4_000_000)
    }
    func testLateOldModelCannotOverwriteNewJobAndSourcesGroupOnce() throws {
        let s=try space("Generation"),_=try file(s),old=try XCTUnwrap(try store.nextSourceIndexJob(modelID:"old-model"))
        let fragments=try MioDocumentExtraction.fragments(file:old["file"],bytes:Data(base64Encoded:old["file"]["bytes"].stringValue!)!)
        let oldDocs=try store.sourceDocuments(job:old,fileFragments:fragments),new=try XCTUnwrap(try store.nextSourceIndexJob(modelID:"lexical-native-v1")),docs=try store.sourceDocuments(job:new,fileFragments:fragments)
        XCTAssertTrue(try store.publishSourceIndex(job:new,documents:docs))
        var v=Array(repeating:Float(0),count:768);v[0]=1
        XCTAssertFalse(try store.publishSourceIndex(job:old,documents:oldDocs,embeddings:oldDocs.map{_ in v}))
        let result=try call("search",["query":.string("Willow House"),"scope":.string("files")])
        XCTAssertEqual(result["results"].arrayValue.count,1);XCTAssertLessThanOrEqual(result["results"].arrayValue[0]["supporting_sources"].arrayValue.count,2)
    }
    func testExactFragmentCitationAndPurgeCascadeLeaveOtherSameBytesIntact() throws {
        let a=try space("A"),b=try space("B"),p=try call("profile.create",["space_id":a,"name":.string("agent")]),context=AccessContext.agent(token:p["token"].stringValue!)
        let trace=try call("search",["query":.string("source witness")],context),sessionID=trace["interaction_session_id"]
        let original=try file(a,body:"sensitive_annotation"),other=try file(b)
        try indexLexical()
        let first=try XCTUnwrap(try call("search",["query":.string("cancellation costs"),"scope":.string("files"),"space_ids":.array([a])])["results"].arrayValue.first)
        let derived=try call("note.create",["space_id":a,"title":.string("Derived fact"),"body":.string("SENSITIVE_DERIVED_FRAGMENT"),"source_ids":.array([first["source_id"]])],context)
        let before=try call("replica.export")
        _=try call("interaction.session.end",["_mio_interaction":.object(["transport_session_id":try call("read",["kind":.string("session"),"id":sessionID])["transport_session_id"]])],context)
        _=try call("history.purge",["session_id":sessionID,"note_ids":.array([original["id"]])])
        XCTAssertEqual(try store.entity("note",derived["id"].stringValue!)?["status"],.string("purged"))
        XCTAssertThrowsError(try call("read",["kind":.string("source"),"id":first["source_id"]]))
        XCTAssertEqual(try store.db.rows("SELECT id FROM source_fragments WHERE note_id=?",[original["id"].stringValue!]).count,0)
        _=try call("replica.merge",["document":before])
        XCTAssertEqual(try store.entity("attachment",original["file_id"].stringValue!)?["bytes"],.string(""))
        XCTAssertEqual(try call("read",["kind":.string("source"),"id":other["file_id"]])["sha256"],.string(store.hash(try fixture("record-01.pdf"))))
        XCTAssertFalse(try store.db.rows("SELECT json FROM idempotency").contains{$0["json"]!.contains("sensitive_annotation")})
    }
    func testLegacyAttachmentDemotionAndHistoricalScopeDoNotLeakTextNotes() throws {
        let s=try space("History"),n=try file(s,body:"exact marker"),_=try call("note.create",["space_id":s,"title":.string("ordinary"),"body":.string("exact marker")])
        let historical=try call("search",["query":.string("exact marker"),"scope":.string("files"),"as_of":.string("9999-01-01T00:00:00Z")])
        XCTAssertEqual(historical["results"].arrayValue.count,1);XCTAssertEqual(historical["results"].arrayValue[0]["id"],n["id"]);XCTAssertNotEqual(historical["file_search_state"],.null)
        let doc=try call("replica.export"),record=try XCTUnwrap(doc["records"].arrayValue.first{$0["kind"] == .string("attachment")})
        var changed=record.objectValue;changed["id"] = .string(UUID().uuidString);changed.removeValue(forKey:"content_hash")
        var payload=record["data"].objectValue;payload.removeValue(forKey:"kind");changed["data"] = .object(payload)
        changed["content_hash"] = .string(store.hash(try JSONValue.object(changed).encoded()))
        var broken=doc.objectValue;broken["records"] = .array([.object(changed)])
        XCTAssertThrowsError(try call("replica.merge",["document":.object(broken)]))
    }
    func testRotatedPDFPreviewUsesDisplayedOrientation() throws {
        let document=try XCTUnwrap(PDFDocument(data:fixture("record-01.pdf")));document.page(at:0)!.rotation=90
        let original=try XCTUnwrap(document.dataRepresentation()),file=JSONValue.object(["mime_type":.string("application/pdf")])
        let preview=try MioDocumentExtraction.preview(file:file,bytes:original,locator:.object(["page":.number(1)]))
        let source=try XCTUnwrap(CGImageSourceCreateWithData(preview as CFData,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertLessThan(image.width,image.height,"A rotated landscape page is displayed in portrait orientation")
        if let output=ProcessInfo.processInfo.environment["MIO_SOURCE_TEST_OUTPUT"] { let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try preview.write(to:directory.appendingPathComponent("rotated-page.png")) }
    }
    func testHighEntropyImageGetsBoundedPreviewWithoutLosingOriginal() throws {
        let width=1400,height=1400
        var pixels=[UInt8](repeating:0,count:width*height*4),state:UInt32=1729
        for i in pixels.indices { if i%4==3 { pixels[i]=255 } else { state=1664525 &* state &+ 1013904223;pixels[i]=UInt8(truncatingIfNeeded:state>>24) } }
        let data=Data(pixels),provider=CGDataProvider(data:data as CFData)!
        let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let original=NSMutableData(),encoder=CGImageDestinationCreateWithData(original,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(encoder,image,nil);XCTAssertTrue(CGImageDestinationFinalize(encoder));XCTAssertGreaterThan(original.length,4_000_000)
        let s=try space("Large image"),capture=try call("note.create",["space_id":s,"title":.string("High entropy image"),"file_name":.string("noise.png"),"mime_type":.string("image/png"),"file_base64":.string((original as Data).base64EncodedString())])
        store.configureSourceImages {try MioDocumentExtraction.preview(file:$0,bytes:$1,locator:$2)}
        let result=try call("read",["kind":.string("source"),"id":capture["file_id"]]),preview=try XCTUnwrap(Data(base64Encoded:result["media"]["data"].stringValue!))
        XCTAssertLessThanOrEqual(preview.count,4_000_000);XCTAssertEqual(result["sha256"],.string(store.hash(original as Data)))
    }
}
