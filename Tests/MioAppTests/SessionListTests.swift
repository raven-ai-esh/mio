import XCTest
import Foundation
import MioCore
import MioBridge
@testable import Mio

@MainActor final class SessionListTests: XCTestCase {
    var directory: URL!
    var model: AppModel!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mio-session-list-" + UUID().uuidString)
        setenv("MIO_DATA_DIRECTORY", directory.path, 1)
        model = AppModel(startIndexing: false)
        await model.refresh()
    }
    override func tearDown() async throws {
        model.shutdown(); model = nil
        unsetenv("MIO_DATA_DIRECTORY")
        try? FileManager.default.removeItem(at: directory)
    }
    private func session(_ id: String, _ opened: String, _ updated: String, deleted: Bool = false, purged: Bool = false, source: String = "memory_operations_v1") -> JSONValue {
        .object(["id": .string(id), "space_id": .string("home"), "source": .string(source), "opened_at": .string(opened), "updated_at": .string(updated), "deleted": .bool(deleted), "purged": .bool(purged)])
    }
    func testRecordedConnectionOrderMatchesDisplayedStartTimeNotRecentActivity() {
        let oldActive = session("old-active", "2026-10-13T13:56:14.996Z", "2026-10-14T14:12:30.915Z")
        let middle = session("middle", "2026-10-14T11:36:23.296Z", "2026-10-14T13:24:55.999Z")
        let newest = session("newest", "2026-10-14T13:17:32.801Z", "2026-10-14T13:18:01.465Z")
        model.snapshot = .object(["spaces": .array([.object(["id": .string("home")])]), "sessions": .array([oldActive, middle, newest])])
        XCTAssertEqual(model.sessions.map(\.id), ["newest", "middle", "old-active"])
        // The history sidebar still sorts by the last-activity time it displays.
        XCTAssertEqual(model.visibleSessions.map(\.id), ["old-active", "middle", "newest"])
    }
    func testSessionOrderComparesInstantsAndHasStableTiesAndExcludesClearedRows() {
        let rows = [
            session("late-offset", "2026-10-14T15:00:00+03:00", "2026-10-14T20:00:00Z"),
            session("z-tie", "2026-10-14T12:30:00Z", "2026-10-14T12:30:00Z"),
            session("a-tie", "2026-10-14T12:30:00.000Z", "2026-10-14T12:31:00Z"),
            session("deleted", "2026-10-15T12:30:00Z", "", deleted: true),
            session("purged", "2026-10-15T12:30:00Z", "", purged: true),
            session("foreign", "2026-10-15T12:30:00Z", "", source: "legacy")
        ]
        model.snapshot = .object(["sessions": .array(rows)])
        XCTAssertEqual(model.sessions.map(\.id), ["a-tie", "z-tie", "late-offset"])
        model.snapshot = .object(["sessions": .array(rows.reversed())])
        XCTAssertEqual(model.sessions.map(\.id), ["a-tie", "z-tie", "late-offset"])
    }
    func testReadingSessionCountDoesNotRepeatDateParsingAndSorting() {
        let rows=(0..<141).map { session("row-\($0)",String(format:"2026-10-%02dT12:%02d:00.000Z",1+$0%18,$0%60),"") }
        model.snapshot = .object(["sessions":.array(rows)])
        XCTAssertEqual(model.sessions.count,141)
        let start=ContinuousClock.now
        for _ in 0..<3 { XCTAssertEqual(model.sessions.count,141) }
        XCTAssertLessThan(start.duration(to:.now),.milliseconds(500),"Rendering the sidebar count must not sort all session dates again")
    }
    func testPickerLabelsFollowProfileLanguageCalendarAndTimeZone() async {
        model.setInterfaceLanguage(.english)
        let row:JSONValue = .object(["id":.string("picker"),"source":.string("memory_operations_v1"),"actor":.string("profile"),"opened_at":.string("2026-10-18T01:30:00.000Z")])
        model.snapshot = .object(["sessions":.array([row]),"profiles":.array([.object(["id":.string("profile"),"name":.string("Original")])])])
        XCTAssertEqual(model.sessionPickerLabel(row),"Original · "+model.date(row["opened_at"]))
        var fields=model.snapshot.fields;fields["profiles"] = .array([.object(["id":.string("profile"),"name":.string("Renamed")])]);model.snapshot = .object(fields)
        XCTAssertEqual(model.sessionPickerLabel(row),"Renamed · "+model.date(row["opened_at"]))
        model.setInterfaceLanguage(.russian);await model.refreshSessionPresentation()
        XCTAssertEqual(model.sessionPickerLabel(row),"Renamed · "+model.date(row["opened_at"]))
        var projection=SessionListProjection();projection.update([row])
        var context=SessionPickerContext(locale:Locale(identifier:"en_US"),timeZone:TimeZone(secondsFromGMT:0)!,calendar:Calendar(identifier:.gregorian),fallbackName:"Agent")
        projection.preparePickerLabels(profiles:[],context:context)
        let utc=projection.pickerLabels["picker"]
        context.timeZone=TimeZone(secondsFromGMT:-8*3600)!
        projection.preparePickerLabels(profiles:[],context:context)
        XCTAssertNotEqual(utc,projection.pickerLabels["picker"])
        let western=projection.pickerLabels["picker"]
        context.calendar=Calendar(identifier:.buddhist)
        projection.preparePickerLabels(profiles:[],context:context)
        XCTAssertNotEqual(western,projection.pickerLabels["picker"])
    }
    func testCancelledViewReadKeepsItsExistingBoundedReadSemantics() async throws {
        let home=try await model.execute("space.create",["name":.string("View lifecycle")])["id"]
        let task=Task { @MainActor in try await model.execute("read",["kind":.string("spaces")]) }
        task.cancel()
        let value=try await task.value
        XCTAssertTrue(value["spaces"].items.contains{$0.id == home.text})
        XCTAssertTrue(model.failure.isEmpty)
    }
    func testNewIPCSessionAppearsAutomaticallyAndKeepsSelectedReplay() async throws {
        let home = try await model.execute("space.create", ["name": .string("Session list QA")])["id"]
        let profile = try await model.execute("profile.create", ["name": .string("List QA"), "space_id": home])
        await model.refresh()
        XCTAssertTrue(model.sessions.isEmpty)
        let client = LocalBridgeClient(socketURL: MioPaths.runtime.socketURL, credential: .agent(profile["token"].text))
        func read(_ transport: String, _ request: String) async throws -> JSONValue {
            try await Task.detached {
                try client.call("read", params: ["kind": .string("spaces"), "_mio_interaction": .object(["transport_session_id": .string(transport), "request_id": .string(request)])])
            }.value
        }
        let first = try await read("list-first", "r1")["interaction_session_id"].text
        let firstDeadline = Date().addingTimeInterval(8)
        while !model.sessions.contains(where: { $0.id == first }) && Date() < firstDeadline { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertEqual(model.sessions.map(\.id), [first], "Periodic refresh must publish IPC sessions without a manual refresh")
        await model.graph.openSession(first, using: model); model.graph.setStep(1)
        let savedSteps = model.graph.steps.map(\.id), savedIndex = model.graph.stepIndex
        let second = try await read("list-second", "r1")["interaction_session_id"].text
        let deadline = Date().addingTimeInterval(8)
        while !model.sessions.contains(where: { $0.id == second }) && Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertEqual(model.sessions.map(\.id), [second, first])
        XCTAssertEqual(model.graph.sessionID, first); XCTAssertEqual(model.graph.steps.map(\.id), savedSteps); XCTAssertEqual(model.graph.stepIndex, savedIndex)
        _ = try await read("list-first", "r2")
        let eventDeadline = Date().addingTimeInterval(8)
        while (model.sessions.first { $0.id == first }?["event_count"].integer ?? 0) < 4 && Date() < eventDeadline { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertGreaterThanOrEqual(model.sessions.first { $0.id == first }?["event_count"].integer ?? 0, 4)
        XCTAssertEqual(model.sessions.map(\.id), [second, first], "Activity on an older connection must not move its start-time row")
        XCTAssertEqual(model.graph.steps.map(\.id), savedSteps)
    }
}
