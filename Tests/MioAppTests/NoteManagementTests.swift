import XCTest
import MioCore
@testable import Mio

@MainActor final class NoteManagementTests: XCTestCase {
    var directory: URL!
    var model: AppModel!
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("mio-management-"+UUID().uuidString)
        setenv("MIO_DATA_DIRECTORY",directory.path,1)
        model=AppModel(startIndexing:false);await model.refresh()
    }
    override func tearDown() async throws { model.shutdown();model=nil;unsetenv("MIO_DATA_DIRECTORY");try? FileManager.default.removeItem(at:directory) }
    func testHierarchyHighlightsDescendantsAndMetadataReachesCatalog() async throws {
        let a=try await model.execute("space.create",["name":.string("Personal")])
        let b=try await model.execute("space.create",["name":.string("Family"),"parent_id":a["id"]])
        let other=try await model.execute("space.create",["name":.string("Other")])
        let n=try await model.execute("note.create",["space_id":b["id"],"title":.string("Family note")])
        let o=try await model.execute("note.create",["space_id":other["id"],"title":.string("Other note")])
        await model.refresh();model.selectSpace(a.id);model.focusNotesSpace(a.id)
        XCTAssertEqual(model.notesOpacity(n["note"]),1);XCTAssertEqual(model.notesOpacity(o["note"]),0.06);XCTAssertEqual(model.emphasizedNoteCount,1)
        model.graph.focusSpace(a.id);XCTAssertEqual(model.graph.effectiveFocusedSpaceIDs,[a.id,b.id])
        XCTAssertEqual(model.spaceEntries.first(where:{$0.id == b.id})?.depth,1)
        let saved=await model.saveSpaceDetails(id:b.id,name:"Genealogy",description:"Family evidence",color:"purple",parent:a.id);XCTAssertTrue(saved)
        let catalog=try await model.execute("read",["kind":.string("spaces")])
        XCTAssertEqual(catalog["spaces"].items.first(where:{$0.id == b.id})?["description"],.string("Family evidence"))
    }
    func testBulkMoveStatusDeleteRetainUnsavedDraftAndRestore() async throws {
        let a=try await model.execute("space.create",["name":.string("A")]),b=try await model.execute("space.create",["name":.string("B")])
        let n=try await model.execute("note.create",["space_id":a["id"],"title":.string("Draft note"),"body":.string("Saved")])
        await model.refresh();model.selectNote(n.id);await model.loadSelectedNote()
        model.stageDraft(id:n.id,title:"Draft note",body:"UNSAVED",revision:n["revision_id"].text,status:"hypothesis")
        await model.bulkNotes("move",ids:[n.id],destination:b.id)
        XCTAssertEqual(model.selectedNoteValue["space_id"],b["id"]);XCTAssertEqual(model.preferences.drafts[n.id]?.body,"UNSAVED")
        await model.bulkNotes("status",ids:[n.id],status:"confirmed")
        let saved=try await model.execute("read",["id":n["id"]])
        XCTAssertEqual(saved["body"],.string("Saved"));XCTAssertEqual(model.preferences.drafts[n.id]?.body,"UNSAVED")
        XCTAssertEqual(model.preferences.drafts[n.id]?.revision,saved["revision_id"].text)
        XCTAssertEqual(model.preferences.drafts[n.id]?.status,"confirmed")
        await model.bulkNotes("delete",ids:[n.id]);XCTAssertEqual(model.deletedNotes.count,1);XCTAssertEqual(model.preferences.drafts[n.id]?.body,"UNSAVED")
        _=try await model.execute("note.restore",["note_id":n["id"],"revision_id":saved["revision_id"]]);await model.refresh()
        XCTAssertEqual(model.notesInLiveSpaces.count,1);XCTAssertEqual(model.preferences.drafts[n.id]?.body,"UNSAVED")
    }
}

extension NoteManagementTests {
    func testNativeDragProviderAndDropMoveOnlySameWindowSelection() async throws {
        let a=try await model.execute("space.create",["name":.string("A")]),b=try await model.execute("space.create",["name":.string("B")])
        let n=try await model.execute("note.create",["space_id":a["id"],"title":.string("Drag me")]);await model.refresh()
        model.notesSelectionChanged([n.id]);let provider=model.noteDragProvider(for:n.id)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(MioNoteDrag.contentType.identifier))
        let bytes: Data=try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier:MioNoteDrag.typeID) { data,error in if let data { continuation.resume(returning:data) } else { continuation.resume(throwing:error ?? CocoaError(.fileReadUnknown)) } }
        }
        let drag=try JSONDecoder().decode(MioNoteDrag.self,from:bytes);XCTAssertEqual(drag.sessionID,model.dragSessionID);XCTAssertEqual(drag.spaces,[n.id:a.id])
        XCTAssertTrue(model.acceptNoteDrop([provider],destination:b.id))
        for _ in 0..<100 { if model.allNotes.first?["space_id"] == b["id"] { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.allNotes.first?["space_id"],b["id"])
        let foreign=NSItemProvider(),data=try JSONEncoder().encode(MioNoteDrag(sessionID:UUID().uuidString,spaces:[n.id:b.id]))
        foreign.registerDataRepresentation(forTypeIdentifier:MioNoteDrag.typeID,visibility:.ownProcess) { completion in completion(data,nil);return nil }
        XCTAssertTrue(model.acceptNoteDrop([foreign],destination:a.id))
        for _ in 0..<100 { if !model.failure.isEmpty { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(model.failure.isEmpty);XCTAssertEqual(model.allNotes.first?["space_id"],b["id"])
    }
}
