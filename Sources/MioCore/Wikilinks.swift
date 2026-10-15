import Foundation

extension MioStore {
    func wikiTargets(_ body: String) throws -> [String] {
        let text=body as NSString,regex=try NSRegularExpression(pattern:"(?<!!)\\[\\[([^\\]]+)\\]\\]")
        return regex.matches(in:body,range:NSRange(location:0,length:text.length)).compactMap { match in
            let raw=text.substring(with:match.range(at:1))
            let target=String(raw.split(separator:"|",maxSplits:1).first ?? "").split(separator:"#",maxSplits:1).first.map(String.init) ?? ""
            return target.isEmpty ? nil:target
        }
    }
    func wikiTarget(_ target: String, matches candidate: JSONValue, from note: JSONValue) -> Bool {
        let path=target.hasSuffix(".md") ? target:target+".md"
        let origin=note["import_path"].stringValue.map { URL(fileURLWithPath:$0).deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path }
        return candidate["title"].stringValue == target || candidate["import_relative_path"].stringValue == path || (origin != nil && candidate["import_path"].stringValue == origin)
    }
    /// Capture pre-existing short-link bindings before relocating their owner.
    /// Removing the matching wiki text will still remove its derived edge.
    func preserveWikiBindings(_ note: JSONValue) throws {
        let targets=try wikiTargets(note["body"].stringValue ?? "")
        for link in try all("link") where !link["deleted"].boolValue && link["derived"] == .string("wikilink") && link["from_note_id"] == note["id"] && link["wiki_targets"].arrayValue.isEmpty {
            guard let target=try entity("note",link["to_note_id"].stringValue ?? "") else { continue }
            let matching=targets.filter { wikiTarget($0,matches:target,from:note) }
            if !matching.isEmpty { var value=link.objectValue;value["wiki_targets"] = .array(matching.map(JSONValue.string));_=try record("link",entityID:link["id"].stringValue!,data:.object(value)) }
        }
    }
    func refreshWikilinks(_ note: JSONValue, _ scope: Scope) throws -> [JSONValue] {
        let id=note["id"].stringValue!,space=note["space_id"].stringValue!
        let existing=try all("link").filter { !$0["deleted"].boolValue && $0["from_note_id"].stringValue == id }
        let inputs=try wikiTargets(note["body"].stringValue ?? "")
        var candidateSpaces: Set<String>=[space]
        for connection in try all("connection") where !connection["deleted"].boolValue && connection["from_space_id"].stringValue == space {
            if let target=connection["to_space_id"].stringValue,scope.readable.contains(target) { candidateSpaces.insert(target) }
        }
        let candidates=inputs.isEmpty ? []:try all("note").filter { !$0["deleted"].boolValue && $0["status"].stringValue != "purged" && candidateSpaces.contains($0["space_id"].stringValue ?? "") && scope.readable.contains($0["space_id"].stringValue ?? "") }
        var bindings=[String:Set<String>](),warnings=[JSONValue]()
        for target in inputs {
            let bound=existing.filter { $0["derived"] == .string("wikilink") && $0["wiki_targets"].arrayValue.contains(.string(target)) }
            if !bound.isEmpty { for link in bound { bindings[link["to_note_id"].stringValue!,default:[]].insert(target) };continue }
            let local=candidates.filter { $0["space_id"].stringValue == space && wikiTarget(target,matches:$0,from:note) }
            let matched=local.isEmpty ? candidates.filter { wikiTarget(target,matches:$0,from:note) }:local
            if matched.count == 1 { bindings[matched[0]["id"].stringValue!,default:[]].insert(target) }
            else { warnings.append(.object(["target":.string(target),"reason":.string(matched.isEmpty ? "missing_target":"ambiguous_target")])) }
        }
        for link in existing where link["derived"] == .string("wikilink") {
            var value=link.objectValue
            if let targets=bindings[link["to_note_id"].stringValue ?? ""] { value["wiki_targets"] = .array(targets.sorted().map(JSONValue.string)) }
            else { value["deleted"] = .bool(true) }
            if value != link.objectValue { _=try record("link",entityID:link["id"].stringValue!,data:.object(value)) }
        }
        for (target,inputs) in bindings where !existing.contains(where: { $0["to_note_id"].stringValue == target && $0["kind"] == .string("related") }) {
            let linkID=UUID().uuidString.lowercased()
            _=try record("link",entityID:linkID,data:.object(["id":.string(linkID),"space_id":.string(space),"from_note_id":.string(id),"to_note_id":.string(target),"kind":.string("related"),"derived":.string("wikilink"),"wiki_targets":.array(inputs.sorted().map(JSONValue.string)),"deleted":.bool(false)]))
        }
        return warnings
    }
}
