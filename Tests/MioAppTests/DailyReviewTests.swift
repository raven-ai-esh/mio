import Foundation
import XCTest
@testable import Mio

final class DailyReviewTests: XCTestCase {
    func testDefaultMidnightAndNextConfiguredLocalTime() throws {
        var configuration = DailyReviewConfiguration()
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.hour, 0)
        XCTAssertEqual(configuration.minute, 0)
        let calendar = calendar(in: "Europe/Moscow")
        var schedule = DailyReviewSchedule(configuration, calendar: calendar)
        let now = date("2026-11-11T21:00:09Z")
        let window = try XCTUnwrap(schedule.due(at: now, enabledSince: date("2026-11-10T12:00:00Z")))
        XCTAssertEqual(window.day, "2026-11-12")
        XCTAssertEqual(window.start, date("2026-11-10T21:00:00Z"))
        XCTAssertEqual(window.end, date("2026-11-11T21:00:00Z"))
        XCTAssertNil(schedule.due(at: now, enabledSince: now))
        configuration.hour = 8
        configuration.minute = 35
        schedule = DailyReviewSchedule(configuration, calendar: calendar)
        XCTAssertEqual(schedule.next(after: now, claimed: { _ in false }), date("2026-11-12T05:35:00Z"))
        XCTAssertEqual(schedule.next(after: now, claimed: { $0 == "2026-11-12" }), date("2026-11-13T05:35:00Z"))
    }

    func testSkippedAndRepeatedLocalTimesStillIdentifyOneCalendarDay() throws {
        var configuration = DailyReviewConfiguration(hour: 2, minute: 30)
        let calendar = calendar(in: "America/New_York")
        var schedule = DailyReviewSchedule(configuration, calendar: calendar)
        let spring = try XCTUnwrap(schedule.due(at: date("2026-03-08T07:01:00Z"),
                                                enabledSince: date("2026-03-06T00:00:00Z")))
        XCTAssertEqual(spring.day, "2026-03-08")
        XCTAssertEqual(spring.end, date("2026-03-08T07:00:00Z"))
        configuration.hour = 1
        schedule = DailyReviewSchedule(configuration, calendar: calendar)
        let enabled = date("2026-10-31T00:00:00Z")
        let first = schedule.due(at: date("2026-11-01T05:31:00Z"), enabledSince: enabled)
        let second = schedule.due(at: date("2026-11-01T06:31:00Z"), enabledSince: enabled)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.end, date("2026-11-01T05:30:00Z"))
    }

    func testActivationRequiresConfirmationBeforeRegisteringOrRunning() throws {
        let (root, storage, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = DailyReviewConfiguration(executable: "/bin/cat", workspace: root.path)
        XCTAssertThrowsError(try agent.save(configuration, enable: true, confirmed: false))
        XCTAssertFalse(try storage.loadConfiguration().enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.plistURL.path))
        try DailyReviewRunner(storage: storage, launchAgent: agent).runIfDue()
        XCTAssertNil(storage.lastRun())
    }

    func testActualHarnessProcessesAnalyzeThenWorkOncePerDay() throws {
        let (root, storage, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try script(in: root, body: """
            set -eu
            test "$1" = "$MIO_REVIEW_PROMPT_PATH"
            test "$2" = "argument with spaces"
            test -z "$(printenv MIO_DATA_DIRECTORY || true)"
            if test "$MIO_REVIEW_PHASE" = analysis; then
                grep -q '"calls":0'
                echo 'Analysis for the scheduled fixture'
            else
                grep -q 'Analysis for the scheduled fixture'
                grep -q 'Analysis for the scheduled fixture' "$MIO_REVIEW_ANALYSIS_PATH"
                printf 'worked\\n' >> proof.txt
                echo 'Fixture work verified'
            fi
            """)
        let config = DailyReviewConfiguration(executable: harness.path, arguments: "{prompt_file}\nargument with spaces",
                                             workspace: root.path, enabledSince: date("2026-11-10T00:00:00Z"), authorizationID: UUID())
        try storage.saveConfiguration(config)
        let runner = DailyReviewRunner(storage: storage, launchAgent: agent)
        let calendar = calendar(in: "UTC")
        let now = date("2026-11-11T00:00:15Z")
        try runner.runIfDue(now: now, calendar: calendar)
        let first = try XCTUnwrap(storage.lastRun())
        XCTAssertEqual(first.state, .succeeded)
        XCTAssertEqual(first.scheduledAt, date("2026-11-11T00:00:00Z"))
        try runner.runIfDue(now: now.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(storage.lastRun(), first)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("proof.txt"), encoding: .utf8), "worked\n")
        XCTAssertEqual(try String(contentsOf: storage.directory(for: first.day).appendingPathComponent("work.txt"), encoding: .utf8),
                       "Fixture work verified\n")
    }

    func testFailedAnalysisDoesNotStartWork() throws {
        let (root, storage, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try script(in: root, body: """
            if test "$MIO_REVIEW_PHASE" = analysis; then
                exit 7
            fi
            touch unexpected-work
            """)
        let config = DailyReviewConfiguration(executable: harness.path, workspace: root.path,
                                              enabledSince: date("2026-11-10T00:00:00Z"), authorizationID: UUID())
        try storage.saveConfiguration(config)
        let runner = DailyReviewRunner(storage: storage, launchAgent: agent)
        XCTAssertThrowsError(try runner.runIfDue(now: date("2026-11-11T00:00:15Z"), calendar: calendar(in: "UTC")))
        XCTAssertEqual(storage.lastRun()?.state, .failed)
        XCTAssertTrue(storage.lastRun()?.error?.contains("status 7") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-work").path))
    }

    func testDisablingDuringAnalysisPreventsWork() throws {
        let (root, storage, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let disabledFile = root.appendingPathComponent("disabled.json")
        try JSONEncoder().encode(DailyReviewConfiguration()).write(to: disabledFile)
        let harness = try script(in: root, body: """
            set -eu
            if test "$MIO_REVIEW_PHASE" = analysis; then
                cp "$1" "$2"
                echo 'Analysis finished after review was disabled'
            else
                touch unexpected-work
            fi
            """)
        let destination = storage.directory.appendingPathComponent("DailyReview/configuration.json")
        try storage.saveConfiguration(DailyReviewConfiguration(
            executable: harness.path, arguments: disabledFile.path + "\n" + destination.path,
            workspace: root.path, enabledSince: date("2026-11-10T00:00:00Z"), authorizationID: UUID()))
        try DailyReviewRunner(storage: storage, launchAgent: agent).runIfDue(
            now: date("2026-11-11T00:00:15Z"), calendar: calendar(in: "UTC"))
        XCTAssertEqual(storage.lastRun()?.state, .interrupted)
        XCTAssertFalse(try storage.loadConfiguration().enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-work").path))
    }

    func testNewConsentDoesNotResumeAnOldRunWithTheSameHarness() throws {
        let (root, storage, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let replacement = root.appendingPathComponent("replacement.json")
        let destination = storage.directory.appendingPathComponent("DailyReview/configuration.json")
        let harness = try script(in: root, body: """
            set -eu
            if test "$MIO_REVIEW_PHASE" = analysis; then
                cp "$1" "$2"
                echo 'Analysis from an earlier activation'
            else
                touch unexpected-work
            fi
            """)
        let config = DailyReviewConfiguration(executable: harness.path, arguments: [replacement.path, destination.path].joined(separator: "\n"),
                                             workspace: root.path, enabledSince: date("2026-11-10T00:00:00Z"), authorizationID: UUID())
        var reenabled = config
        reenabled.enabledSince = date("2026-11-11T00:00:10Z")
        reenabled.authorizationID = UUID()
        try JSONEncoder().encode(reenabled).write(to: replacement)
        try storage.saveConfiguration(config)
        try DailyReviewRunner(storage: storage, launchAgent: agent).runIfDue(
            now: date("2026-11-11T00:00:05Z"), calendar: calendar(in: "UTC"))
        XCTAssertEqual(storage.lastRun()?.state, .interrupted)
        XCTAssertTrue(try storage.loadConfiguration().enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-work").path))
    }

    private func fixture() throws -> (URL, DailyReviewStorage, DailyReviewLaunchAgent) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mio daily fixture " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DailyReviewStorage(directory: root.appendingPathComponent("memory", isDirectory: true))
        let agent = DailyReviewLaunchAgent(storage: storage, appExecutable: URL(fileURLWithPath: "/bin/false"), home: root)
        return (root, storage, agent)
    }

    private func script(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("test harness.sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func calendar(in identifier: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: identifier)!
        return result
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
