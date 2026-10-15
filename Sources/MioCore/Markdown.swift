import Foundation

extension MioStore {
    func markdownImport(_ p: [String: JSONValue], _ s: Scope) throws -> JSONValue {
        let space = try p.required("space_id"); try requireSpace(space,s,write:true)
        let root = URL(fileURLWithPath:try p.required("path")).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:root.path,isDirectory:&isDirectory) else { throw MioError("not_found", "Markdown source not found") }
        let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]
        let files: [URL]
        if isDirectory.boolValue {
            guard let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles]) else { throw MioError("file_access", "Cannot read Markdown folder") }
            files = enumerator.compactMap { ($0 as? URL)?.standardizedFileURL }.filter { url in let v = try? url.resourceValues(forKeys:Set(keys)); return v?.isRegularFile == true && v?.isSymbolicLink != true }
        } else { files = [root] }
        let base = isDirectory.boolValue ? root : root.deletingLastPathComponent()
        let basePath = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        let sourceNamespace = hash(Data(basePath.utf8))
        var imported: [(URL,JSONValue)] = [], warnings: [JSONValue] = [], attached = 0
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension.lowercased() == "md" {
            guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) < 5_000_000 else { throw MioError("file_too_large", "Markdown note exceeds 5 MB") }
            let relative = String(file.path.dropFirst(basePath.count + 1)), key = basePath + "/" + relative
            var body = try String(contentsOf:file,encoding:.utf8), title = file.deletingPathExtension().lastPathComponent
            var status: String?
            var sources: JSONValue?
            if body.hasPrefix("---\nmio: "), let end = body.range(of:"\n---\n",range:body.index(body.startIndex,offsetBy:4)..<body.endIndex) {
                let line = String(body[body.index(body.startIndex,offsetBy:9)..<end.lowerBound])
                if let meta = try? JSONValue.decode(Data(line.utf8)) {
                    title = meta["title"].stringValue ?? title; status = meta["status"].stringValue
                    sources = meta.objectValue["source_ids"]
                    if let sources {
                        guard case .array = sources else { throw MioError("invalid_params", "Source IDs must be an array") }
                        try validateSources(sources,s)
                    }
                }
                body = String(body[end.upperBound...])
            }
            let candidates=try all("note").filter { $0["import_path"].stringValue == key }
            var old=candidates.first { $0["space_id"].stringValue == space }
            if old == nil {
                for candidate in candidates where candidate["location_id"].stringValue != nil {
                    if try entity("revision",candidate["revision_id"].stringValue ?? "")?["space_id"].stringValue == space { old=candidate;break }
                }
            }
            let result: JSONValue
            if let old, !old["deleted"].boolValue {
                let retainedSources = sources ?? old["source_ids"]
                let retainedStatus = status.map(JSONValue.string) ?? old["status"]
                if old["body"].stringValue == body && old["title"].stringValue == title && old["status"] == retainedStatus && old["source_ids"] == retainedSources { result = .object(["note_id":old["id"]]) }
                else {
                    guard !old["has_conflict"].boolValue else { throw MioError("revision_conflict", "Resolve the note's conflicting versions before importing an update") }
                    result = try changeNote("note.update",["note_id":old["id"],"expected_revision":old["revision_id"],"title":.string(title),"body":.string(body),"status":retainedStatus,"source_ids":retainedSources],s)
                }
            } else if old != nil { warnings.append(.object(["file":.string(relative),"reason":.string("deleted_note_skipped")])); continue }
            else { result = try createNote(["space_id":.string(space),"title":.string(title),"body":.string(body),"status":.string(status ?? "unverified"),"source_ids":sources ?? .array([]),"import_path":.string(key),"import_relative_path":.string(relative),"import_source_namespace":.string(sourceNamespace)],s) }
            imported.append((file,try entity("note",result["note_id"].stringValue!)!))
        }
        for (file,note) in imported {
            for warning in try refreshWikilinks(note,s) { var d = warning.objectValue; d["file"] = .string(file.lastPathComponent); warnings.append(.object(d)) }
        }
        // Preserve supported local attachments as bytes; never read outside the selected source.
        for file in files where file.pathExtension.lowercased() != "md" {
            let supported: Set<String> = ["png","jpg","jpeg","gif","webp","pdf","txt","svg","mp3","m4a","wav","mp4","mov"]
            guard supported.contains(file.pathExtension.lowercased()) else { continue }
            let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            if size > 20_000_000 { warnings.append(.object(["file":.string(file.lastPathComponent),"reason":.string("attachment_exceeds_20mb")])); continue }
            let bytes = try Data(contentsOf:file), relative = String(file.path.dropFirst(basePath.count + 1)), id = "asset-" + hash(Data((space + "\u{0}" + sourceNamespace + "\u{0}" + relative).utf8))
            let data: JSONValue = .object(["id":.string(id),"space_id":.string(space),"relative_path":.string(relative),"bytes":.string(bytes.base64EncodedString()),"sha256":.string(hash(bytes)),"source_namespace":.string(sourceNamespace),"source_root":.string(basePath),"deleted":.bool(false)])
            if let existing = try entity("attachment",id), existing["sha256"] == data["sha256"] { continue }
            _ = try record("attachment",entityID:id,data:data); attached += 1
        }
        for (_,note) in imported where note["space_id"].stringValue != space {
            var origin=note.objectValue;origin["space_id"] = .string(space)
            let copied=try copyReferencedAssets(.object(origin),to:note["space_id"].stringValue!)
            let bindings=Set((copied+note["asset_ids"].arrayValue).compactMap(\.stringValue)).sorted()
            if bindings != note["asset_ids"].arrayValue.compactMap(\.stringValue).sorted() {
                _=try record("note.assets",entityID:note["id"].stringValue!,data:.object(["note_id":note["id"],"space_id":note["space_id"],"revision_id":note["revision_id"],"asset_ids":.array(bindings.map(JSONValue.string))]))
            }
        }
        return .object(["imported_notes":.number(Double(imported.count)),"imported_attachments":.number(Double(attached)),"warnings":.array(warnings),"source_modified":.bool(false)])
    }
    func markdownExport(_ p: [String: JSONValue], _ s: Scope) throws -> JSONValue {
        let root = URL(fileURLWithPath:try p.required("path")); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let requested = Set(p["space_ids"]?.arrayValue.compactMap(\.stringValue) ?? Array(s.readable)), spaces = s.readable.intersection(requested)
        let notes = try all("note").filter { !$0["deleted"].boolValue && spaces.contains($0["space_id"].stringValue ?? "") }
        let links = try all("link").filter { !$0["deleted"].boolValue }
        let selectedNoteIDs=Set(notes.compactMap{$0["id"].stringValue})
        let fileIDs=Set(notes.flatMap{$0["file_ids"].arrayValue.compactMap(\.stringValue)})
        let boundIDs=Set(notes.flatMap{$0["asset_ids"].arrayValue.compactMap(\.stringValue)})
        let assets = try all("attachment").map { try currentOwnership($0,kind:"attachment") }.filter {
            guard !$0["deleted"].boolValue,!$0["purged"].boolValue else { return false }
            if $0["kind"] == .string("pinned_asset") { return selectedNoteIDs.contains($0["note_id"].stringValue ?? "") && boundIDs.contains($0["id"].stringValue ?? "") }
            if $0["kind"] == .string("memory_file") { return fileIDs.contains($0["id"].stringValue ?? "") }
            return spaces.contains($0["space_id"].stringValue ?? "") || boundIDs.contains($0["id"].stringValue ?? "")
        }
        let assetNames = exportAssetNames(assets)
        var exportWarnings: [JSONValue] = []
        var names: [String:String] = [:]
        for note in notes {
            let sid = note["space_id"].stringValue!, id = note["id"].stringValue!
            let importedPath = note["import_relative_path"].stringValue
            let stem = importedPath.map { URL(fileURLWithPath:$0).deletingPathExtension().lastPathComponent } ?? safeFilename(note["title"].stringValue ?? "Note")
            let parent = importedPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
            let filename = safeFilename(stem) + "-" + id + ".md"
            names[id] = sid + "/" + (parent.isEmpty || parent == "." ? "" : parent + "/") + filename
        }
        for note in notes {
            let id = note["id"].stringValue!, path = names[id]!, url = root.appendingPathComponent(path)
            let metadata: JSONValue = .object(["id":note["id"],"space_id":note["space_id"],"title":note["title"],"status":note["status"],"revision_id":note["revision_id"],"source_ids":note["source_ids"]])
            let linkedBody = try exportBody(note,names:names,links:links,notes:notes)
            let resolvedBody = try exportAssetReferences(linkedBody,note:note,notePath:path,assets:assets,names:assetNames,warnings:&exportWarnings)
            var text = "---\nmio: " + (try encode(metadata)) + "\n---\n" + resolvedBody
            let outbound = links.filter { $0["from_note_id"].stringValue == id && names[$0["to_note_id"].stringValue ?? ""] != nil }
            if !outbound.isEmpty { text += "\n\n<!-- Mio links -->\n"; for link in outbound { text += "[[" + String(names[link["to_note_id"].stringValue!]!.dropLast(3)) + "]]\n" } }
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(text.utf8).write(to:url,options:.atomic)
        }
        var attachments = 0
        for a in assets {
            guard let bytes = Data(base64Encoded:a["bytes"].stringValue ?? ""), a["sha256"].stringValue == hash(bytes), let relative = a["relative_path"].stringValue, !relative.hasPrefix("/"), !relative.split(separator:"/").contains("..") else { throw MioError("attachment_corrupt", "Stored attachment is invalid") }
            let url = root.appendingPathComponent(assetNames[a["id"].stringValue!]!)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try bytes.write(to:url,options:.atomic); attachments += 1
        }
        let info = "Mio Markdown export\n\nPreserves note text, basic metadata, wikilinks and supported attachment bytes. Full version history, sessions, typed links, access profiles and deletion records require the Mio archive.\n"
        try Data(info.utf8).write(to:root.appendingPathComponent("Mio export.txt"),options:.atomic)
        return .object(["path":.string(root.path),"notes":.number(Double(notes.count)),"attachments":.number(Double(attachments)),"warnings":.array(exportWarnings),"excluded":.array([.string("revision_history"),.string("sessions"),.string("access_profiles"),.string("deletions")])])
    }
    func exportBody(_ note: JSONValue, names: [String:String], links: [JSONValue], notes: [JSONValue]) throws -> String {
        let body = note["body"].stringValue ?? "", ns = body as NSString
        let regex = try NSRegularExpression(pattern:"(?<!!)\\[\\[([^\\]]+)\\]\\]")
        let outboundIDs = Set(links.filter { $0["from_note_id"] == note["id"] }.compactMap { $0["to_note_id"].stringValue })
        var output = body
        for match in regex.matches(in:body,range:NSRange(location:0,length:ns.length)).reversed() {
            let raw = ns.substring(with:match.range(at:1)), parts = raw.split(separator:"|",maxSplits:1,omittingEmptySubsequences:false)
            let target = String(parts.first ?? ""), anchorParts = target.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false), lookup = String(anchorParts.first ?? "")
            let matches = notes.filter { outboundIDs.contains($0["id"].stringValue!) && ($0["title"].stringValue == lookup || $0["import_relative_path"].stringValue == lookup || $0["import_relative_path"].stringValue == lookup + ".md") }
            if matches.count == 1, let path = names[matches[0]["id"].stringValue!] {
                let alias = parts.count > 1 ? String(parts[1]) : lookup
                let anchor = anchorParts.count > 1 ? "#" + anchorParts[1] : ""
                let replacement = "[[" + String(path.dropLast(3)) + anchor + "|" + alias + "]]"
                if let range = Range(match.range,in:output) { output.replaceSubrange(range,with:replacement) }
            }
        }
        return output
    }
    func safeFilename(_ title: String) -> String {
        let s = title.components(separatedBy:CharacterSet(charactersIn:"/:\\\0")).joined(separator:"-").trimmingCharacters(in:.whitespacesAndNewlines)
        return String((s.isEmpty ? "Note" : s).prefix(100))
    }
}
