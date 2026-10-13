import Foundation

extension MioStore {
    func exportAssetNames(_ assets: [JSONValue]) -> [String:String] {
        let groups = Dictionary(grouping:assets) { ($0["space_id"].stringValue ?? "") + "\u{0}" + ($0["relative_path"].stringValue ?? "").lowercased() }
        var names: [String:String] = [:]
        for asset in assets {
            let id = asset["id"].stringValue!, space = asset["space_id"].stringValue!, relative = asset["relative_path"].stringValue!
            let collision = (groups[space + "\u{0}" + relative.lowercased()]?.count ?? 0) > 1
            if collision {
                let path = relative as NSString, parent = path.deletingLastPathComponent, filename = (path.lastPathComponent as NSString).deletingPathExtension, ext = path.pathExtension
                names[id] = space + "/" + (parent.isEmpty || parent == "." ? "" : parent + "/") + safeFilename(filename) + "-" + id + (ext.isEmpty ? "" : "." + ext)
            } else { names[id] = space + "/" + relative }
        }
        return names
    }
    func resolveExportAsset(_ raw: String, note: JSONValue, assets: [JSONValue]) -> [JSONValue] {
        let decoded = raw.removingPercentEncoding ?? raw
        if decoded.hasPrefix("/") || decoded.contains("://") { return [] }
        let namespace = note["import_source_namespace"].stringValue
        let relativeNote = note["import_relative_path"].stringValue ?? ""
        let parent = (relativeNote as NSString).deletingLastPathComponent
        let relativeTarget = URL(fileURLWithPath:"/" + parent).appendingPathComponent(decoded).standardizedFileURL.path.dropFirst()
        let sourceScoped = assets.filter { asset in
            guard asset["space_id"] == note["space_id"] else { return false }
            if let namespace { return asset["source_namespace"].stringValue == namespace }
            if let sourceRoot = asset["source_root"].stringValue, let noteSource = note["import_path"].stringValue { return noteSource.hasPrefix(sourceRoot + "/") }
            return true
        }
        let exact = sourceScoped.filter { $0["relative_path"].stringValue == String(relativeTarget) }
        if !exact.isEmpty { return exact }
        // Obsidian also permits a unique vault-relative path or basename.
        return sourceScoped.filter { asset in let path = asset["relative_path"].stringValue ?? ""; return path == decoded || ((path as NSString).lastPathComponent == decoded) }
    }
    func relativeExportLink(from notePath: String, to assetPath: String) -> String {
        var from = notePath.split(separator:"/").dropLast().map(String.init), to = assetPath.split(separator:"/").map(String.init)
        while from.first != nil && from.first == to.first { from.removeFirst(); to.removeFirst() }
        return (Array(repeating:"..",count:from.count) + to).joined(separator:"/")
    }
    func exportAssetReferences(_ body: String, note: JSONValue, notePath: String, assets: [JSONValue], names: [String:String], warnings: inout [JSONValue]) throws -> String {
        var output = body
        let wiki = try NSRegularExpression(pattern:"!?\\[\\[([^\\]]+)\\]\\]")
        let source = output as NSString
        for match in wiki.matches(in:output,range:NSRange(location:0,length:source.length)).reversed() {
            let raw = source.substring(with:match.range(at:1)), parts = raw.split(separator:"|",maxSplits:1,omittingEmptySubsequences:false), target = String(parts.first ?? "")
            let anchors = target.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false), lookup = String(anchors.first ?? "")
            let candidates = resolveExportAsset(lookup,note:note,assets:assets)
            if candidates.count == 1, let path = names[candidates[0]["id"].stringValue!] {
                let anchor = anchors.count > 1 ? "#" + anchors[1] : "", suffix = parts.count > 1 ? "|" + parts[1] : ""
                if let range = Range(match.range(at:1),in:output) { output.replaceSubrange(range,with:path + anchor + suffix) }
            } else if candidates.count > 1 { warnings.append(.object(["note_id":note["id"],"target":.string(lookup),"reason":.string("ambiguous_attachment")])) }
        }
        let markdown = try NSRegularExpression(pattern:"!?\\[[^\\]]*\\]\\(([^)]+)\\)")
        let updated = output as NSString
        for match in markdown.matches(in:output,range:NSRange(location:0,length:updated.length)).reversed() {
            let raw = updated.substring(with:match.range(at:1)), anchors = raw.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false), lookup = String(anchors.first ?? "")
            let candidates = resolveExportAsset(lookup,note:note,assets:assets)
            if candidates.count == 1, let path = names[candidates[0]["id"].stringValue!] {
                let relative = relativeExportLink(from:notePath,to:path), anchor = anchors.count > 1 ? "#" + anchors[1] : ""
                let escaped = relative.addingPercentEncoding(withAllowedCharacters:CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn:"()"))) ?? relative
                if let range = Range(match.range(at:1),in:output) { output.replaceSubrange(range,with:escaped + anchor) }
            } else if candidates.count > 1 { warnings.append(.object(["note_id":note["id"],"target":.string(lookup),"reason":.string("ambiguous_attachment")])) }
        }
        return output
    }
}
