import Foundation
import MioCore

struct NoteListProjection: Sendable {
    private var input:[JSONValue]=[],spaces:[JSONValue]=[]
    private var selection=Set<String>()
    private var ordered:[JSONValue]=[]
    private(set) var all:[JSONValue]=[],deleted:[JSONValue]=[],live:[JSONValue]=[],display:[JSONValue]=[]
    private(set) var focus=Set<String>()
    private(set) var emphasized=0
    mutating func update(notes:[JSONValue],spaces:[JSONValue],selected:Set<String>) {
        let metadataChanged=input != notes || self.spaces != spaces
        guard metadataChanged || selection != selected else { return }
        if metadataChanged {
            input=notes;self.spaces=spaces
            let retained=notes.filter { !$0["redacted"].boolValue && !$0["purged"].boolValue && $0["status"] != .string("purged") }
            all=retained.filter { !$0["deleted"].boolValue };deleted=retained.filter { $0["deleted"].boolValue }
            let available=Set(spaces.filter{!$0["deleted"].boolValue}.map(\.id))
            live=all.filter { available.contains($0["space_id"].text) }
            ordered=live.sorted { $0["updated_at"] == $1["updated_at"] ? $0.id < $1.id:$0["updated_at"].text > $1["updated_at"].text }
        }
        selection=selected
        let tree=MioSpaceTree(spaces:spaces)
        focus=selected.reduce(into:Set<String>()) { $0.formUnion(tree.subtreeIDs(of:$1)) }
        if selected.isEmpty { display=ordered;emphasized=live.count }
        else {
            let matching=ordered.filter { focus.contains($0["space_id"].text) }
            emphasized=matching.count
            display=matching+ordered.filter { !focus.contains($0["space_id"].text) }
        }
    }
}
