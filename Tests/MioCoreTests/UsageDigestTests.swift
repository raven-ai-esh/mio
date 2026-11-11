import Foundation
import XCTest
@testable import MioCore

final class UsageDigestTests: XCTestCase {
    func testReadsRealInteractionsInsideTheWindowWithoutExposingPayloads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mio-review-digest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MioStore(directory: folder)
        let space = try store.execute("space.create", params: ["name": .string("Private fixture")])["id"]
        let profile = try store.execute("profile.create", params: ["space_id": space, "name": .string("Fixture")])
        let context = AccessContext.agent(token: try XCTUnwrap(profile["token"].stringValue))
        let before = Date().addingTimeInterval(-1)
        let captured = try store.execute("note.create", params: [
            "space_id": space, "title": .string("SENSITIVEQUERY"), "body": .string("DO_NOT_EXPORT_NOTE_BODY"),
            "source_ids": .array([.string("https://example.invalid/private-reference")]), "idempotency_key": .string("fixture")
        ], context: context)
        for _ in 0..<2 {
            let search = try store.execute("search", params: ["query": .string("SENSITIVEQUERY"), "scope": .string("notes")], context: context)
            XCTAssertEqual(search["results"].arrayValue.count, 1)
        }
        _ = try store.execute("read", params: ["kind": .string("note"), "id": captured["id"]], context: context)
        XCTAssertThrowsError(try store.execute("note.update", params: ["note_id": captured["id"]], context: context))
        let after = Date().addingTimeInterval(1)
        let digest = try MioUsageDigest.read(directory: folder, from: before, until: after)
        XCTAssertEqual(digest["calls"].intValue, 5)
        XCTAssertEqual(digest["outcomes"]["success"].intValue, 4)
        XCTAssertEqual(digest["error_codes"]["invalid_params"].intValue, 1)
        XCTAssertEqual(digest["committed_note_versions"].intValue, 1)
        XCTAssertEqual(digest["committed_note_versions_with_source_refs"].intValue, 1)
        XCTAssertEqual(digest["searches_followed_by_read"].intValue, 1)
        XCTAssertEqual(digest["repeated_search_terms_within_ten_minutes"].intValue, 1)
        let encoded = String(decoding: try digest.encoded(), as: UTF8.self)
        for secret in ["SENSITIVEQUERY", "DO_NOT_EXPORT_NOTE_BODY", "private-reference", captured["id"].stringValue!] {
            XCTAssertFalse(encoded.contains(secret))
        }
        XCTAssertEqual(try MioUsageDigest.read(directory: folder, from: after, until: after.addingTimeInterval(60))["calls"].intValue, 0)
    }

    func testEmptyReviewDoesNotCreateAMemoryDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let now = Date()
        let digest = try MioUsageDigest.read(directory: folder, from: now.addingTimeInterval(-86400), until: now)
        XCTAssertEqual(digest["calls"].intValue, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
