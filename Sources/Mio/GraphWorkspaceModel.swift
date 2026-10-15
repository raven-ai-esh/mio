import Foundation
import SwiftUI
import MioCore

@MainActor final class GraphWorkspaceModel: ObservableObject {
    enum Mode: String { case memory, history }
    @Published var mode: Mode = .memory
    @Published private(set) var nodes = [MemoryGraphNode]()
    @Published private(set) var edges = [MemoryGraphEdge]()
    @Published private(set) var layout = GraphLayoutResult(positions:[:],componentCount:0)
    @Published private(set) var calculating = false
    @Published private(set) var layoutFailure = ""
    @Published var fitToken = 0
    @Published var zoomCommand = 0
    @Published var selectedNodeID = ""
    @Published var showInspector = false
    @Published private(set) var detail: JSONValue = .null
    @Published private(set) var detailLoading = false
    @Published private(set) var detailFailure = ""
    @Published private(set) var inspectionRevisionID = ""
    @Published var sessionID = ""
    @Published private(set) var session: JSONValue = .null
    @Published private(set) var steps = [GraphReplayStep]()
    @Published private(set) var sessionLoading = false
    @Published private(set) var sessionFailure = ""
    @Published private(set) var stepIndex = 0
    @Published private(set) var playing = false
    @Published private(set) var purgedSourceIDs = Set<String>()
    @Published var nodeQuery = ""
    @Published private(set) var focusedSpaceIDs = Set<String>()
    private var spaceTree=MioSpaceTree(spaces:[])
    var effectiveFocusedSpaceIDs: Set<String> { focusedSpaceIDs.reduce(into:Set<String>()) { $0.formUnion(spaceTree.subtreeIDs(of:$1)) } }
    func updateSpaceHierarchy(_ spaces: [JSONValue]) { spaceTree=MioSpaceTree(spaces:spaces) }
    private var lastSidebarSpaceID: String?
    private var topology = ""
    private var layoutGeneration = 0
    private var layoutTask: Task<GraphLayoutResult,Error>?
    private var layoutCache = [String:GraphLayoutResult]()
    private var detailGeneration = 0
    var selectionGeneration: Int { detailGeneration }
    private var sessionGeneration = 0
    private var playbackTask: Task<Void,Never>?
    private var fileOwners = [String:String]()
    private var sourceEvents = [JSONValue]()
    var selectedStep: GraphReplayStep? { mode == .history && stepIndex > 0 && stepIndex <= steps.count ? steps[stepIndex-1] : nil }
    var highlights: GraphReplayHighlights { mode == .history ? MemoryGraphReplay.highlights(steps:steps,through:stepIndex) : .init() }
    var spaceFilterActive: Bool { !focusedSpaceIDs.isEmpty }
    var focusedNodeCount: Int {
        let nodes=displayNodes,focus=effectiveFocusedSpaceIDs
        return spaceFilterActive ? nodes.filter { focus.contains($0.spaceID) }.count:nodes.count
    }
    func toggleSpaceFocus(_ id: String) {
        if focusedSpaceIDs.contains(id) { focusedSpaceIDs.remove(id) } else { focusedSpaceIDs.insert(id) }
    }
    func showAllSpaces() { focusedSpaceIDs = [] }
    func focusSpace(_ id: String) { focusedSpaceIDs = id.isEmpty ? [] : [id] }
    func synchronizeSidebarSpace(_ id: String, available: Set<String>) {
        if lastSidebarSpaceID != id {
            focusedSpaceIDs = !id.isEmpty && available.contains(id) ? [id] : []
            lastSidebarSpaceID = id
        } else { focusedSpaceIDs.formIntersection(available) }
    }
    @Published var purgedSourceTitle = "Очищенный источник"
    var displayNodes: [MemoryGraphNode] { (mode == .history ? MemoryGraphReplay.referencedNodes(steps:steps,current:nodes) : nodes).map { purgedSourceIDs.contains($0.id) ? .init(id:$0.id,title:purgedSourceTitle,spaceID:$0.spaceID,status:"purged"):$0 } }
    var displayPositions: [String:GraphPoint] {
        var positions = layout.positions
        let additional = displayNodes.filter { positions[$0.id] == nil }.sorted { $0.id < $1.id }
        let observed = steps.flatMap(\.issuedEdges)
        let maxY = (positions.values.map(\.y).max() ?? 0)+110
        for (i,node) in additional.enumerated() {
            let anchors = observed.filter { $0.from == node.id || $0.to == node.id }.compactMap { positions[$0.from == node.id ? $0.to:$0.from] }
            let center = anchors.isEmpty ? GraphPoint(Double(i%16)*60-450,maxY+Double(i/16)*60) : GraphPoint(anchors.reduce(0){$0+$1.x}/Double(anchors.count),anchors.reduce(0){$0+$1.y}/Double(anchors.count))
            let angle = Double(i)*2.399963229728653
            positions[node.id] = GraphPoint(center.x+cos(angle)*50,center.y+sin(angle)*50)
        }
        return positions
    }
    func updateGraph(notes: [JSONValue], links: [JSONValue], force: Bool = false) {
        // Playback is a saved view: background agent calls don't move its map.
        guard mode == .memory || force else { return }
        let newNodes = notes.map(MemoryGraphNode.init).sorted { $0.id < $1.id }, ids = Set(newNodes.map(\.id))
        let newEdges = links.map(MemoryGraphEdge.init).filter { ids.contains($0.from) && ids.contains($0.to) }.sorted { $0.id < $1.id }
        if nodes != newNodes { nodes = newNodes }
        if edges != newEdges { edges = newEdges }
        fileOwners = [:]
        for note in notes { for file in note["file_ids"].items { fileOwners[file.text] = note.id } }
        let signature = MemoryGraphLayout.signature(nodes:newNodes,edges:newEdges)
        guard signature != topology || !layoutFailure.isEmpty else { return }
        topology = signature; layoutTask?.cancel(); layoutGeneration += 1
        let generation = layoutGeneration
        layoutFailure = ""
        if let cached = layoutCache[signature] { layout = cached; calculating = false; fitToken += 1; return }
        calculating = true
        let work = Task.detached(priority:.userInitiated) { try MemoryGraphLayout.calculate(nodes:newNodes,edges:newEdges) }
        layoutTask = work
        Task {
            do {
                let computed = try await work.value
                guard generation == layoutGeneration else { return }
                layout = computed; calculating = false; fitToken += 1
                if layoutCache.count >= 6 { layoutCache.removeAll() }
                layoutCache[signature] = computed
            } catch {
                guard generation == layoutGeneration else { return }
                calculating = false
                if !(error is CancellationError) { layoutFailure = error.localizedDescription }
            }
        }
    }
    func inspect(_ id: String, using model: AppModel) async {
        pause(); selectedNodeID = id; showInspector = true; detail = .null; detailLoading = true; detailFailure = ""
        detailGeneration += 1
        let generation = detailGeneration
        let revision = mode == .history ? steps.prefix(stepIndex).reversed().compactMap { $0.revision(for:id) }.first : nil
        inspectionRevisionID = revision ?? ""
        var params: [String:JSONValue] = ["kind":.string("note"),"id":.string(id)]
        if let revision { params["revision_id"] = .string(revision) }
        do {
            let value = try await model.execute("read",params)
            guard generation == detailGeneration, selectedNodeID == id else { return }
            detail = value; detailLoading = false
        } catch {
            guard generation == detailGeneration, selectedNodeID == id else { return }
            detailLoading = false; detailFailure = error.localizedDescription
        }
    }
    func dismissInspector() { showInspector = false; selectedNodeID = ""; detailGeneration += 1; detail = .null; detailLoading = false; detailFailure = "" }
    func invalidatePurgedSources(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        purgedSourceIDs.formUnion(ids)
        if ids.contains(selectedNodeID) { dismissInspector() }
        nodes.removeAll { ids.contains($0.id) }; edges.removeAll { ids.contains($0.from) || ids.contains($0.to) }
    }
    func loadMoreLinks(using model: AppModel) async {
        guard mode == .memory, detail["links_next_offset"] != .null else { return }
        let id = selectedNodeID, generation = detailGeneration, revision = detail["revision_id"]
        do {
            let page = try await model.execute("read",["kind":.string("note"),"id":.string(id),"offset":detail["links_next_offset"]])
            guard generation == detailGeneration, selectedNodeID == id, page["revision_id"] == revision else { return }
            var value = detail.fields; value["links"] = .array(detail["links"].items+page["links"].items); value["links_next_offset"] = page["links_next_offset"]; detail = .object(value)
        } catch { if generation == detailGeneration { detailFailure = error.localizedDescription } }
    }
    func setStep(_ index: Int) {
        pause(); moveStep(index)
    }
    private func moveStep(_ index: Int) {
        stepIndex = max(0,min(index,steps.count)); selectedNodeID = ""; detailGeneration += 1; detail = .null; detailLoading = false; detailFailure = ""
        showInspector = stepIndex > 0
    }
    func play() {
        guard !steps.isEmpty, !playing else { return }
        if stepIndex == steps.count { moveStep(0) }
        playing = true
        playbackTask = Task {
            while !Task.isCancelled && playing {
                moveStep(stepIndex+1)
                if stepIndex >= steps.count { playing = false; break }
                try? await Task.sleep(for:.milliseconds(1000))
            }
        }
    }
    func pause() { playing = false; playbackTask?.cancel(); playbackTask = nil }
    func clearSession() { pause(); sessionGeneration += 1; sessionID = ""; session = .null; sourceEvents = []; steps = []; sessionLoading = false; sessionFailure = ""; moveStep(0) }
    func loadSession(_ id: String, using model: AppModel) async {
        pause(); sessionGeneration += 1; let generation = sessionGeneration
        sessionID = id; sessionLoading = true; sessionFailure = ""; steps = []; sourceEvents = []; session = .null; moveStep(0)
        guard !id.isEmpty else { sessionLoading = false; return }
        do {
            var offset = 0, events = [JSONValue](), first: JSONValue?
            while true {
                try Task.checkCancellation()
                let page = try await model.execute("read",["kind":.string("session"),"id":.string(id),"offset":.number(Double(offset)),"limit":.number(100)])
                guard generation == sessionGeneration, sessionID == id else { return }
                if let first {
                    guard page["event_count"] == first["event_count"], page["updated_at"] == first["updated_at"] else { throw MioError("history_changed","История изменилась во время загрузки. Обновите сохранённый просмотр.") }
                } else { first = page }
                events += page["events"].items
                if page["next_offset"] == .null { break }
                let next = page["next_offset"].integer
                guard next > offset else { throw MioError("invalid_cursor","Не удалось загрузить следующую страницу истории") }
                offset = next
            }
            guard generation == sessionGeneration else { return }
            session = first ?? .null; sourceEvents = events
            steps = MemoryGraphReplay.steps(events:events,nodes:model.allNotes.map(MemoryGraphNode.init),fileOwners:fileOwners)
            sessionLoading = false
        } catch {
            guard generation == sessionGeneration else { return }
            sessionLoading = false; steps = []; sessionFailure = error.localizedDescription
        }
    }
    func openSession(_ id: String, using model: AppModel) async {
        updateGraph(notes:model.allNotes,links:model.links,force:true)
        mode = .history; model.tab = "graph"
        await loadSession(id,using:model)
    }
    func changeMode(using model: AppModel) {
        pause(); dismissInspector()
        if mode == .memory { sessionGeneration += 1; sessionLoading = false; updateGraph(notes:model.allNotes,links:model.links,force:true) }
        else { updateGraph(notes:model.allNotes,links:model.links,force:true) }
    }
    func shutdown() { pause(); layoutTask?.cancel(); detailGeneration += 1; sessionGeneration += 1; layoutGeneration += 1 }
}
