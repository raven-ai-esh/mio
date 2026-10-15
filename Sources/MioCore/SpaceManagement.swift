import Foundation

/// An organizational tree. Permission grants remain separate connections.
public struct MioSpaceTree: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let space: JSONValue
        public let depth: Int
        public var id: String { space["id"].stringValue ?? "" }
    }
    private let values: [String:JSONValue]
    private let parents: [String:String]
    private let children: [String:[String]]
    public init(spaces: [JSONValue]) {
        let values=Dictionary(spaces.filter { !$0["deleted"].boolValue }.compactMap { space in space["id"].stringValue.map { ($0,space) } },uniquingKeysWith: { _,last in last })
        var parents=[String:String]()
        for (id,space) in values { if let parent=space["parent_id"].stringValue,parent != id,values[parent] != nil { parents[id]=parent } }
        // Concurrent offline parent changes can form a cycle. Break one edge
        // deterministically in the view; retain the original records for repair.
        for start in values.keys.sorted() {
            var chain=[String](),seen=[String:Int](),cursor: String?=start
            while let id=cursor {
                if let index=seen[id] { parents.removeValue(forKey:chain[index...].min()!);break }
                seen[id]=chain.count;chain.append(id);cursor=parents[id]
            }
        }
        var children=[String:[String]]()
        for (id,parent) in parents { children[parent,default:[]].append(id) }
        for parent in Array(children.keys) { children[parent]!.sort { a,b in values[a]!["name"] == values[b]!["name"] ? a<b : (values[a]!["name"].stringValue ?? "") < (values[b]!["name"].stringValue ?? "") } }
        self.values=values;self.parents=parents;self.children=children
    }
    public func parent(of id: String) -> String? { parents[id] }
    public func childIDs(of id: String) -> [String] { children[id] ?? [] }
    public func subtreeIDs(of id: String) -> Set<String> {
        guard values[id] != nil else { return [] }
        var result=Set<String>(),pending=[id]
        while let next=pending.popLast() { if result.insert(next).inserted { pending += children[next] ?? [] } }
        return result
    }
    public func path(to id: String) -> [JSONValue] {
        var result=[JSONValue](),cursor: String?=id
        while let next=cursor,let space=values[next] { result.append(space);cursor=parents[next] }
        return result.reversed()
    }
    public var entries: [Entry] {
        let roots=values.keys.filter { parents[$0] == nil }.sorted { a,b in values[a]!["name"] == values[b]!["name"] ? a<b : (values[a]!["name"].stringValue ?? "") < (values[b]!["name"].stringValue ?? "") }
        var result=[Entry](),pending=roots.reversed().map { ($0,0) }
        while let (id,depth)=pending.popLast() { result.append(Entry(space:values[id]!,depth:depth));pending += (children[id] ?? []).reversed().map { ($0,depth+1) } }
        return result
    }
}

extension MioStore {
    func saveSpace(_ p: [String:JSONValue], _ s: Scope, creating: Bool) throws -> JSONValue {
        let id=creating ? UUID().uuidString.lowercased() : try p.required("space_id")
        var values: [String:JSONValue]
        if creating { values=["id":.string(id),"name":.string(""),"description":.string(""),"color":.string("blue"),"parent_id":.null,"deleted":.bool(false),"created_at":.string(now())] }
        else { try requireSpace(id,s,write:true);values=try entity("space",id)!.objectValue }
        if creating || p["name"] != nil {
            let name=try p.required("name").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty,name.count<=200 else { throw MioError("invalid_params","A space name must contain 1–200 characters") }
            values["name"] = .string(name)
        }
        for key in ["description","color"] where p[key] != nil {
            guard let value=p[key]?.stringValue,value.count <= (key == "description" ? 4000:64),key != "color" || !value.isEmpty else { throw MioError("invalid_params","Invalid space details") }
            values[key] = .string(value)
        }
        if let parent=p["parent_id"] {
            guard parent == .null || parent.stringValue != nil else { throw MioError("invalid_params","Parent must be a space ID") }
            if let parentID=parent.stringValue {
                try requireSpace(parentID,s)
                let allSpaces=try all("space");let byID=Dictionary(uniqueKeysWithValues:allSpaces.compactMap { item in item["id"].stringValue.map { ($0,item) } })
                var visited: Set<String>=[id],cursor: String?=parentID
                while let next=cursor {
                    guard visited.insert(next).inserted else { throw MioError("invalid_hierarchy","A space cannot be nested inside itself or its descendants") }
                    cursor=byID[next]?["parent_id"].stringValue
                }
            }
            values["parent_id"]=parent
        }
        _=try record("space",entityID:id,data:.object(values))
        return try entity("space",id)!
    }
}
