import Foundation

public struct GraphReplayStep: Identifiable, Sendable {
    public let id: String
    public let method: String
    public let startedAt: String
    public let sourceSequence: Int
    public let endSequence: Int?
    public let finishedAt: String
    public let outcome: String
    public let query: String
    public let durationMS: Double?
    public let request: JSONValue
    public let refs: [JSONValue]
    public let events: [JSONValue]
    public let noteIDs: [String]
    public let issuedGraph: JSONValue
    public let replayed: Bool
    public let deliveryFailed: Bool
    public var isRead: Bool { method == "read" }
    public var isSearch: Bool { method == "search" }
    public var isMutation: Bool { ["note.create","note.update","link.create","note.delete","link.delete"].contains(method) }
    public var isFailure: Bool { !["success","in_progress"].contains(outcome) || deliveryFailed }
    public var hasRecordedGraph: Bool { issuedGraph["state"].stringValue == "recorded" }
    public var issuedEdges: [MemoryGraphEdge] { hasRecordedGraph ? issuedGraph["links"].arrayValue.map(MemoryGraphEdge.init) : [] }
    public func revision(for id: String) -> String? {
        if let ref = refs.first(where: { ($0["note_id"].stringValue ?? $0["id"].stringValue) == id }), let version = ref["revision_id"].stringValue, !version.isEmpty { return version }
        if issuedGraph["note_id"].stringValue == id { return issuedGraph["revision_id"].stringValue }
        return issuedGraph["links"].arrayValue.first { $0["note"]["id"].stringValue == id }?["note"]["revision_id"].stringValue
    }
}

public struct GraphReplayHighlights: Sendable {
    public var candidates = Set<String>()
    public var reads = Set<String>()
    public var mutations = Set<String>()
    public var failures = Set<String>()
    public var current = Set<String>()
    public var transitions = [(String,String,Int)]()
    public var issuedEdges = [MemoryGraphEdge]()
    public init() {}
}

