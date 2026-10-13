import XCTest
import AppKit
@testable import Mio
@testable import MioCore

@MainActor final class GraphWorkspaceTests: XCTestCase {
    var directory: URL!
    var model: AppModel!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mio-graph-ui-"+UUID().uuidString)
        setenv("MIO_DATA_DIRECTORY",directory.path,1)
        model = AppModel(startIndexing:false); await model.refresh()
    }
    override func tearDown() async throws { model.shutdown(); model = nil; unsetenv("MIO_DATA_DIRECTORY"); try? FileManager.default.removeItem(at:directory) }
    func testGraphInspectionPreservesEditorDraftAndRapidSelectionAndFailureRetry() async throws {
        let space = try await model.execute("space.create",["name":.string("Graph")])["id"]
        let a = try await model.execute("note.create",["space_id":space,"title":.string("A"),"body":.string("full selected A")])
        let b = try await model.execute("note.create",["space_id":space,"title":.string("B"),"body":.string("full selected B")])
        await model.refresh(); model.selectNote(a.id); await model.loadSelectedNote()
        model.stageDraft(id:a.id,title:"unsaved",body:"PRIVATE_DRAFT",revision:a["revision_id"].text,status:"hypothesis")
        let drafts = model.preferences.drafts[a.id]!.body
        model.tab = "graph"; model.graph.updateGraph(notes:model.visibleNotes,links:model.links)
        let first = Task { await model.graph.inspect(a.id,using:model) }
        while model.graph.selectedNodeID != a.id { await Task.yield() }
        await model.graph.inspect(b.id,using:model); await first.value
        XCTAssertEqual(model.tab,"graph"); XCTAssertEqual(model.selectedNote,a.id)
        XCTAssertEqual(model.preferences.drafts[a.id]?.body,drafts)
        XCTAssertEqual(model.graph.selectedNodeID,b.id); XCTAssertEqual(model.graph.detail["body"].text,"full selected B")
        await model.graph.inspect("missing",using:model)
        XCTAssertFalse(model.graph.detailFailure.isEmpty); XCTAssertFalse(model.graph.detailLoading)
        await model.graph.inspect(a.id,using:model)
        XCTAssertTrue(model.graph.detailFailure.isEmpty); XCTAssertEqual(model.graph.detail["body"].text,"full selected A")
        XCTAssertEqual(model.tab,"graph")
    }
    func testNativeDrawingIncludesAllNodesEdgesAndHitCoordinates() throws {
        let view = MemoryGraphCanvasView(frame:CGRect(x:0,y:0,width:1100,height:700))
        view.nodes = (0..<1300).map{MemoryGraphNode(id:"n\($0)",title:"Node \($0)")}
        view.edges = (1..<1300).map{MemoryGraphEdge(id:"e\($0)",from:"n\($0-1)",to:"n\($0)")}
        view.positions = Dictionary(uniqueKeysWithValues:(0..<1300).map{("n\($0)",GraphPoint(Double($0%50)*20,Double($0/50)*20))})
        view.fit()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        XCTAssertEqual(view.renderedNodes,1300); XCTAssertEqual(view.renderedEdges,1299)
        XCTAssertNotNil(view.screen("n1299")); XCTAssertGreaterThan(bitmap.pixelsWide,0)
    }
    func testPaginatedPlaybackUsesOldVersionAndPurgingClearsCachedReplay() async throws {
        let home = try await model.execute("space.create",["name":.string("Home")])["id"]
        let target = try await model.execute("space.create",["name":.string("Target")])["id"]
        _ = try await model.execute("connection.create",["from_space_id":home,"to_space_id":target,"access":.string("write")])
        let note = try await model.execute("note.create",["space_id":target,"title":.string("Historical"),"body":.string("OLD_GRAPH_VERSION")])
        let profile = try await model.execute("profile.create",["space_id":home,"name":.string("Agent")])
        let store = try XCTUnwrap(model.store), context = AccessContext.agent(token:profile["token"].text)
        var result: JSONValue = .null
        for i in 0..<56 { result = try store.execute("read",params:["kind":.string("note"),"id":note["id"],"_mio_interaction":.object(["transport_session_id":.string("long-history"),"request_id":.string("r\(i)")])],context:context) }
        _ = try store.execute("interaction.session.end",params:["_mio_interaction":.object(["transport_session_id":.string("long-history"),"request_id":.string("end")])],context:context)
        _ = try await model.execute("note.update",["note_id":note["id"],"expected_revision":note["revision_id"],"title":.string("Historical"),"body":.string("CURRENT_GRAPH_VERSION")])
        await model.refresh(); model.selectSpace(target.text)
        XCTAssertTrue(model.visibleSessions.contains{$0.id == result["interaction_session_id"].text})
        await model.graph.openSession(result["interaction_session_id"].text,using:model)
        XCTAssertTrue(model.graph.sessionFailure.isEmpty); XCTAssertEqual(model.graph.steps.count,56)
        model.graph.setStep(1); await model.graph.inspect(note.id,using:model)
        XCTAssertEqual(model.graph.detail["body"].text,"OLD_GRAPH_VERSION")
        XCTAssertEqual(model.graph.inspectionRevisionID,note["revision_id"].text)
        let historicalDetail = model.graph.detail, positions = model.graph.layout.positions
        model.graph.toggleSpaceFocus(home.text)
        XCTAssertEqual(model.graph.stepIndex,1); XCTAssertEqual(model.graph.detail,historicalDetail)
        XCTAssertEqual(model.graph.layout.positions,positions)
        model.graph.showAllSpaces()
        model.graph.mode = .memory; model.graph.changeMode(using:model); XCTAssertNil(model.graph.selectedStep)
        model.graph.mode = .history; model.graph.changeMode(using:model); XCTAssertNotNil(model.graph.selectedStep)
        model.graph.setStep(0); await model.graph.inspect(note.id,using:model)
        XCTAssertEqual(model.graph.detail["body"].text,"CURRENT_GRAPH_VERSION"); XCTAssertTrue(model.graph.inspectionRevisionID.isEmpty)
        model.graph.setStep(1); model.graph.play(); model.graph.pause()
        let index = model.graph.stepIndex; try await Task.sleep(for:.milliseconds(50)); XCTAssertEqual(model.graph.stepIndex,index)
        _ = try await model.execute("history.purge",["session_id":result["interaction_session_id"]]); await model.refresh()
        XCTAssertTrue(model.graph.sessionID.isEmpty); XCTAssertTrue(model.graph.steps.isEmpty); XCTAssertFalse(model.graph.playing)
    }
    func testClearedSourceInvalidatesReadOnlyGraphContent() async throws {
        let space = try await model.execute("space.create",["name":.string("Clear source")])["id"]
        let note = try await model.execute("note.create",["space_id":space,"title":.string("private title"),"body":.string("PRIVATE_LOADED_GRAPH_BODY")])
        await model.refresh(); model.graph.updateGraph(notes:model.visibleNotes,links:model.links)
        await model.graph.inspect(note.id,using:model)
        let generation = model.graph.selectionGeneration
        XCTAssertEqual(model.graph.detail["body"].text,"PRIVATE_LOADED_GRAPH_BODY")
        _ = try model.store!.record("note.redact",entityID:note.id,data:.object(["note_id":note["id"]]))
        await model.refresh()
        XCTAssertTrue(model.graph.selectedNodeID.isEmpty); XCTAssertEqual(model.graph.detail,.null)
        XCTAssertGreaterThan(model.graph.selectionGeneration,generation)
        XCTAssertFalse(model.graph.nodes.contains{$0.id==note.id})
    }
    func testNativeSelfLinkProducesVisiblePixels() throws {
        let view = MemoryGraphCanvasView(frame:CGRect(x:0,y:0,width:300,height:220))
        view.nodes = [MemoryGraphNode(id:"self")]; view.positions = ["self":GraphPoint(0,0)]; view.fit()
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap)
            return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        }
        let without = try pixels()
        view.edges = [.init(id:"loop",from:"self",to:"self")]
        let with = try pixels()
        XCTAssertNotEqual(without,with); XCTAssertEqual(view.renderedEdges,1)
    }
    func testSpaceFilterRetainsOtherSpacesAndDoesNotMoveGraphOrEditor() async throws {
        let a = try await model.execute("space.create",["name":.string("A")])["id"].text
        let b = try await model.execute("space.create",["name":.string("B")])["id"].text
        let empty = try await model.execute("space.create",["name":.string("Empty")])["id"].text
        let note = try await model.execute("note.create",["space_id":.string(a),"title":.string("A note"),"body":.string("A")])
        _ = try await model.execute("note.create",["space_id":.string(b),"title":.string("B note"),"body":.string("B")])
        await model.refresh(); model.selectSpace(a); model.selectNote(note.id); model.tab = "graph"
        let graph = model.graph, available = Set(model.spaces.map(\.id))
        graph.synchronizeSidebarSpace(a,available:available)
        graph.changeMode(using:model)
        while graph.calculating { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(graph.nodes.count,2); XCTAssertEqual(graph.focusedNodeCount,1)
        let positions = graph.layout.positions, fit = graph.fitToken
        graph.toggleSpaceFocus(b)
        XCTAssertEqual(graph.focusedSpaceIDs,Set([a,b])); XCTAssertEqual(graph.focusedNodeCount,2)
        XCTAssertEqual(graph.layout.positions,positions); XCTAssertEqual(graph.fitToken,fit)
        XCTAssertEqual(model.selectedSpace,a); XCTAssertEqual(model.selectedNote,note.id); XCTAssertEqual(model.tab,"graph")
        graph.showAllSpaces(); graph.synchronizeSidebarSpace(a,available:available)
        XCTAssertFalse(graph.spaceFilterActive) // Re-entering graph preserves a manual reset.
        graph.focusSpace(a); XCTAssertEqual(graph.focusedSpaceIDs,[a])
        graph.toggleSpaceFocus(b); graph.focusSpace(a); XCTAssertEqual(graph.focusedSpaceIDs,[a])
        graph.focusSpace(""); XCTAssertFalse(graph.spaceFilterActive)
        graph.toggleSpaceFocus(empty); XCTAssertEqual(graph.focusedNodeCount,0); XCTAssertEqual(graph.nodes.count,2)
        graph.synchronizeSidebarSpace(a,available:available.subtracting([empty]))
        XCTAssertFalse(graph.spaceFilterActive)
        graph.synchronizeSidebarSpace(b,available:available)
        XCTAssertEqual(graph.focusedSpaceIDs,[b]); XCTAssertEqual(graph.nodes.count,2)
        graph.synchronizeSidebarSpace("",available:available); XCTAssertFalse(graph.spaceFilterActive)
    }
    func testNativeSpaceDimmingKeepsNodesEdgesAndAppliesToReplayOverlays() throws {
        let view = MemoryGraphCanvasView(frame:CGRect(x:0,y:0,width:600,height:300))
        view.nodes = [MemoryGraphNode(id:"a1",spaceID:"a"),MemoryGraphNode(id:"a2",spaceID:"a"),MemoryGraphNode(id:"b1",spaceID:"b"),MemoryGraphNode(id:"b2",spaceID:"b")]
        view.colors = ["a":.systemBlue,"b":.systemBlue]
        view.positions = ["a1":GraphPoint(-180,0),"a2":GraphPoint(-60,0),"b1":GraphPoint(60,0),"b2":GraphPoint(180,0)]
        view.edges = [.init(id:"a",from:"a1",to:"a2"),.init(id:"cross",from:"a2",to:"b1"),.init(id:"b",from:"b1",to:"b2")]
        view.fit()
        func contrast(_ id: String) throws -> Double {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap)
            let point = try XCTUnwrap(view.screen(id)), sx = Double(bitmap.pixelsWide)/view.bounds.width, sy = Double(bitmap.pixelsHigh)/view.bounds.height
            let color = try XCTUnwrap(bitmap.colorAt(x:Int(point.x*sx),y:Int(point.y*sy))?.usingColorSpace(.deviceRGB))
            let background = try XCTUnwrap(bitmap.colorAt(x:2,y:2)?.usingColorSpace(.deviceRGB))
            return abs(color.redComponent-background.redComponent)+abs(color.greenComponent-background.greenComponent)+abs(color.blueComponent-background.blueComponent)
        }
        let before = try contrast("b1"), aBefore = try contrast("a1"), coordinate = view.screen("b1")
        XCTAssertGreaterThan(before,0.3)
        view.focusedSpaceIDs = ["a"]
        XCTAssertLessThan(try contrast("b1"),before*0.15)
        XCTAssertGreaterThan(try contrast("b1"),0)
        XCTAssertEqual(try contrast("a1"),aBefore,accuracy:0.03)
        XCTAssertEqual(view.renderedNodes,4); XCTAssertEqual(view.renderedEdges,3); XCTAssertEqual(view.screen("b1"),coordinate)
        let emphasis = GraphSpaceEmphasis(nodes:view.nodes,focusedSpaceIDs:["a"])
        XCTAssertEqual(emphasis.edgeOpacity("a1","a2"),1)
        XCTAssertGreaterThan(emphasis.edgeOpacity("a2","b1"),emphasis.edgeOpacity("b1","b2"))
        XCTAssertLessThan(emphasis.edgeOpacity("a2","b1"),1)
        view.history = true; view.highlights.reads = Set(view.nodes.map(\.id)); view.highlights.current = ["b1"]; view.selected = "b1"; view.highlights.issuedEdges = view.edges; view.highlights.transitions = [("b1","b2",2)]
        XCTAssertLessThan(try contrast("b1"),before*0.15)
        view.focusedSpaceIDs = ["a","b"]; XCTAssertGreaterThan(try contrast("b1"),before*0.7)
        view.focusedSpaceIDs = []; XCTAssertGreaterThan(try contrast("b1"),before*0.7)
    }
}
