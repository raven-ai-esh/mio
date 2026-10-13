import XCTest
@testable import MioCore

final class GraphLayoutPlaybackTests: XCTestCase {
    func testHistoricalPlaceholderUsesOnlyRecordedSpaceEvidence() {
        func event(_ id: String, refs: [JSONValue], neighbors: [JSONValue] = []) -> JSONValue {
            .object(["id":.string(id),"kind":.string("memory_operation"),"accepted_by_projection":.bool(true),"interaction_id":.string(id),"phase":.string("end"),"method":.string("read"),"outcome":.string("success"),"request":.object(["kind":.string("note"),"id":.string("gone")]),"result_refs":.array(refs),"issued_graph":.object(["state":.string("recorded"),"links":.array(neighbors.map{.object(["note":$0])})])])
        }
        func projected(_ events: [JSONValue]) -> MemoryGraphNode? {
            MemoryGraphReplay.referencedNodes(steps:MemoryGraphReplay.steps(events:events,nodes:[]),current:[]).first{$0.id=="gone"}
        }
        let ref:JSONValue = .object(["id":.string("gone"),"note_id":.string("gone"),"space_id":.string("work"),"revision_id":.string("r1")])
        XCTAssertEqual(projected([event("recorded",refs:[ref])])?.spaceID,"work")
        let neighbor:JSONValue = .object(["id":.string("gone"),"space_id":.string("research"),"revision_id":.string("r2")])
        XCTAssertEqual(projected([event("neighbor",refs:[],neighbors:[neighbor])])?.spaceID,"research")
        XCTAssertEqual(projected([event("unknown",refs:[])])?.spaceID,"")
        XCTAssertEqual(projected([event("a-unknown",refs:[]),event("b-recorded",refs:[ref])])?.spaceID,"work")
    }
    func testCompleteDeterministicLayoutAndSeparateComponents() throws {
        let nodes = (0..<1300).map { MemoryGraphNode(id:"n\($0)") }
        let edges = (1..<1200).map { MemoryGraphEdge(id:"e\($0)",from:"n\($0-1)",to:"n\($0)") }
        let first = try MemoryGraphLayout.calculate(nodes:nodes,edges:edges,iterations:30)
        let second = try MemoryGraphLayout.calculate(nodes:nodes.reversed(),edges:edges.reversed(),iterations:30)
        XCTAssertEqual(first.positions.count,1300)
        XCTAssertEqual(first.componentCount,101)
        XCTAssertEqual(first.positions,second.positions)
        XCTAssertTrue(first.positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(Set(first.positions.values).count,1300)
        XCTAssertTrue(try MemoryGraphLayout.calculate(nodes:[],edges:[]).positions.isEmpty)
    }
    func testLinkedCommunitiesAreCloserInsideThanAcrossBridge() throws {
        let nodes = (0..<20).map { MemoryGraphNode(id:"n\($0)") }
        var edges = [MemoryGraphEdge]()
        for base in [0,10] { for a in base..<(base+10) { for b in (a+1)..<(base+10) { edges.append(.init(id:"\(a)-\(b)",from:"n\(a)",to:"n\(b)")) } } }
        edges.append(.init(id:"bridge",from:"n0",to:"n10"))
        let layout = try MemoryGraphLayout.calculate(nodes:nodes,edges:edges)
        func average(_ a: Range<Int>,_ b: Range<Int>) -> Double { let d = a.flatMap { i in b.filter{$0 != i}.map{j in layout.positions["n\(i)"]!.distance(to:layout.positions["n\(j)"]!)} }; return d.reduce(0,+)/Double(d.count) }
        XCTAssertGreaterThan(average(0..<10,10..<20),average(0..<10,0..<10)*1.6)
    }
    func event(_ call: String, _ phase: String, _ method: String, _ second: Int, note: String = "", extra: [String:JSONValue] = [:]) -> JSONValue {
        let timestamp = String(format:"2026-10-12T10:00:%02d.000Z",second)
        var data: [String:JSONValue] = ["id":.string(call+phase),"kind":.string("memory_operation"),"interaction_id":.string(call),"phase":.string(phase),"method":.string(method),"timestamp":.string(timestamp),"started_at":.string(timestamp),"source_sequence":.number(Double(second)),"outcome":.string(phase == "start" ? "in_progress":"success"),"request":.object(["kind":.string("note"),"id":.string(note)]),"result_refs":.array(note.isEmpty ? []:[.object(["id":.string(note),"kind":.string("note"),"revision_id":.string("r-"+note)])])]
        if phase == "end" { data["finished_at"] = .string(timestamp) }
        data["accepted_by_projection"] = .bool(true)
        for (k,v) in extra { data[k] = v }
        return .object(data)
    }
    func testTechnicalPhasesMergeRetriesRemainAndScrubbingRecomputes() {
        let nodes = [MemoryGraphNode(id:"A"),MemoryGraphNode(id:"C")]
        let events = [event("s","start","search",0),event("s","end","search",1,note:"A"),event("s","delivery","search",2),event("s","delivery","search",3),event("a","start","read",4,note:"A"),event("a","end","read",5,note:"A"),event("c","start","read",6,note:"C"),event("c","end","read",7,note:"C"),event("retry","start","read",8,note:"C"),event("retry","end","read",9,note:"C",extra:["replayed":.bool(true)])]
        let steps = MemoryGraphReplay.steps(events:events.reversed(),nodes:nodes)
        XCTAssertEqual(steps.count,4)
        XCTAssertEqual(steps.map(\.id),["s","a","c","retry"])
        XCTAssertEqual(steps.last?.revision(for:"C"),"r-C")
        let final = MemoryGraphReplay.highlights(steps:steps,through:4)
        XCTAssertEqual(final.candidates,Set(["A"]))
        XCTAssertEqual(final.reads,Set(["A","C"]))
        XCTAssertEqual(final.transitions.count,2)
        XCTAssertEqual(final.transitions.last?.0,"C"); XCTAssertEqual(final.transitions.last?.1,"C")
        XCTAssertTrue(MemoryGraphReplay.highlights(steps:steps,through:1).reads.isEmpty)
        XCTAssertTrue(MemoryGraphReplay.highlights(steps:steps,through:0).candidates.isEmpty)
        XCTAssertFalse(steps[1].hasRecordedGraph)
    }
    func testFailurePendingOverlapAndPurgedEventsDoNotInventRoute() {
        let nodes = [MemoryGraphNode(id:"A"),MemoryGraphNode(id:"C")]
        let events = [event("a","start","read",0,note:"A"),event("c","start","read",1,note:"C"),event("a","end","read",3,note:"A"),event("c","end","read",4,note:"C"),event("bad","start","read",5,note:"A"),event("bad","end","read",6,note:"A",extra:["outcome":.string("error")]),event("pending","start","read",7,note:"C"),event("purged","end","read",8,note:"A",extra:["purged":.bool(true)]),.object(["kind":.string("message"),"interaction_id":.string("chat")])]
        let steps = MemoryGraphReplay.steps(events:events,nodes:nodes)
        XCTAssertEqual(steps.count,4)
        let h = MemoryGraphReplay.highlights(steps:steps,through:steps.count)
        XCTAssertTrue(h.transitions.isEmpty)
        XCTAssertEqual(h.failures,Set(["A"]))
        XCTAssertEqual(steps.last?.outcome,"in_progress")
    }
    func testSameMillisecondUsesRecordedSequenceAndRawEventsAreUntrusted() {
        var first = event("z-first","start","read",0,note:"A").objectValue
        var second = event("a-second","start","read",0,note:"C").objectValue
        first["source_sequence"] = .number(4); second["source_sequence"] = .number(7)
        let steps = MemoryGraphReplay.steps(events:[.object(second),.object(first)],nodes:[])
        XCTAssertEqual(steps.map(\.id),["z-first","a-second"])
        first.removeValue(forKey:"accepted_by_projection")
        XCTAssertTrue(MemoryGraphReplay.steps(events:[.object(first)],nodes:[]).isEmpty)
    }
}
