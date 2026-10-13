import XCTest
import MioCore
@testable import Mio

@MainActor final class NotesSpaceFilterTests: XCTestCase {
    var directory: URL!
    var model: AppModel!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mio-notes-filter-"+UUID().uuidString)
        setenv("MIO_DATA_DIRECTORY",directory.path,1)
        model = AppModel(startIndexing:false); await model.refresh()
    }
    override func tearDown() async throws {
        model.shutdown(); model = nil; unsetenv("MIO_DATA_DIRECTORY"); try? FileManager.default.removeItem(at:directory)
    }
    func testOneMultipleResetRetainsAllNotesAndEditorDraft() async throws {
        let a = try await model.execute("space.create",["name":.string("A")])["id"].text
        let b = try await model.execute("space.create",["name":.string("B")])["id"].text
        let noteA = try await model.execute("note.create",["space_id":.string(a),"title":.string("A"),"body":.string("A original")])
        let noteB = try await model.execute("note.create",["space_id":.string(b),"title":.string("B"),"body":.string("B original")])
        _ = try await model.execute("connection.create",["from_space_id":.string(a),"to_space_id":.string(b),"access":.string("read")])
        await model.refresh(); model.selectSpace(a); model.synchronizeNotesSpaces()
        model.selectNote(noteB.id); await model.loadSelectedNote()
        model.stageDraft(id:noteB.id,title:"B draft",body:"SYNTHETIC_UNSAVED_BODY",revision:noteB["revision_id"].text,status:"hypothesis")
        let detail = model.noteDetail, draft = model.preferences.drafts[noteB.id]?.body
        XCTAssertEqual(model.notesForDisplay.count,2); XCTAssertEqual(model.notesForDisplay.first?.id,noteA.id)
        XCTAssertEqual(model.emphasizedNoteCount,1); XCTAssertEqual(model.notesOpacity(noteB),0.06)
        model.setNotesSpaceSelected(b,selected:true); model.setNotesSpaceSelected(b,selected:true)
        XCTAssertEqual(model.emphasizedNoteCount,2); XCTAssertEqual(model.notesFocusedSpaceIDs,Set([a,b]))
        model.showAllNotesSpaces(); XCTAssertFalse(model.notesFilterActive); XCTAssertEqual(model.notesForDisplay.count,2)
        model.synchronizeNotesSpaces(); XCTAssertFalse(model.notesFilterActive)
        model.focusNotesSpace(a); model.setNotesSpaceSelected(b,selected:true); model.focusNotesSpace(a)
        XCTAssertEqual(model.notesFocusedSpaceIDs,[a]); XCTAssertEqual(model.notesForDisplay.count,2)
        XCTAssertEqual(model.selectedNote,noteB.id); XCTAssertEqual(model.selectedSpace,a)
        XCTAssertEqual(model.noteDetail,detail); XCTAssertEqual(model.preferences.drafts[noteB.id]?.body,draft)
        XCTAssertEqual(model.tab,"notes")
    }
    func testEmptyFocusKeepsOtherRowsAndDeletedNotesStayExcluded() async throws {
        let empty = try await model.execute("space.create",["name":.string("Empty")])["id"].text
        let other = try await model.execute("space.create",["name":.string("Other")])["id"].text
        let note = try await model.execute("note.create",["space_id":.string(other),"title":.string("Retained"),"body":.string("Evidence")])
        await model.refresh(); model.selectSpace(empty); model.synchronizeNotesSpaces()
        XCTAssertEqual(model.emphasizedNoteCount,0); XCTAssertEqual(model.notesForDisplay.map(\.id),[note.id])
        XCTAssertEqual(model.notesOpacity(model.notesForDisplay[0]),0.06)
        model.showAllNotesSpaces(); XCTAssertEqual(model.emphasizedNoteCount,1)
        await model.deleteNote(note.id); XCTAssertTrue(model.notesForDisplay.isEmpty)
        XCTAssertEqual(model.deletedNotes.count,1)
    }
    func testNotesAndGraphSelectionsAreIndependentAcrossReentry() async throws {
        let a = try await model.execute("space.create",["name":.string("A")])["id"].text
        let b = try await model.execute("space.create",["name":.string("B")])["id"].text
        await model.refresh(); model.selectSpace(a); model.synchronizeNotesSpaces()
        model.setNotesSpaceSelected(b,selected:true)
        model.graph.focusSpace(b); model.synchronizeNotesSpaces()
        XCTAssertEqual(model.notesFocusedSpaceIDs,Set([a,b])); XCTAssertEqual(model.graph.focusedSpaceIDs,[b])
        model.showAllNotesSpaces(); XCTAssertEqual(model.graph.focusedSpaceIDs,[b])
        model.selectSpace(b); model.synchronizeNotesSpaces(); XCTAssertEqual(model.notesFocusedSpaceIDs,[b])
    }
    func testDeletedSpaceDoesNotExposeUnopenableRowsOrEraseDrafts() async throws {
        let space = try await model.execute("space.create",["name":.string("Removed space")])["id"].text
        let note = try await model.execute("note.create",["space_id":.string(space),"title":.string("Retained record"),"body":.string("History")])
        await model.refresh()
        model.stageDraft(id:note.id,title:"Draft",body:"SYNTHETIC_SPACE_DRAFT",revision:note["revision_id"].text,status:"hypothesis")
        _ = try await model.execute("space.delete",["space_id":.string(space)])
        await model.refresh()
        XCTAssertEqual(model.allNotes.count,1) // Storage history is retained.
        XCTAssertTrue(model.notesForDisplay.isEmpty)
        XCTAssertEqual(model.emphasizedNoteCount,0)
        XCTAssertEqual(model.preferences.drafts[note.id]?.body,"SYNTHETIC_SPACE_DRAFT")
    }
}
