import Foundation
import MioCore
import MioEmbeddings

func hybridLoad(_ corpusURL: URL, store: MioStore) throws -> JSONValue {
    let corpus=try read(corpusURL.appendingPathComponent("corpus.json"))
    guard try store.execute("snapshot")["spaces"].arrayValue.isEmpty else { throw MioError("fixture_exists","Use an empty isolated database") }
    let space=try store.execute("space.create",params:["name":.string("Hybrid search acceptance")])["id"]
    var mapping:[String:JSONValue]=[:]
    for item in corpus["notes"].arrayValue {
        mapping[item["key"].stringValue!]=try store.execute("note.create",params:["space_id":space,"title":item["title"],"body":item["body"],"status":.string("confirmed"),"idempotency_key":item["key"]])
    }
    for item in corpus["files"].arrayValue {
        let bytes=try Data(contentsOf:corpusURL.appendingPathComponent(item["path"].stringValue!))
        guard hash(bytes)==item["sha256"].stringValue else { throw MioError("fixture_changed","Frozen source differs") }
        mapping[item["key"].stringValue!]=try store.execute("note.create",params:["space_id":space,"title":item["title"],"body":.string(""),"status":.string("unverified"),"file_name":item["path"],"mime_type":item["mime_type"],"file_base64":.string(bytes.base64EncodedString()),"idempotency_key":item["key"]])
    }
    return .object(["space_id":space,"mapping":.object(mapping)])
}
func hybridEvaluate(_ out: URL) throws {
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let corpus=URL(fileURLWithPath:flag("--corpus")),state=out.appendingPathComponent("state"),store=try MioStore(directory:state)
    let loaded=try hybridLoad(corpus,store:store);try save(loaded,out.appendingPathComponent("mapping.json"))
    let workerURL=URL(fileURLWithPath:flag("--worker")),models=URL(fileURLWithPath:flag("--models"))
    let indexer=MioSourceIndexer(store:store,executable:workerURL,modelDirectory:models)
    defer { indexer.stop() };indexer.checkModel()
    guard try indexer.status()["model_state"] == .string("ready") else { throw MioError("model_missing","Real pinned model is required for this evaluation") }
    let indexingStart=benchTick()
    while try indexer.indexNext() {}
    let indexingMS=ms(indexingStart),status=try indexer.status()
    guard status["index"]["error"].intValue==0 else { throw MioError("index_failed","Real source indexing failed",details:status) }
    let reverse=Dictionary(uniqueKeysWithValues:loaded["mapping"].objectValue.map{($0.value["note_id"].stringValue!,$0.key)})
    // Read independently frozen labels only after the corpus has been indexed.
    let queries=try read(URL(fileURLWithPath:flag("--queries")))
    guard queries["corpus_sha256"].stringValue == hash(try Data(contentsOf:corpus.appendingPathComponent("corpus.json"))) else { throw MioError("fixture_changed","Query labels bind another source corpus") }
    var measurements:[JSONValue]=[]
    for mode in [MioRetrievalMode.bm25,.dense,.hybrid] {
        store.configureSemanticSearch(queryEncoder:{ try indexer.worker.query($0) },imageRenderer:{try MioDocumentExtraction.preview(file:$0,bytes:$1,locator:$2)},mode:mode)
        for query in queries["queries"].arrayValue {
            let started=benchTick(),result=try store.execute("search",params:["query":query["query"],"scope":.string("all"),"limit":.number(5),"max_chars":.number(6000)])
            let latency=ms(started)
            let hits=try result["results"].arrayValue.map { hit -> JSONValue in
                var item=hit.objectValue
                item["fixture_key"] = .string(reverse[hit["note_id"].stringValue ?? hit["id"].stringValue ?? ""] ?? "unknown")
                if let source=hit["source_id"].stringValue,source.hasPrefix("source-") {
                    let evidence=try store.execute("read",params:["kind":.string("source"),"id":.string(source)])
                    guard evidence["revision_id"]==hit["revision_id"],evidence["note_id"]==hit["note_id"],evidence["locator"]==hit["locator"] else { throw MioError("source_changed","Search/source anchors differ") }
                    item["evidence_text"] = evidence["text"]
                    if evidence["media"]["mime_type"] == .string("image/png"),let data=Data(base64Encoded:evidence["media"]["data"].stringValue ?? ""),!data.isEmpty { let path=out.appendingPathComponent(source+".png");try data.write(to:path,options:.atomic);item["preview_sha256"] = .string(hash(data)) }
                }
                return .object(item)
            }
            measurements.append(.object(["query_id":query["id"],"query":query["query"],"mode":.string(mode.rawValue),"milliseconds":.number(latency),"expected":query["expected"],"no_answer":query["no_answer"],"category":query["category"],"results":.array(hits),"state":result["semantic_state"]]))
        }
    }
    try save(.object(["indexing_ms":.number(indexingMS),"index":status,"corpus_sha256":.string(hash(try Data(contentsOf:corpus.appendingPathComponent("corpus.json")))),"queries_sha256":.string(hash(try queries.encoded())),"measurements":.array(measurements),"boundary":.string("Fixture retrieval only; no generated answers or general quality claim")]),out.appendingPathComponent("results.json"))
    print("Real model retrieval complete: \(measurements.count) query/mode measurements")
}
