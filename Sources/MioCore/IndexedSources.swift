import Foundation

public struct MioSemanticQuery: Sendable {
    public let modelID: String
    public let values: [Float]
    public init(modelID: String, values: [Float]) { self.modelID=modelID;self.values=values }
}
public enum MioRetrievalMode: String, Sendable { case hybrid, bm25, dense }

extension MioStore {
    func ensureSourceIndex() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS source_fragments(id TEXT PRIMARY KEY,note_id TEXT NOT NULL,revision_id TEXT NOT NULL,file_id TEXT NOT NULL,space_id TEXT NOT NULL,signature TEXT NOT NULL,current INTEGER NOT NULL,json TEXT NOT NULL,model_id TEXT NOT NULL,embedding TEXT)")
        try db.exec("CREATE INDEX IF NOT EXISTS source_fragments_note ON source_fragments(note_id,current)")
        try db.exec("CREATE TABLE IF NOT EXISTS source_index_jobs(note_id TEXT PRIMARY KEY,signature TEXT NOT NULL,model_id TEXT NOT NULL,state TEXT NOT NULL,error TEXT NOT NULL)")
    }
    public func configureSemanticSearch(queryEncoder: @escaping (String) throws -> MioSemanticQuery, imageRenderer: @escaping (JSONValue,Data,JSONValue) throws -> Data, mode: MioRetrievalMode = .hybrid) {
        lock.lock();defer{lock.unlock()};semanticQueryEncoder=queryEncoder;sourceImageRenderer=imageRenderer;retrievalMode=mode
    }
    public func configureSourceImages(_ renderer: @escaping (JSONValue,Data,JSONValue) throws -> Data) {
        lock.lock(); defer { lock.unlock() }; sourceImageRenderer = renderer
    }
    private func indexSignature(_ note: JSONValue, modelID: String) throws -> String {
        hash(try JSONValue.object(["note_id":note["id"],"revision_id":note["revision_id"],"file_ids":note["file_ids"],"extractor":.string(MioDocumentExtraction.version),"model":.string(modelID)]).encoded())
    }
    public func nextSourceIndexJob(modelID: String) throws -> JSONValue? {
        lock.lock();defer{lock.unlock()}
        let allowed=try scope(.human).readable
        for note in try all("note") where allowed.contains(note["space_id"].stringValue ?? "") && !note["deleted"].boolValue && !note["purged"].boolValue && note["status"] != .string("purged") {
            let signature=try indexSignature(note,modelID:modelID)
            let state=try db.rows("SELECT signature,model_id,state FROM source_index_jobs WHERE note_id=?",[note["id"].stringValue!]).first
            if state?["signature"]==signature,state?["model_id"]==modelID,["ready","lexical","error"].contains(state?["state"] ?? "") { continue }
            var job:[String:JSONValue] = ["note":note,"signature":.string(signature),"model_id":.string(modelID)]
            if let id=note["file_ids"].arrayValue.first?.stringValue {
                do { job["file"] = try requireFile(id,scope(.human)) }
                catch let error as MioError where ["forbidden","not_found","source_purged"].contains(error.code) { continue }
            }
            try db.exec("INSERT OR REPLACE INTO source_index_jobs VALUES(?,?,?,'indexing','')",[note["id"].stringValue!,signature,modelID])
            return .object(job)
        }
        return nil
    }
    public func sourceDocuments(job: JSONValue, fileFragments: [JSONValue] = []) throws -> [JSONValue] {
        lock.lock();defer{lock.unlock()}
        let note=job["note"],file=job["file"]
        var inputs:[JSONValue] = fileFragments
        if file == .null || !(note["body"].stringValue ?? "").isEmpty {
            let text=note["body"].stringValue ?? ""
            let chunks=MioDocumentExtraction.textChunks(text)
            inputs += chunks.isEmpty ? [.object(["text":.string(""),"modality":.string("text"),"annotation":.bool(true),"locator":.object(["utf16_start":.number(0),"utf16_length":.number(0)])])] : chunks.map { .object(["text":.string($0.0),"modality":.string("text"),"annotation":.bool(true),"locator":.object(["utf16_start":.number(Double($0.1)),"utf16_length":.number(Double($0.2))])]) }
        }
        return try inputs.map { input in
            let file = input["annotation"].boolValue ? JSONValue.null:job["file"]
            let identity:JSONValue = .object(["note_id":note["id"],"revision_id":file == .null ? note["revision_id"] : file["captured_revision_id"],"file_id":file["id"],"file_sha":file["sha256"],"modality":input["modality"],"locator":input["locator"],"extractor":.string(MioDocumentExtraction.version)])
            let id="source-"+hash(try identity.encoded())
            return .object(["id":.string(id),"kind":.string("fragment"),"note_id":note["id"],"space_id":note["space_id"],"revision_id":file == .null ? note["revision_id"] : file["captured_revision_id"],"indexed_note_revision":note["revision_id"],"file_id":file["id"],"file_sha":file["sha256"],"source_type":.string(job["file"] == .null ? "note":"file"),"title":note["title"],"text":input["text"],"modality":input["modality"],"locator":input["locator"],"timestamp":note["updated_at"],"status":note["status"],"extractor":.string(MioDocumentExtraction.version)])
        }
    }
    public func publishSourceIndex(job: JSONValue, documents: [JSONValue], embeddings: [[Float]] = []) throws -> Bool {
        lock.lock();defer{lock.unlock()}
        guard (embeddings.isEmpty && job["model_id"] == .string("lexical-native-v1") || documents.count==embeddings.count),embeddings.allSatisfy({$0.count==768 && $0.allSatisfy(\.isFinite) && abs($0.reduce(Float(0)){$0+$1*$1}-1)<0.02}) else { throw MioError("invalid_embedding","Expected normalized finite768d embeddings") }
        return try db.transaction {
            let scope=try self.scope(.human),noteID=job["note"]["id"].stringValue!,model=job["model_id"].stringValue!
            guard let note=try? requireEntity("note",noteID,scope),!note["purged"].boolValue,note["status"] != .string("purged"),try indexSignature(note,modelID:model)==job["signature"].stringValue else { return false }
            guard let latest=try db.rows("SELECT signature,model_id,state FROM source_index_jobs WHERE note_id=?",[noteID]).first,latest["signature"]==job["signature"].stringValue,latest["model_id"]==model,latest["state"]=="indexing" else { return false }
            if job["file"] != .null { guard let file=try? requireFile(job["file"]["id"].stringValue!,scope),file["sha256"]==job["file"]["sha256"] else { return false } }
            for row in try db.rows("SELECT id FROM source_fragments WHERE note_id=? AND current=1",[noteID]) { try removeSearchDocument(kind:"fragment",id:row["id"]!) }
            try db.exec("UPDATE source_fragments SET current=0 WHERE note_id=?",[noteID])
            for (index,document) in documents.enumerated() {
                let vector=embeddings.isEmpty ? []:embeddings[index]
                let boundFile=document["file_id"] != .null
                guard document["note_id"]==note["id"],document["space_id"]==note["space_id"],document["indexed_note_revision"]==note["revision_id"],document["extractor"] == .string(MioDocumentExtraction.version),document["revision_id"] == (boundFile ? job["file"]["captured_revision_id"]:note["revision_id"]),(!boundFile || document["file_id"]==job["file"]["id"] && document["file_sha"]==job["file"]["sha256"]) else { throw MioError("invalid_source","Source documents do not belong to the current indexing job") }
                let id=document["id"].stringValue!,fileID=document["file_id"].stringValue ?? ""
                try db.bindVector("INSERT OR REPLACE INTO source_fragments VALUES(?,?,?,?,?,?,1,?,?,?)",[id,noteID,document["revision_id"].stringValue!,fileID,note["space_id"].stringValue!,job["signature"].stringValue!,try encode(document),model],vector:vector)
                try indexDocument(kind:"fragment",id:id,space:note["space_id"].stringValue!,revision:document["revision_id"].stringValue!,title:document["title"].stringValue ?? "",text:document["text"].stringValue ?? "",timestamp:document["timestamp"].stringValue ?? "",status:document["status"].stringValue ?? "")
            }
            try db.exec("INSERT OR REPLACE INTO source_index_jobs VALUES(?,?,?,?, '')",[noteID,job["signature"].stringValue!,model,embeddings.isEmpty ? "lexical":"ready"])
            try db.exec("INSERT INTO metadata(key,value) VALUES('source_index_generation','1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1")
            return true
        }
    }
    public func failSourceIndex(job: JSONValue, error: String) throws {
        lock.lock();defer{lock.unlock()}
        try db.exec("UPDATE source_index_jobs SET state='error',error=? WHERE note_id=? AND signature=?",[String(error.prefix(500)),job["note"]["id"].stringValue!,job["signature"].stringValue!])
    }
    public func resetSourceIndexErrors() throws { lock.lock();defer{lock.unlock()};try db.exec("DELETE FROM source_index_jobs WHERE state='error'") }
    public func sourceIndexStatus() throws -> JSONValue {
        lock.lock();defer{lock.unlock()}
        var values:[String:JSONValue]=[:]
        let allowed=try scope(.human).readable
        var counts:[String:Int]=[:]
        var errors:[JSONValue]=[]
        for note in try all("note") where allowed.contains(note["space_id"].stringValue ?? "") && !note["deleted"].boolValue && !note["purged"].boolValue && note["status"] != .string("purged") {
            let job=try db.rows("SELECT * FROM source_index_jobs WHERE note_id=?",[note["id"].stringValue!]).first
            let matching=try job.map { $0["signature"] == (try indexSignature(note,modelID:$0["model_id"]!)) } ?? false
            counts[matching ? job!["state"]!:"pending",default:0]+=1
            if matching,job?["state"]=="error" { errors.append(.object(["note_id":note["id"],"title":note["title"],"error":.string(job?["error"] ?? "")])) }
        }
        for (state,count) in counts { values[state] = .number(Double(count)) }
        values["errors"] = .array(Array(errors.prefix(20)))
        values["generation"] = .string(try db.rows("SELECT value FROM metadata WHERE key='source_index_generation'").first?["value"] ?? "0")
        values["fragments"] = .number(Double(try db.rows("SELECT count(*) AS n FROM source_fragments WHERE current=1").first?["n"] ?? "0") ?? 0)
        return .object(values)
    }
    func requireFragment(_ id: String, _ scope: Scope) throws -> JSONValue {
        guard let row=try db.rows("SELECT json FROM source_fragments WHERE id=?",[id]).first else { throw MioError(scope.human ? "not_found":"forbidden","Source fragment is unavailable") }
        let fragment=try decode(row["json"]!),note=try requireEntity("note",fragment["note_id"].stringValue ?? "",scope)
        guard !note["purged"].boolValue,note["status"] != .string("purged"),note["space_id"]==fragment["space_id"] else { throw MioError("source_purged","Source note was cleared") }
        if let fileID=fragment["file_id"].stringValue,!fileID.isEmpty {
            let file=try requireFile(fileID,scope);guard file["sha256"]==fragment["file_sha"] else { throw MioError("source_changed","File source has changed") }
        } else {
            let revision=try requireEntity("revision",fragment["revision_id"].stringValue ?? "",scope)
            guard revision["note_id"]==note["id"],revision["space_id"]==note["space_id"],!revision["purged"].boolValue else { throw MioError("source_purged","Source revision is unavailable") }
        }
        return fragment
    }
    func readFragment(_ id: String, _ scope: Scope) throws -> JSONValue {
        let fragment=try requireFragment(id,scope)
        var value=fragment.objectValue;value["body"] = fragment["text"];value["source_id"] = fragment["id"];value["source_group_id"] = fragment["note_id"]
        if fragment["modality"] == .string("image"),let renderer=sourceImageRenderer {
            let file=try requireFile(fragment["file_id"].stringValue ?? "",scope)
            guard let bytes=Data(base64Encoded:file["bytes"].stringValue ?? "") else { throw MioError("invalid_source","File bytes are invalid") }
            let image=try renderer(file,bytes,fragment["locator"])
            value["media"] = .object(["mime_type":.string("image/png"),"data":.string(image.base64EncodedString())])
        }
        return .object(value)
    }
    func eraseSourceIndex(_ noteID: String) throws {
        for row in try db.rows("SELECT id FROM source_fragments WHERE note_id=?",[noteID]) { try removeSearchDocument(kind:"fragment",id:row["id"]!) }
        try db.exec("DELETE FROM source_fragments WHERE note_id=?",[noteID]);try db.exec("DELETE FROM source_index_jobs WHERE note_id=?",[noteID])
    }
}