public enum MemoryGraphReplay {
    // START, END and multiple delivery observations are one logical call.
    // Retry attempts keep their distinct interaction IDs and remain steps.
    public static func steps(events: [JSONValue], nodes: [MemoryGraphNode], fileOwners: [String:String] = [:]) -> [GraphReplayStep] {
        let known = Set(nodes.map(\.id))
        let eligible = events.filter { $0["kind"].stringValue == "memory_operation" && !$0["purged"].boolValue && !($0["interaction_id"].stringValue ?? "").isEmpty && $0["accepted_by_projection"].boolValue }
        let groups = Dictionary(grouping:eligible) { $0["interaction_id"].stringValue! }
        return groups.map { id, group in
            let ordered = group.sorted { $0["source_sequence"].intValue == $1["source_sequence"].intValue ? ($0["timestamp"].stringValue ?? "") < ($1["timestamp"].stringValue ?? "") : $0["source_sequence"].intValue < $1["source_sequence"].intValue }
            let start = ordered.first { $0["phase"].stringValue == "start" }
            let end = ordered.last { $0["phase"].stringValue == "end" }
            let anchor = start ?? end ?? ordered[0], method = anchor["method"].stringValue ?? "read"
            let request = anchor["request"], refs = end?["result_refs"].arrayValue ?? []
            var ids = [String](), seen = Set<String>()
            func add(_ value: String?) { if let value, !value.isEmpty, seen.insert(value).inserted { ids.append(value) } }
            for ref in refs {
                add(ref["note_id"].stringValue)
                add(ref["from_note_id"].stringValue); add(ref["to_note_id"].stringValue)
                if let refID = ref["id"].stringValue, known.contains(refID) || ref["kind"].stringValue == "note" { add(refID) }
            }
            if method == "read", request["kind"].stringValue == "note" { add(request["id"].stringValue) }
            if let requested = request["id"].stringValue, let owner = fileOwners[requested] { add(owner) }
            if method == "note.update" || method == "note.delete" { add(request["note_id"].stringValue) }
            if method == "link.create" || method == "link.delete" { add(request["from_note_id"].stringValue); add(request["to_note_id"].stringValue) }
            return GraphReplayStep(id:id,method:method,startedAt:anchor["started_at"].stringValue ?? anchor["timestamp"].stringValue ?? "",sourceSequence:anchor["source_sequence"].intValue,endSequence:end?["source_sequence"].intValue,finishedAt:end?["finished_at"].stringValue ?? "",outcome:end?["outcome"].stringValue ?? "in_progress",query:request["query"].stringValue ?? "",durationMS:end?["duration_ms"].doubleValue,request:request,refs:refs,events:ordered,noteIDs:ids,issuedGraph:end?["issued_graph"] ?? .null,replayed:end?["replayed"].boolValue ?? false,deliveryFailed:ordered.contains { ["stdout_write_failed","socket_write_failed","frame_too_large"].contains($0["delivery_state"].stringValue ?? "") })
        }.sorted { $0.sourceSequence == $1.sourceSequence ? ($0.startedAt == $1.startedAt ? $0.id < $1.id:$0.startedAt < $1.startedAt):$0.sourceSequence < $1.sourceSequence }
    }
    public static func highlights(steps: [GraphReplayStep], through count: Int) -> GraphReplayHighlights {
        var result = GraphReplayHighlights(), lastRead: GraphReplayStep?
        let selected = Array(steps.prefix(max(0,min(count,steps.count))))
        for (index,step) in selected.enumerated() {
            let ids = Set(step.noteIDs)
            if step.isSearch && step.outcome == "success" { result.candidates.formUnion(ids) }
            if step.isRead && step.outcome == "success" {
                result.reads.formUnion(ids)
                // This arrow means call order, never a claimed causal traversal.
                // Overlapping calls do not receive an invented serial transition.
                if let prior = lastRead, !prior.finishedAt.isEmpty, let end = prior.endSequence, end < step.sourceSequence,
                   let from = prior.noteIDs.first, let to = step.noteIDs.first { result.transitions.append((from,to,index+1)) }
                lastRead = step
            }
            if step.isMutation && step.outcome == "success" { result.mutations.formUnion(ids) }
            if step.isFailure { result.failures.formUnion(ids) }
        }
        if let current = selected.last { result.current = Set(current.noteIDs); result.issuedEdges = current.issuedEdges }
        return result
    }
    public static func referencedNodes(steps: [GraphReplayStep], current: [MemoryGraphNode]) -> [MemoryGraphNode] {
        var nodes = Dictionary(uniqueKeysWithValues: current.map { ($0.id,$0) })
        let currentIDs = Set(current.map(\.id))
        func remember(_ node: MemoryGraphNode) {
            guard !currentIDs.contains(node.id) else { return }
            if let existing = nodes[node.id] {
                if existing.spaceID.isEmpty && !node.spaceID.isEmpty { nodes[node.id] = .init(id:existing.id,title:existing.title,spaceID:node.spaceID,revisionID:existing.revisionID,status:existing.status) }
            } else { nodes[node.id] = node }
        }
        for step in steps {
            for id in step.noteIDs {
                let space = step.refs.first { ($0["note_id"].stringValue ?? $0["id"].stringValue) == id && !($0["space_id"].stringValue ?? "").isEmpty }?["space_id"].stringValue ?? ""
                remember(.init(id:id,title:"Источник \(id.prefix(8))",spaceID:space,revisionID:step.revision(for:id) ?? ""))
            }
            for edge in step.issuedGraph["links"].arrayValue {
                let value = edge["note"], id = value["id"].stringValue ?? ""
                if !id.isEmpty { remember(MemoryGraphNode(value)) }
            }
        }
        return nodes.values.sorted { $0.id < $1.id }
    }
}

private extension JSONValue {
    var doubleValue: Double? { if case .number(let value) = self { return value }; return nil }
}
