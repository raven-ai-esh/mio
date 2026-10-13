import Foundation

extension MioStore {
    func readSpaces(_ params: [String:JSONValue], _ scope: Scope) throws -> JSONValue {
        guard params["id"] == nil, params["revision_id"] == nil else { throw MioError("invalid_params","read(kind=spaces) takes no id or revision_id") }
        let spaces = try all("space").filter { !$0["deleted"].boolValue && scope.readable.contains($0["id"].stringValue ?? "") }.sorted {
            $0["name"] == $1["name"] ? $0["id"].stringValue! < $1["id"].stringValue! : ($0["name"].stringValue ?? "") < ($1["name"].stringValue ?? "")
        }
        let offset = max(0,params["offset"]?.intValue ?? 0), limit = max(1,min(200,params["limit"]?.intValue ?? 50))
        let page = spaces.dropFirst(offset).prefix(limit).map { space -> JSONValue in
            .object(["id":space["id"],"name":space["name"],"can_read":.bool(true),"can_write":.bool(scope.writable.contains(space["id"].stringValue!))])
        }
        return .object(["kind":.string("spaces"),"default_space_id":scope.homeSpace.map(JSONValue.string) ?? .null,
            "spaces":.array(page),"total_count":.number(Double(spaces.count)),"offset":.number(Double(offset)),"limit":.number(Double(limit)),
            "next_offset":offset+page.count < spaces.count ? .number(Double(offset+page.count)):.null])
    }
}
