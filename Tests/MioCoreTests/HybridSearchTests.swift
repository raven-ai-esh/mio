import XCTest
@testable import MioCore

final class HybridSearchTests: XCTestCase {
    var root: URL!
    var db: MioStore!
    let model="test-model"
    override func setUpWithError() throws { root=FileManager.default.temporaryDirectory.appendingPathComponent("mio-hybrid-"+UUID().uuidString);db=try MioStore(directory:root) }
    override func tearDownWithError() throws { db=nil;try FileManager.default.removeItem(at:root) }
    func call(_ m:String,_ p:[String:JSONValue]=[:],_ c:AccessContext = .human)throws->JSONValue { try db.execute(m,params:p,context:c) }
    func vector(_ index:Int)->[Float] { var x=Array(repeating:Float(0),count:768);x[index]=1;return x }
    func space(_ name:String)throws->JSONValue { try call("space.create",["name":.string(name)])["id"] }
    func note(_ s:JSONValue,_ title:String,_ text:String)throws->JSONValue { try call("note.create",["space_id":s,"title":.string(title),"body":.string(text)]) }
    func configure() { db.configureSemanticSearch(queryEncoder:{_ in MioSemanticQuery(modelID:self.model,values:self.vector(0))},imageRenderer:{_,_,_ in Data()}) }
    func indexAll()throws {
        while let job=try db.nextSourceIndexJob(modelID:model) {
            let docs=try db.sourceDocuments(job:job)
            let values=docs.map{$0["text"].stringValue?.contains("weather")==true ? vector(1):vector(0)}
            XCTAssertTrue(try db.publishSourceIndex(job:job,documents:docs,embeddings:values))
        }
    }
    func testHybridFindsParaphraseAndExactSourceWithNoDuplicateWholeNote() throws {
        let s=try space("Knowledge"),answer=try note(s,"Integrity","Compare the SHA-256 checksum with the original."),_=try note(s,"Weather","weather and temperature")
        try indexAll();configure()
        let results=try call("search",["query":.string("detect unexpected alterations"),"scope":.string("notes")])
        XCTAssertEqual(results["search_mode"],.string("bm25_embeddinggemma2_rrf"));XCTAssertEqual(results["results"].arrayValue.first?["id"],answer["id"])
        let matches=results["results"].arrayValue.filter{$0["id"]==answer["id"]};XCTAssertEqual(matches.count,1)
        let source=try call("read",["kind":.string("source"),"id":matches[0]["source_id"]])
        XCTAssertEqual(source["body"],.string("Compare the SHA-256 checksum with the original."));XCTAssertEqual(source["revision_id"],answer["revision_id"]);XCTAssertEqual(source["locator"]["utf16_start"],.number(0))
    }
    func testDenseAndLexicalCandidatesCannotRevealUnscopedSourcesOrStarveAllowedOnes() throws {
        let visible=try space("Visible"),hidden=try space("Hidden"),a=try note(visible,"Public","Public proof")
        for i in 0..<8 { _=try note(hidden,"PRIVATE_\(i)","Public proof exact repeated") }
        try indexAll();configure()
        let p=try call("profile.create",["space_id":visible,"name":.string("reader")]),c=AccessContext.agent(token:p["token"].stringValue!)
        let results=try call("search",["query":.string("Public proof"),"limit":.number(1)],c)
        XCTAssertEqual(results["results"].arrayValue.first?["id"],a["id"]);XCTAssertFalse(String(decoding:try results.encoded(),as:UTF8.self).contains("PRIVATE_"))
        let hiddenSource=try XCTUnwrap(try db.db.rows("SELECT id FROM source_fragments WHERE space_id=?",[hidden.stringValue!]).first?["id"])
        XCTAssertThrowsError(try call("read",["kind":.string("source"),"id":.string(hiddenSource)],c))
    }
    func testOldWorkerCannotPublishAfterRevisionChangeOrDeletion() throws {
        let s=try space("Races"),n=try note(s,"A","before"),job=try XCTUnwrap(try db.nextSourceIndexJob(modelID:model)),docs=try db.sourceDocuments(job:job)
        _=try call("note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("after")])
        XCTAssertFalse(try db.publishSourceIndex(job:job,documents:docs,embeddings:docs.map{_ in vector(0)}))
        let next=try XCTUnwrap(try db.nextSourceIndexJob(modelID:model)),fresh=try db.sourceDocuments(job:next)
        _=try call("note.delete",["note_id":n["id"]])
        XCTAssertFalse(try db.publishSourceIndex(job:next,documents:fresh,embeddings:fresh.map{_ in vector(0)}))
    }
    func testCurrentEditInvalidatesSearchButOldExactAnchorRemainsReadable() throws {
        let s=try space("Versions"),n=try note(s,"A","oldunique text")
        try indexAll();configure()
        let old=try XCTUnwrap(try call("search",["query":.string("oldunique"),"scope":.string("notes")])["results"].arrayValue.first)
        _=try call("note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("newunique text")])
        XCTAssertEqual(try call("search",["query":.string("oldunique"),"scope":.string("notes")])["results"],.array([]))
        XCTAssertEqual(try call("read",["kind":.string("source"),"id":old["source_id"]])["body"],.string("oldunique text"))
    }
    func testIndexAndEncoderFailuresAreExplicitAndInvalidVectorsDoNotPublish() throws {
        let s=try space("Errors"),_=try note(s,"A","local exact wording"),job=try XCTUnwrap(try db.nextSourceIndexJob(modelID:model)),docs=try db.sourceDocuments(job:job)
        XCTAssertThrowsError(try db.publishSourceIndex(job:job,documents:docs,embeddings:[Array(repeating:0,count:768)]))
        let pending=try call("search",["query":.string("exact")]);XCTAssertEqual(pending["semantic_state"],.string("model_missing"))
        db.configureSemanticSearch(queryEncoder:{_ in throw MioError("model_unavailable","Model failed")},imageRenderer:{_,_,_ in Data()})
        let failed=try call("search",["query":.string("exact")]);XCTAssertEqual(failed["semantic_state"],.string("error"));XCTAssertEqual(failed["results"].arrayValue.count,1)
    }
}
