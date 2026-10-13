import XCTest
import Foundation
import MioCore
@testable import Mio

@MainActor final class AppModelTests: XCTestCase {
    private var folder: URL!
    private var model: AppModel!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mio-model-\(UUID().uuidString)", isDirectory: true)
        setenv("MIO_DATA_DIRECTORY", folder.path, 1)
        model = AppModel()
        await model.refresh()
        XCTAssertNotNil(model.store, model.failure)
    }
    override func tearDown() async throws {
        model.shutdown(); model = nil
        try? FileManager.default.removeItem(at: folder)
        unsetenv("MIO_DATA_DIRECTORY")
    }
    func testExternalPurgeClearsPersistedDraftAndSelection() async throws {
        let space = try await model.execute("space.create", ["name": .string("Private test")])["id"].text
        _ = try await model.execute("history.import", ["space_id": .string(space), "source": .string("codex"), "external_id": .string("model-source"), "title": .string("Source"), "events": .array([.object(["source_id": .string("source-1"), "kind": .string("message"), "role": .string("user"), "text": .string("PRIVATE_DRAFT_MARKER"), "timestamp": .string("2026-10-11T00:00:00Z")])])])
        await model.refresh()
        let event = model.snapshot["events"].items.first!
        let note = try await model.execute("note.create", ["space_id": .string(space), "title": .string("Derived"), "body": .string("PRIVATE_DRAFT_MARKER"), "source_ids": .array([.string(event.id)])])
        await model.refresh(); model.selectNote(note["id"].text)
        model.stageDraft(id: note["id"].text, title: "Derived", body: "PRIVATE_DRAFT_MARKER unsaved", revision: note["revision_id"].text, status: "confirmed")
        XCTAssertTrue(String(data: try Data(contentsOf: folder.appendingPathComponent("preferences.json")), encoding: .utf8)!.contains("PRIVATE_DRAFT_MARKER"))
        // Simulate another owner/client/cloud path; do not invoke GUI cleanup.
        _ = try model.store!.execute("history.purge", params: ["session_id": .string(event["session_id"].text)])
        await model.refresh()
        XCTAssertNil(model.preferences.drafts[note["id"].text])
        XCTAssertEqual(model.selectedNote, "")
        XCTAssertFalse(String(data: try Data(contentsOf: folder.appendingPathComponent("preferences.json")), encoding: .utf8)!.contains("PRIVATE_DRAFT_MARKER"))
    }
    func testFinishedFileIndexRefreshesAlreadyTypedQueryWithoutAnotherEdit() async throws {
        model.shutdown();model=AppModel(startIndexing:false)
        let s=try await model.execute("space.create",["name":.string("Pending file")])["id"]
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MioCoreTests/Fixtures/Hybrid/record-01.pdf")
        let bytes=try Data(contentsOf:source)
        let n=try await model.execute("note.create",["space_id":s,"title":.string("Original PDF"),"file_name":.string("policy.pdf"),"mime_type":.string("application/pdf"),"file_base64":.string(bytes.base64EncodedString())])
        await model.refresh();await model.refreshIndexing()
        model.query="cancellation costs";model.searchScope="files";model.search()
        for _ in 0..<30 { if !model.searchWorking { break };try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertEqual(model.searchResults.count,0);XCTAssertEqual(model.searchStatus["lexical_pending_sources"],.number(1))
        let store=try XCTUnwrap(model.store),job=try XCTUnwrap(try store.nextSourceIndexJob(modelID:"lexical-native-v1"))
        let fragments=try MioDocumentExtraction.fragments(file:job["file"],bytes:bytes),docs=try store.sourceDocuments(job:job,fileFragments:fragments)
        XCTAssertTrue(try store.publishSourceIndex(job:job,documents:docs))
        await model.refreshIndexing()
        for _ in 0..<30 { if !model.searchWorking { break };try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertEqual(model.query,"cancellation costs");XCTAssertEqual(model.searchResults.first?["id"],n["id"])
    }
    func testPurgeClearsRetiredSubscriptionPreferenceAndDoesNotResurrect() async throws {
        let space = try await model.execute("space.create", ["name": .string("Source test")])["id"].text
        _ = try await model.execute("history.import", ["space_id": .string(space), "source": .string("codex"), "external_id": .string("selected-source"), "title": .string("Source"), "events": .array([.object(["source_id": .string("evt"), "kind": .string("message"), "role": .string("user"), "text": .string("temporary evidence"), "timestamp": .string("2026-10-11T00:00:00Z")])])])
        model.preferences.historySources = [.init(id: "selected-source", title: "Source", spaceID: space)]
        model.preferences.save(); await model.refresh()
        let session = model.snapshot["sessions"].items.first { $0["external_id"].text == "selected-source" }!
        model.selectedSession = session.id
        await model.purgeSession(session.id)
        XCTAssertTrue(model.preferences.historySources.isEmpty)
        XCTAssertTrue(model.preferences.ignoredHistorySources.contains(space + "|selected-source"))
        XCTAssertEqual(model.selectedSession, "")
        XCTAssertTrue(model.sessions.isEmpty)
    }
    func testDisconnectedMountNoLongerShowsMountedNotes() async throws {
        let a = try await model.execute("space.create", ["name": .string("A")])["id"].text
        let b = try await model.execute("space.create", ["name": .string("B")])["id"].text
        _ = try await model.execute("note.create", ["space_id": .string(b), "title": .string("mounted"), "body": .string("evidence")])
        let connection = try await model.execute("connection.create", ["from_space_id": .string(a), "to_space_id": .string(b), "access": .string("read")])
        await model.refresh(); model.selectSpace(a)
        XCTAssertEqual(model.visibleNotes.count, 1)
        _ = try await model.execute("connection.delete", ["connection_id": connection["id"]])
        await model.refresh()
        XCTAssertTrue(model.visibleNotes.isEmpty)
        XCTAssertTrue(model.connections.isEmpty)
    }
    func testOldPreferencesUpgradePreservesDraftAndSources() throws {
        let old = Data(#"{"selectedSpace":"a","selectedNote":"n","cloudFolder":"folder","historySources":[{"id":"s","title":"session","spaceID":"a"}],"drafts":{"n":{"title":"draft","body":"unsaved","revision":"r","status":"hypothesis"}}}"#.utf8)
        let upgraded = try JSONDecoder().decode(MioPreferences.self, from: old)
        XCTAssertEqual(upgraded.drafts["n"]?.body, "unsaved")
        XCTAssertEqual(upgraded.historySources.first?.id, "s")
        XCTAssertEqual(upgraded.cloudFolder, "folder")
        XCTAssertTrue(upgraded.historyWorkspaces.isEmpty)
    }
    func testSoftDeletedNoteRemainsRecoverableInModel() async throws {
        let space = try await model.execute("space.create", ["name": .string("Recovery")])["id"].text
        let note = try await model.execute("note.create", ["space_id": .string(space), "title": .string("remember"), "body": .string("kept bytes")])
        await model.refresh(); await model.deleteNote(note["id"].text)
        XCTAssertEqual(model.deletedNotes.count, 1)
        XCTAssertTrue(model.allNotes.isEmpty)
        _ = try await model.execute("note.restore", ["note_id": note["id"], "revision_id": note["revision_id"]])
        await model.refresh()
        model.selectNote(note["id"].text); await model.loadSelectedNote()
        XCTAssertEqual(model.selectedNoteValue["body"].text, "kept bytes")
        XCTAssertTrue(model.deletedNotes.isEmpty)
    }
    func testCompactListLoadsAndSavesFullNoteWithoutLosingTail() async throws {
        let space = try await model.execute("space.create", ["name": .string("Complete text")])["id"].text
        let body = String(repeating: "Long document line.\n", count: 500) + "UNIQUE_END_OF_DOCUMENT"
        let note = try await model.execute("note.create", ["space_id": .string(space), "title": .string("Full document"), "body": .string(body)])
        await model.refresh()
        XCTAssertEqual(model.snapshot["projection"].text, "compact")
        XCTAssertEqual(model.allNotes.first?["body"], .null)
        XCTAssertTrue(model.allNotes.first?["body_omitted"].flag ?? false)
        model.selectNote(note["id"].text); await model.loadSelectedNote()
        XCTAssertEqual(model.selectedNoteValue["body"].text, body)
        let saved = await model.saveNote(id: note["id"].text, title: "Retitled", body: model.selectedNoteValue["body"].text, revision: model.selectedNoteValue["revision_id"].text, status: "confirmed")
        XCTAssertTrue(saved, model.failure)
        let reopened = try await model.execute("read", ["kind": .string("note"), "id": note["id"]])
        XCTAssertEqual(reopened["body"].text, body)
        XCTAssertEqual(reopened["title"].text, "Retitled")
        XCTAssertFalse(model.noteLoading)
    }
    func testRapidSelectionAndExternalDeleteNeverExposePreviousBody() async throws {
        let space = try await model.execute("space.create", ["name": .string("Selection")])["id"].text
        let a = try await model.execute("note.create", ["space_id": .string(space), "title": .string("A"), "body": .string("A private body")])
        let b = try await model.execute("note.create", ["space_id": .string(space), "title": .string("B"), "body": .string("B private body")])
        await model.refresh(); model.selectNote(a["id"].text); model.selectNote(b["id"].text)
        await model.loadSelectedNote()
        XCTAssertEqual(model.selectedNoteValue.id, b["id"].text)
        XCTAssertEqual(model.selectedNoteValue["body"].text, "B private body")
        _ = try await model.execute("note.delete", ["note_id": b["id"]]); await model.refresh()
        XCTAssertEqual(model.selectedNote, "")
        XCTAssertEqual(model.selectedNoteValue, .null)
        XCTAssertFalse(model.noteLoading)
    }
    func testEarlierOfflineBranchRefreshesConflictWithoutChangingSelectedRevision() async throws {
        let space = try await model.execute("space.create", ["name": .string("Offline conflict")])["id"]
        let base = try await model.execute("note.create", ["space_id": space, "title": .string("Decision"), "body": .string("base")])
        let peer = try MioStore(directory: folder.appendingPathComponent("offline-peer"))
        _ = try peer.execute("replica.merge", params: ["document": try await model.execute("replica.export")])
        _ = try peer.execute("note.update", params: ["note_id": base["id"], "expected_revision": base["revision_id"], "body": .string("offline branch")])
        try await Task.sleep(for: .milliseconds(20))
        let local = try await model.execute("note.update", ["note_id": base["id"], "expected_revision": base["revision_id"], "body": .string("newer local branch")])
        await model.refresh(); model.selectNote(base["id"].text); await model.loadSelectedNote()
        XCTAssertEqual(model.selectedNoteValue["revision_id"], local["revision_id"])
        XCTAssertFalse(model.selectedNoteValue["has_conflict"].flag)
        _ = try await model.execute("replica.merge", ["document": try peer.execute("replica.export")])
        await model.refresh()
        XCTAssertEqual(model.selectedNoteValue["revision_id"], local["revision_id"])
        XCTAssertTrue(model.selectedNoteValue["has_conflict"].flag)
        XCTAssertEqual(model.selectedNoteValue["head_revision_ids"].items.count, 2)
        XCTAssertEqual(model.selectedNoteValue["body"].text, "newer local branch")
    }
}
