import Foundation

extension MioStore {
    // Redact recognizable URI credentials in automatic history only.
    // User-authored notes and API domain responses retain their explicit data.
    func traceURI(_ raw: String) -> String {
        guard var uri=URLComponents(string:raw), ["http","https"].contains(uri.scheme?.lowercased() ?? ""), uri.host != nil else { return "[URI omitted]" }
        var changed=uri.user != nil || uri.password != nil
        uri.user=nil; uri.password=nil
        let secretKeys: Set<String> = ["token","accesstoken","refreshtoken","idtoken","apikey","key","auth","authorization","password","pass","pwd","secret","clientsecret","signature","sig","code","awsaccesskeyid","xamzcredential","xamzsignature","xamzsecuritytoken"]
        func isSecret(_ name:String) -> Bool { secretKeys.contains(name.lowercased().filter{$0.isLetter || $0.isNumber}) }
        if let items=uri.queryItems {
            let kept=items.filter{!isSecret($0.name)}
            if kept.count != items.count { changed=true; uri.queryItems=kept.isEmpty ? nil : kept }
        }
        if let fragment=uri.fragment {
            var parsed=URLComponents(); parsed.query=fragment
            let items=parsed.queryItems ?? []
            if items.contains(where:{isSecret($0.name)}) {
                changed=true; let kept=items.filter{!isSecret($0.name)}; parsed.queryItems=kept.isEmpty ? nil : kept; uri.fragment=parsed.query
            } else if let colon=fragment.firstIndex(of:":"), isSecret(String(fragment[..<colon])) { changed=true; uri.fragment=nil }
            else if fragment.lowercased().hasPrefix("bearer ") { changed=true; uri.fragment=nil }
        }
        return changed ? (uri.string ?? "[URI omitted]") : raw
    }
    func traceString(_ raw:String) -> String {
        guard raw.localizedCaseInsensitiveContains("http") else { return raw }
        if (raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://")), URLComponents(string:raw)?.host != nil { return traceURI(raw) }
        guard let expression=try? NSRegularExpression(pattern:"https?://[^\\s<>\"]+",options:.caseInsensitive) else { return raw }
        var output=raw
        let matches=expression.matches(in:raw,range:NSRange(raw.startIndex...,in:raw))
        for match in matches.reversed() {
            guard let range=Range(match.range,in:output) else { continue }
            let original=String(output[range]), safe=traceURI(original)
            // Keep the exact harmless string; URLComponents can normalize spelling.
            if safe != original { output.replaceSubrange(range,with:safe) }
        }
        return output
    }
    func automaticTrace(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let input):
            var output:[String:JSONValue]=[:]
            for (key,child) in input {
                let safe=automaticTrace(child); output[key]=safe
                if safe != child {
                    output[key+"_credentials_removed"] = .bool(true)
                    output[key+"_original_hash"] = .string(hash((try? child.encoded()) ?? Data()))
                }
            }
            return .object(output)
        case .array(let values): return .array(values.map(automaticTrace))
        case .string(let raw): return .string(traceString(raw))
        default: return value
        }
    }
}
