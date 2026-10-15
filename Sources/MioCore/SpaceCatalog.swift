import Foundation

extension MioStore {
    func readSpaces(_ params: [String:JSONValue], _ scope: Scope) throws -> JSONValue {
        guard params["id"] == nil, params["revision_id"] == nil else { throw MioError("invalid_params","read(kind=spaces) takes no id or revision_id") }
        let spaces = try all("space").filter { !$0["deleted"].boolValue && scope.readable.contains($0["id"].stringValue ?? "") }.sorted {
            $0["name"] == $1["name"] ? $0["id"].stringValue! < $1["id"].stringValue! : ($0["name"].stringValue ?? "") < ($1["name"].stringValue ?? "")
        }
        let tree=MioSpaceTree(spaces:spaces),visibleIDs=Set(spaces.compactMap { $0["id"].stringValue })
        let connections=try all("connection").filter { !$0["deleted"].boolValue && visibleIDs.contains($0["from_space_id"].stringValue ?? "") && visibleIDs.contains($0["to_space_id"].stringValue ?? "") }.map { edge -> JSONValue in
            .object(["id":edge["id"],"from_space_id":edge["from_space_id"],"to_space_id":edge["to_space_id"],"access":edge["access"],"effective_for_profile":.bool(edge["from_space_id"].stringValue==scope.homeSpace)])
        }
        let offset = max(0,params["offset"]?.intValue ?? 0), limit = max(1,min(200,params["limit"]?.intValue ?? 50))
        let page = spaces.dropFirst(offset).prefix(limit).map { space -> JSONValue in
            let id=space["id"].stringValue!
            return .object(["id":space["id"],"name":space["name"],"description":space["description"] == .null ? .string(""):space["description"],"color":space["color"],"sort_order":space["sort_order"],"parent_id":tree.parent(of:id).map(JSONValue.string) ?? .null,"child_space_ids":.array(tree.childIDs(of:id).map(JSONValue.string)),"subtree_space_ids":.array(tree.subtreeIDs(of:id).sorted().map(JSONValue.string)),"path":.array(tree.path(to:id).map { .object(["id":$0["id"],"name":$0["name"]]) }),"can_read":.bool(true),"can_write":.bool(scope.writable.contains(id))])
        }
        return .object(["kind":.string("spaces"),"default_space_id":scope.homeSpace.map(JSONValue.string) ?? .null,
            "spaces":.array(page),"connections":.array(connections),"hierarchy_access":.string("Organization only; profile grants remain explicit. Use subtree_space_ids to search authorized child spaces."),"total_count":.number(Double(spaces.count)),"offset":.number(Double(offset)),"limit":.number(Double(limit)),
            "next_offset":offset+page.count < spaces.count ? .number(Double(offset+page.count)):.null])
    }
}
