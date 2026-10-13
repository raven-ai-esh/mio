import Foundation

extension MioStore {
    func refreshWikilinks(_ note: JSONValue, _ scope: Scope) throws -> [JSONValue] {
        let id = note["id"].stringValue!, space = note["space_id"].stringValue!
        let body = note["body"].stringValue ?? "", ns = body as NSString
        let regex = try NSRegularExpression(pattern:"(?<!!)\\[\\[([^\\]]+)\\]\\]")
        let matches = regex.matches(in:body,range:NSRange(location:0,length:ns.length))
        if matches.isEmpty {
            let old = try db.rows("SELECT json FROM entities WHERE kind='link' AND json_extract(json,'$.from_note_id')=? AND json_extract(json,'$.derived')='wikilink' AND json_extract(json,'$.deleted')=0",[id]).map { try decode($0["json"]!) }
            for link in old { var d = link.objectValue; d["deleted"] = .bool(true); _ = try record("link",entityID:link["id"].stringValue!,data:.object(d)) }
            return []
        }
        var candidateSpaces: Set<String> = [space]
        for connection in try all("connection") where !connection["deleted"].boolValue && connection["from_space_id"].stringValue == space {
            if let target = connection["to_space_id"].stringValue, scope.readable.contains(target) { candidateSpaces.insert(target) }
        }
        let candidates = try all("note").filter { !$0["deleted"].boolValue && $0["status"].stringValue != "purged" && candidateSpaces.contains($0["space_id"].stringValue ?? "") && scope.readable.contains($0["space_id"].stringValue ?? "") }
        var targets = Set<String>(), warnings: [JSONValue] = []
        for match in matches {
            let raw = ns.substring(with:match.range(at:1)), target = String(raw.split(separator:"|",maxSplits:1).first ?? "").split(separator:"#",maxSplits:1).first.map(String.init) ?? ""
            if target.isEmpty { continue }
            let path = target.hasSuffix(".md") ? target : target + ".md"
            let originPath = note["import_path"].stringValue.map { URL(fileURLWithPath:$0).deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path }
            func matches(_ candidate: JSONValue) -> Bool { candidate["title"].stringValue == target || candidate["import_relative_path"].stringValue == path || (originPath != nil && candidate["import_path"].stringValue == originPath) }
            let local = candidates.filter { $0["space_id"].stringValue == space && matches($0) }
            let matched = local.isEmpty ? candidates.filter(matches) : local
            if matched.count == 1 { targets.insert(matched[0]["id"].stringValue!) }
            else { warnings.append(.object(["target":.string(target),"reason":.string(matched.isEmpty ? "missing_target" : "ambiguous_target")])) }
        }
        let existing = try all("link").filter { !$0["deleted"].boolValue && $0["from_note_id"].stringValue == id }
        for link in existing where link["derived"].stringValue == "wikilink" && !targets.contains(link["to_note_id"].stringValue ?? "") {
            var d = link.objectValue; d["deleted"] = .bool(true); _ = try record("link",entityID:link["id"].stringValue!,data:.object(d))
        }
        for target in targets where !existing.contains(where: { $0["to_note_id"].stringValue == target && $0["kind"].stringValue == "related" }) {
            let linkID = UUID().uuidString.lowercased()
            let d: JSONValue = .object(["id":.string(linkID),"space_id":.string(space),"from_note_id":.string(id),"to_note_id":.string(target),"kind":.string("related"),"derived":.string("wikilink"),"deleted":.bool(false)])
            _ = try record("link",entityID:linkID,data:d)
        }
        return warnings
    }
}
