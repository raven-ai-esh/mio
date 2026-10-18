import Foundation
import Accelerate

extension MioStore {
    func search(_ p: [String:JSONValue], _ scope: Scope, semantic:Result<MioSemanticQuery,MioError>? = nil) throws -> JSONValue {
        let requestedScope=p.string("scope","all")
        guard ["all","notes","history","files"].contains(requestedScope) else { throw MioError("invalid_params","Search scope must be all, notes, files or history") }
        var legacyParams=p;legacyParams["scope"] = .string(requestedScope)
        if requestedScope == "history" || p["as_of"] != nil {
            var result=try legacySearch(legacyParams,scope).objectValue
            if requestedScope == "files" {
                result["file_search_state"] = .string("historical_annotations_only; extracted file content unavailable in as_of search")
            }
            result["semantic_state"] = .string(requestedScope == "history" ? "history_lexical":"historical_lexical")
            return .object(result)
        }
        let query=p.string("query").trimmingCharacters(in:.whitespacesAndNewlines)
        let limit=max(1,min(100,p["limit"]?.intValue ?? 20)),budget=max(1,min(100000,p["max_chars"]?.intValue ?? 12000))
        let rawWords=Array(query.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter{!$0.isEmpty}.prefix(32))
        let meaningful=rawWords.filter{!Self.searchStopWords.contains($0) && !["s","t","d","m","ll","ve","re"].contains($0)}
        let words=meaningful.isEmpty ? rawWords:meaningful
        guard !words.isEmpty else { return .object(["results":.array([]),"search_mode":.string("hybrid"),"semantic_state":.string("empty_query"),"returned_chars":.number(0),"truncated":.bool(false)]) }
        var allowed=scope.readable
        if let spaces=p["space_ids"],!spaces.arrayValue.isEmpty { allowed.formIntersection(spaces.arrayValue.compactMap(\.stringValue)) }
        guard !allowed.isEmpty else { return .object(["results":.array([]),"search_mode":.string("fts5_lexical"),"semantic_state":.string("empty_scope"),"returned_chars":.number(0),"truncated":.bool(false)]) }
        legacyParams["limit"] = .number(100);legacyParams["max_chars"] = .number(100000)
        legacyParams["scope"] = .string(requestedScope == "files" ? "files":"notes")
        legacyParams["include_file_notes"] = .bool(requestedScope == "all")
        legacyParams["query"] = .string(words.joined(separator:" "))
        let legacy=try legacySearch(legacyParams,scope)["results"].arrayValue
        var keyword:[JSONValue]=[],history:[JSONValue]=[]
        for item in legacy {
            if item["kind"] == .string("event") { history.append(item);continue }
            let owner=try requireEntity("note",item["id"].stringValue!,scope),isFile = !owner["file_ids"].arrayValue.isEmpty
            guard lexicalCandidate((owner["title"].stringValue ?? "")+" "+(owner["body"].stringValue ?? ""),words:words) else { continue }
            if requestedScope == "files" && !isFile || requestedScope == "notes" && isFile { continue }
            var value=item.objectValue;value["source_group_id"] = item["id"];value["kind"] = .string(isFile ? "file":"note")
            keyword.append(.object(value))
        }
        let marks=Array(repeating:"?",count:allowed.count).joined(separator:",")
        let rows=try db.vectorRows("SELECT source_fragments.json,source_fragments.embedding,source_fragments.model_id FROM source_fragments JOIN entities owner ON owner.kind='note' AND owner.id=source_fragments.note_id WHERE source_fragments.current=1 AND source_fragments.space_id IN ("+marks+") AND coalesce(json_extract(owner.json,'$.deleted'),0)=0 AND coalesce(json_extract(owner.json,'$.purged'),0)=0 AND json_extract(owner.json,'$.status')<>'purged' AND json_extract(owner.json,'$.revision_id')=json_extract(source_fragments.json,'$.indexed_note_revision')",allowed.sorted())
        var documents:[String:JSONValue]=[:],vectors:[String:Data]=[:],models:[String:String]=[:]
        var canonicalNotes:[String:JSONValue]=[:],canonicalFiles:[String:JSONValue]=[:]
        for (json,bytes,model) in rows {
            let source=try decode(json),id=source["id"].stringValue!
            let parentID=source["note_id"].stringValue ?? ""
            if canonicalNotes[parentID]==nil { canonicalNotes[parentID]=try? requireEntity("note",parentID,scope) }
            guard let parent=canonicalNotes[parentID],!parent["purged"].boolValue,parent["status"] != .string("purged"),parent["space_id"]==source["space_id"],parent["revision_id"]==source["indexed_note_revision"] else { continue }
            if let fileID=source["file_id"].stringValue {
                if canonicalFiles[fileID]==nil { canonicalFiles[fileID]=try? requireFile(fileID,scope) }
                guard let original=canonicalFiles[fileID],original["note_id"]==parent["id"],original["space_id"]==source["space_id"],original["sha256"]==source["file_sha"],original["captured_revision_id"]==source["revision_id"] else { continue }
            } else { guard source["revision_id"]==parent["revision_id"] else { continue } }
            let file=source["source_type"] == .string("file") || source["file_id"].stringValue != nil
            if requestedScope == "files" && !file || requestedScope == "notes" && file { continue }
            documents[id]=source
            if bytes.count==768*4 && source["extractor"] == .string(MioDocumentExtraction.version) { vectors[id]=bytes;models[id]=model }
        }
        let indexedParents=Set(documents.values.compactMap{$0["note_id"].stringValue})
        keyword.removeAll{indexedParents.contains($0["id"].stringValue ?? "")}
        if requestedScope == "all" { var h=legacyParams;h["scope"] = .string("history");h["query"] = .string(query);history=try legacySearch(h,scope)["results"].arrayValue }
        let match=words.map{"\""+$0.replacingOccurrences(of:"\"",with:"")+"\"*"}.joined(separator:" OR ")
        let lexical=try db.rows("SELECT id,bm25(search_index,0,0,0,0,3,1,0,0) AS score FROM search_index WHERE search_index MATCH ? AND kind='fragment' ORDER BY score",[match])
        var fragmentKeywords:[JSONValue]=[]
        for row in lexical { if let source=documents[row["id"]!],lexicalCandidate((source["title"].stringValue ?? "")+" "+(source["text"].stringValue ?? ""),words:words) { fragmentKeywords.append(fragmentResult(source,words:words));if fragmentKeywords.count==100 { break } } }
        keyword=fragmentKeywords+keyword
        var semanticState="model_missing",semanticError="",activeModel="",dense:[JSONValue]=[]
        if (semantic != nil || semanticQueryEncoder != nil),retrievalMode != .bm25 {
            do {
                let encoded: MioSemanticQuery
                if let semantic { encoded=try semantic.get() }
                else if let encoder=semanticQueryEncoder { encoded=try encoder(query) }
                else { throw MioError("model_missing","The query encoder is unavailable") }
                activeModel=encoded.modelID
                guard encoded.values.count==768,encoded.values.allSatisfy(\.isFinite),abs(encoded.values.reduce(Float(0)){$0+$1*$1}-1)<0.02 else { throw MioError("invalid_embedding","Query embedding is not normalized768d") }
                semanticState=models.values.contains(encoded.modelID) ? "ready":"index_pending"
                var ranked:[(Float,String)]=[]
                for (id,bytes) in vectors {
                    guard models[id]==encoded.modelID else { continue }
                    var score:Float=0
                    encoded.values.withUnsafeBufferPointer { q in bytes.withUnsafeBytes { v in
                        vDSP_dotpr(q.baseAddress!,1,v.bindMemory(to:Float.self).baseAddress!,1,&score,vDSP_Length(768))
                    } }
                    if score.isFinite { ranked.append((score,id)) }
                }
                ranked.sort{$0.0==$1.0 ? $0.1<$1.1:$0.0>$1.0}
                dense=ranked.prefix(100).compactMap{documents[$0.1]}.map{fragmentResult($0,words:words)}
            } catch { semanticState=(error as? MioError)?.code == "model_missing" ? "model_missing":"error";semanticError=error.localizedDescription }
        }
        var fused:[String:(Double,JSONValue,Set<String>)]=[:]
        let channels: [(String,[JSONValue])] = retrievalMode == .dense && semanticState == "ready" ? [("semantic",dense)] : retrievalMode == .bm25 ? [("bm25",keyword)] : [("bm25",keyword),("semantic",dense)]
        for (channel,list) in channels {
            for (index,item) in list.enumerated() {
                let key=item["source_id"].stringValue ?? item["id"].stringValue!
                let old=fused[key] ?? (0,item,Set<String>())
                fused[key]=(old.0+1/Double(60+index+1),old.1,old.2.union([channel]))
            }
        }
        let ranked=fused.sorted{$0.value.0==$1.value.0 ? $0.key<$1.key:$0.value.0>$1.value.0}
        var results:[JSONValue]=[],groups:[String:Int]=[:],groupPositions:[String:Int]=[:],pages=Set<String>(),used=0,truncated=false
        let historySlots=requestedScope == "all" && !history.isEmpty ? min(ranked.isEmpty ? limit:limit/4,history.count):0
        for (_,entry) in ranked {
            let group=entry.1["source_group_id"].stringValue ?? entry.1["id"].stringValue!
            let page=entry.1["locator"]["page"].intValue
            let duplicate=group+":"+String(page)
            if page>0 && !pages.insert(duplicate).inserted { continue }
            if groups[group,default:0]>=3 { continue }
            if let position=groupPositions[group] {
                guard used<budget else { truncated=true;continue }
                var supporting=entry.1.objectValue
                let text=String((entry.1["snippet"].stringValue ?? "").prefix(min(300,budget-used)));used+=text.count
                supporting["snippet"] = .string(text);supporting["match_channels"] = .array(entry.2.sorted().map(JSONValue.string))
                var primary=results[position].objectValue;primary["supporting_sources"] = .array(results[position]["supporting_sources"].arrayValue+[.object(supporting)])
                results[position] = .object(primary);groups[group,default:0]+=1;continue
            }
            if results.count>=limit-historySlots || used>=budget { truncated=true;continue }
            groups[group,default:0]+=1
            var value=entry.1.objectValue;let text=String((entry.1["snippet"].stringValue ?? "").prefix(budget-used));used+=text.count
            value["snippet"] = .string(text);value["match_channels"] = .array(entry.2.sorted().map(JSONValue.string));value["rank_score"] = .number(entry.0)
            value["supporting_sources"] = .array([]);groupPositions[group]=results.count
            results.append(.object(value))
        }
        for item in history.prefix(historySlots) where results.count<limit && used<budget {
            var value=item.objectValue;let text=String((item["snippet"].stringValue ?? "").prefix(budget-used));used+=text.count;value["snippet"] = .string(text);value["match_channels"] = .array([.string("history_bm25")]);results.append(.object(value))
        }
        let visibleNoteCount=try all("note").filter { allowed.contains($0["space_id"].stringValue ?? "") && !$0["deleted"].boolValue && !$0["purged"].boolValue && $0["status"] != .string("purged") && (requestedScope == "all" || (requestedScope == "files") == !$0["file_ids"].arrayValue.isEmpty) }.count
        let semanticParents=Set(documents.filter{models[$0.key] == activeModel}.values.compactMap{$0["note_id"].stringValue})
        let visibleFiles=try all("note").filter { allowed.contains($0["space_id"].stringValue ?? "") && !$0["deleted"].boolValue && !$0["purged"].boolValue && $0["status"] != .string("purged") && !$0["file_ids"].arrayValue.isEmpty && requestedScope != "notes" }
        let lexicalPending=visibleFiles.filter{!indexedParents.contains($0["id"].stringValue ?? "")}.count
        var response:[String:JSONValue] = ["results":.array(results),"search_mode":.string(semanticState=="ready" ? "bm25_embeddinggemma2_rrf":"fts5_lexical"),"semantic_state":.string(semanticState),"semantic_indexed_sources":.number(Double(semanticParents.count)),"visible_sources":.number(Double(visibleNoteCount)),"returned_chars":.number(Double(used)),"truncated":.bool(truncated),"as_of":.null,"history_boundary":.string("Mio memory operation traces only; no conversations"),"interpretation":.string("Ranked retrieval candidates; not proof of an answer")]
        if !semanticError.isEmpty { response["semantic_error"] = .string(String(semanticError.prefix(300))) }
        response["requested_search_mode"] = .string(retrievalMode.rawValue)
        response["lexical_pending_sources"] = .number(Double(lexicalPending))
        response["index_coverage"] = .string(lexicalPending>0 || semanticParents.count<visibleNoteCount && semanticState=="ready" ? "partial":"complete")
        if retrievalMode == .bm25 { response["semantic_state"] = .string("disabled");response["search_mode"] = .string("fts5_bm25") }
        if retrievalMode == .dense && semanticState == "ready" { response["search_mode"] = .string("embeddinggemma2_dense") }
        return .object(response)
    }
    static let searchStopWords=Set("a an the and or of to in on at for from by with without as is are was were be been being do does did can could may might must should would will shall have has had it its this that these those they their them we our us you your i my me what which who whom whose how when where why during before after than then there here also not no if but into over under about against please find show get need и или а но в во на к ко от до из у о об с со по за без при для через это эта этот эти того той те как что кто где когда почему зачем ли не ни же бы я мы вы ты он она они его ее их наш ваш мне нам вам то есть был было были будет будут можно нужно найти покажи показать дать расскажи".split(separator:" ").map(String.init))
    func lexicalCandidate(_ text:String,words:[String])->Bool {
        let tokens=text.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted)
        return Set(words.filter{word in tokens.contains{ $0.hasPrefix(word) }}).count >= min(2,Set(words).count)
    }
    func fragmentResult(_ source: JSONValue, words: [String]) -> JSONValue {
        let file=source["source_type"] == .string("file") || source["file_id"].stringValue != nil
        return .object(["kind":.string(file ? "file":"note"),"id":source["note_id"],"note_id":source["note_id"],"source_id":source["id"],"source_group_id":source["note_id"],"revision_id":source["revision_id"],"space_id":source["space_id"],"file_id":source["file_id"],"file_sha":source["file_sha"],"title":source["title"],"snippet":.string(excerpt(source["text"].stringValue ?? "",words:words,max:1200)),"locator":source["locator"],"modality":source["modality"],"timestamp":source["timestamp"],"status":source["status"]])
    }
}
