import XCTest
import Foundation
import MioCore
@testable import MioCloud

final class FixtureCloudEnvironment: CloudEnvironment {
    var account: Data? = Data("test-account-a".utf8)
    var uploaded = true
    var uploadFailure: String?
    var uploadFailureCode: Int?
    var uploadedByFilename: [String: Bool] = [:]
    var unavailableFolders = Set<String>()
    var uploadHook: ((URL) throws -> Void)?
    func identity() throws -> Data? { account }
    func identitiesEqual(_ lhs: Data, _ rhs: Data) throws -> Bool { lhs == rhs }
    func folderIdentity(_ directory: URL) throws -> String { directory.standardizedFileURL.path }
    func metadata(_ url: URL) throws -> CloudMetadata {
        if url.lastPathComponent.hasSuffix(".mio-record.json") { try uploadHook?(url) }
        return CloudMetadata(ubiquitous: !unavailableFolders.contains(url.standardizedFileURL.path), uploaded: uploadedByFilename[url.lastPathComponent] ?? uploaded, uploadError: url.lastPathComponent.hasSuffix(".mio-record.json") ? uploadFailure : nil, uploadErrorCode: uploadFailureCode, uploadErrorDomain: uploadFailureCode == nil ? nil : NSCocoaErrorDomain)
    }
    func requestDownload(_ url: URL) throws {}
}

final class CloudSyncTests: XCTestCase {
    func setupStores() throws -> (URL, MioStore, MioStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mio-cloud-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let a = try MioStore(directory: root.appendingPathComponent("a")), b = try MioStore(directory: root.appendingPathComponent("b"))
        let folder = root.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, a, b, folder)
    }
    func createNote(_ store: MioStore, space: String? = nil, body: String = "Mio remembers decisions") throws -> (String, String, String) {
        let sid = try space ?? store.execute("space.create", params: ["name": .string("Mio cloud validation")])["id"].stringValue!
        let note = try store.execute("note.create", params: ["space_id": .string(sid), "title": .string("Decision"), "body": .string(body)])
        return (sid, note["note_id"].stringValue!, note["revision_id"].stringValue!)
    }
    func recordFiles(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Mio-records-v1"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
    func testEmptyConnectedFolderDoesNotClaimUploadedDelivery() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        let initial = coordinator.status()
        XCTAssertEqual(initial["state"].stringValue, "connected")
        XCTAssertFalse(initial["delivery_verified"].boolValue)
        let receipt = try coordinator.sync()
        XCTAssertEqual(receipt["state"].stringValue, "connected")
        XCTAssertEqual(receipt["total_records"].intValue, 0)
        XCTAssertEqual(receipt["confirmed_uploaded_records"].intValue, 0)
        XCTAssertFalse(receipt["delivery_verified"].boolValue)
        XCTAssertEqual(try recordFiles(folder).count, 0)
    }
    func testAlreadyAcknowledgedLocalCopiesRequireActualProviderUploadReceipt() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        _ = try createNote(a)
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        _ = try coordinator.sync()
        XCTAssertEqual(try a.execute("sync.pending")["count"].intValue, 0)
        // Local bytes and previous acknowledgements alone cannot establish a
        // current uploaded receipt, including an identical inbound merge.
        env.uploaded = false
        let receipt = try coordinator.sync()
        XCTAssertEqual(receipt["state"].stringValue, "pending")
        XCTAssertFalse(receipt["delivery_verified"].boolValue)
        XCTAssertEqual(receipt["confirmed_uploaded_records"].intValue, 0)
        XCTAssertEqual(try a.execute("sync.pending")["count"].intValue, 2)
        let restarted = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        let inbound = try restarted.sync()
        XCTAssertEqual(inbound["state"].stringValue, "pending")
        XCTAssertFalse(inbound["delivery_verified"].boolValue)
        env.uploaded = true
        let delivered = try restarted.sync()
        XCTAssertEqual(delivered["state"].stringValue, "uploaded")
        XCTAssertEqual(delivered["confirmed_uploaded_records"].intValue, 2)
        XCTAssertTrue(delivered["delivery_verified"].boolValue)
        XCTAssertFalse(delivered["cross_device_verified"].boolValue)
    }
    func testPendingIsSeparateFromUploadedAndCredentialsStayLocal() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        env.uploaded = false
        let (space, _, _) = try createNote(a)
        let profile = try a.execute("profile.create", params: ["space_id": .string(space), "name": .string("Codex")])
        let transport = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        let first = try transport.sync()
        XCTAssertEqual(first["state"].stringValue, "pending")
        XCTAssertEqual(first["pending_records"].intValue, 2)
        XCTAssertEqual(first["uploaded_records"].intValue, 0)
        for file in try recordFiles(folder) {
            let bytes = try Data(contentsOf: file)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(profile["token"].stringValue!))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("token_hash"))
        }
        env.uploaded = true
        let second = try transport.sync()
        XCTAssertEqual(second["state"].stringValue, "uploaded")
        XCTAssertEqual(second["pending_records"].intValue, 0)
        XCTAssertEqual(second["uploaded_records"].intValue, 2)
        XCTAssertFalse(second["cross_device_verified"].boolValue)
    }
    func testUnchangedFilesSkipContentReadsAndMissingCloudFilesRequeueExactRecords() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        _ = try createNote(a)
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        _ = try coordinator.sync()
        let unchanged = try coordinator.sync()
        XCTAssertEqual(unchanged["downloaded_records"].intValue, 0)
        XCTAssertEqual(unchanged["written_records"].intValue, 0)
        let missing = try recordFiles(folder).first!
        let original = try Data(contentsOf: missing)
        try FileManager.default.removeItem(at: missing)
        env.uploadedByFilename[missing.lastPathComponent] = false
        let restored = try coordinator.sync()
        XCTAssertEqual(try Data(contentsOf: missing), original)
        XCTAssertEqual(restored["state"].stringValue, "pending")
        XCTAssertEqual(try a.execute("sync.pending")["count"].intValue, 1)
        // A restart must retain the new delivery requirement, even though an
        // earlier generation of this exact record had been uploaded before.
        let restarted = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        XCTAssertEqual(try restarted.sync()["state"].stringValue, "pending")
        env.uploadedByFilename.removeValue(forKey: missing.lastPathComponent)
        XCTAssertEqual(try restarted.sync()["pending_records"].intValue, 0)
    }

    func testProviderErrorStagesAllRecordsAndRetainsPendingThenRetryRecovers() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        _ = try createNote(a)
        env.uploaded = false
        env.uploadFailure = "Fixture provider authentication unavailable"
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        XCTAssertThrowsError(try coordinator.sync()) { XCTAssertEqual(($0 as? MioError)?.code, "icloud_upload_failed") }
        XCTAssertEqual(try recordFiles(folder).count, 2, "A failed receipt must not prevent staging dependencies")
        XCTAssertEqual(coordinator.status()["pending_records"].intValue, 2)
        XCTAssertEqual(coordinator.status()["state"].stringValue, "error")
        env.uploaded = true; env.uploadFailure = nil
        XCTAssertEqual(try coordinator.sync()["pending_records"].intValue, 0)
    }

    func testServerUnavailable4355IsNotDiagnosedAsWrongAccount() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        _ = try createNote(a)
        env.uploaded = false; env.uploadFailure = "Ambiguous localized provider text"; env.uploadFailureCode = 4355
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        XCTAssertThrowsError(try coordinator.sync()) { error in
            let e = error as? MioError
            XCTAssertEqual(e?.code, "icloud_server_unavailable")
            XCTAssertEqual(e?.details["kind"].stringValue, "NSUbiquitousFileUbiquityServerNotAvailable")
        }
        XCTAssertEqual(coordinator.status()["provider"]["code"].intValue, 4355)
        XCTAssertFalse(coordinator.status()["delivery_verified"].boolValue)
    }
    func testExplicitOwnerReconnectValidatesDestinationAndInvalidatesOldCoordinator() throws {
        let (root, a, _, firstFolder) = try setupStores(), env = FixtureCloudEnvironment()
        _ = try createNote(a)
        let first = try CloudSyncCoordinator(store: a, directory: firstFolder, environment: env)
        _ = try first.sync()
        let binding = a.directory.appendingPathComponent("icloud-drive-binding.json")
        let initial = try Data(contentsOf: binding)
        let secondFolder = root.appendingPathComponent("second-drive")
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        env.unavailableFolders.insert(secondFolder.standardizedFileURL.path)
        XCTAssertThrowsError(try CloudSyncCoordinator.reconnect(store: a, directory: secondFolder, environment: env))
        XCTAssertEqual(try Data(contentsOf: binding), initial)
        XCTAssertEqual(try first.sync()["state"].stringValue, "uploaded")
        env.unavailableFolders.removeAll()
        XCTAssertThrowsError(try CloudSyncCoordinator(store: a, directory: secondFolder, environment: env)) { XCTAssertEqual(($0 as? MioError)?.code, "icloud_folder_changed") }
        let rebound = try CloudSyncCoordinator.reconnect(store: a, directory: secondFolder, environment: env)
        XCTAssertEqual(try rebound.sync()["state"].stringValue, "uploaded")
        let priorBytes = try recordFiles(firstFolder).map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try first.sync()) { XCTAssertEqual(($0 as? MioError)?.code, "icloud_binding_replaced") }
        XCTAssertEqual(try recordFiles(firstFolder).map { try Data(contentsOf: $0) }, priorBytes)
        env.account = Data("test-owner-new-account".utf8)
        XCTAssertThrowsError(try CloudSyncCoordinator(store: a, directory: secondFolder, environment: env)) { XCTAssertEqual(($0 as? MioError)?.code, "icloud_account_changed") }
        let explicit = try CloudSyncCoordinator.reconnect(store: a, directory: secondFolder, environment: env)
        XCTAssertEqual(try explicit.sync()["state"].stringValue, "uploaded")
    }

    func testTwoLocalReplicasPreserveConflictsAndDeletion() throws {
        let (_, a, b, folder) = try setupStores(), env = FixtureCloudEnvironment()
        let (_, noteID, originalRevision) = try createNote(a)
        let ca = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        let cb = try CloudSyncCoordinator(store: b, directory: folder, environment: env)
        _ = try ca.sync(); _ = try cb.sync()
        let va = try a.execute("note.update", params: ["note_id": .string(noteID), "expected_revision": .string(originalRevision), "body": .string("Branch A")])
        let vb = try b.execute("note.update", params: ["note_id": .string(noteID), "expected_revision": .string(originalRevision), "body": .string("Branch B")])
        _ = try ca.sync(); _ = try cb.sync(); _ = try ca.sync()
        for store in [a, b] {
            let n = try store.execute("snapshot")["notes"].arrayValue.first { $0["id"].stringValue == noteID }!
            XCTAssertTrue(n["has_conflict"].boolValue)
            XCTAssertEqual(Set(n["head_revision_ids"].arrayValue.compactMap(\.stringValue)), Set([va["revision_id"].stringValue!, vb["revision_id"].stringValue!]))
        }
        _ = try a.execute("note.delete", params: ["note_id": .string(noteID)])
        _ = try ca.sync(); _ = try cb.sync()
        XCTAssertTrue(try b.execute("snapshot")["notes"].arrayValue.first { $0["id"].stringValue == noteID }!["deleted"].boolValue)
        XCTAssertEqual(try b.execute("search", params: ["query": .string("Branch")])["results"].arrayValue.count, 0)
    }
    func testPurgeReplacesPlaintextAndOldDeliveryCannotResurrectSource() throws {
        let (_, a, b, folder) = try setupStores(), env = FixtureCloudEnvironment()
        let (space, _, _) = try createNote(a)
        let secret = "isolated-secret-" + UUID().uuidString
        let history = try a.execute("history.import", params: ["space_id": .string(space), "external_id": .string("isolated-source"), "title": .string(secret), "events": .array([.object(["source_id": .string("source-item"), "role": .string("user"), "text": .string(secret)])])])
        let sourceID = try a.execute("snapshot")["events"].arrayValue.first!["id"].stringValue!
        let linked = try a.execute("note.create", params: ["space_id": .string(space), "title": .string("Derived"), "body": .string(secret), "source_ids": .array([.string(sourceID)])])
        let ca = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        let cb = try CloudSyncCoordinator(store: b, directory: folder, environment: env)
        _ = try ca.sync(); _ = try cb.sync()
        var original: [URL: Data] = [:]
        for file in try recordFiles(folder) { let bytes = try Data(contentsOf: file); if String(decoding: bytes, as: UTF8.self).contains(secret) { original[file] = bytes } }
        XCTAssertEqual(original.count, 3)
        _ = try a.execute("history.purge", params: ["session_id": history["session_id"]])
        _ = try ca.sync(); _ = try cb.sync()
        for file in try recordFiles(folder) { XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(secret)) }
        XCTAssertEqual(try b.execute("snapshot")["events"].arrayValue.count, 0)
        let purgedNote = try b.execute("snapshot")["notes"].arrayValue.first { $0["id"] == linked["note_id"] }!
        XCTAssertEqual(purgedNote["body"].stringValue, "")
        // Simulate late redelivery of the original source bytes. Durable purge
        // records force canonical redaction before any projection or re-export.
        for (file, bytes) in original { try bytes.write(to: file, options: [.atomic]) }
        _ = try cb.sync(); _ = try ca.sync()
        for file in try recordFiles(folder) { XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(secret)) }
        XCTAssertEqual(try a.execute("snapshot")["events"].arrayValue.count, 0)
        XCTAssertEqual(try b.execute("search", params: ["query": .string(secret)])["results"].arrayValue.count, 0)
    }
    func testSparseCloudDeliveryWaitsForReferencesWithoutClaimingComplete() throws {
        let (_, a, b, folder) = try setupStores(), env = FixtureCloudEnvironment()
        let (_, noteID, _) = try createNote(a)
        let ca = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        let cb = try CloudSyncCoordinator(store: b, directory: folder, environment: env)
        _ = try ca.sync()
        let spaceFile = try recordFiles(folder).first { url in
            (try? JSONValue.decode(Data(contentsOf: url))["kind"].stringValue) == "space"
        }!
        let spaceBytes = try Data(contentsOf: spaceFile)
        try FileManager.default.removeItem(at: spaceFile)
        let sparse = try cb.sync()
        XCTAssertEqual(sparse["state"].stringValue, "pending")
        XCTAssertGreaterThan(sparse["pending_dependencies"].intValue, 0)
        XCTAssertEqual(try b.execute("snapshot")["notes"].arrayValue.count, 0)
        try spaceBytes.write(to: spaceFile, options: [.atomic])
        let settled = try cb.sync()
        XCTAssertEqual(settled["pending_dependencies"].intValue, 0)
        XCTAssertEqual(settled["state"].stringValue, "uploaded")
        XCTAssertEqual(try b.execute("snapshot")["notes"].arrayValue.first?["id"].stringValue, noteID)
    }

    func testAccountChangeStopsTransferAndSurvivesCoordinatorRestart() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        _ = try createNote(a)
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        env.account = Data("test-account-b".utf8)
        XCTAssertThrowsError(try coordinator.sync()) { XCTAssertEqual(($0 as? MioError)?.code, "icloud_account_changed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Mio-records-v1").path))
        XCTAssertEqual(try a.execute("sync.pending")["count"].intValue, 2)
        XCTAssertThrowsError(try CloudSyncCoordinator(store: a, directory: folder, environment: env)) { XCTAssertEqual(($0 as? MioError)?.code, "icloud_account_changed") }
        env.account = nil
        XCTAssertThrowsError(try coordinator.sync()) { XCTAssertEqual(($0 as? MioError)?.code, "icloud_unavailable") }
    }
    func testCorruptedCloudPayloadIsRejectedBeforeMutationOrAcknowledgement() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        env.uploaded = false
        _ = try createNote(a)
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        _ = try coordinator.sync()
        let url = try recordFiles(folder).first!
        var altered = try JSONValue.decode(Data(contentsOf: url)).objectValue
        altered["timestamp"] = .string("altered-without-updating-hash")
        try JSONValue.object(altered).encoded().write(to: url, options: [.atomic])
        XCTAssertThrowsError(try coordinator.sync()) { XCTAssertEqual(($0 as? MioError)?.code, "cloud_invalid_record") }
        XCTAssertEqual(try a.execute("sync.pending")["count"].intValue, 2)
    }

    func testPurgeDuringUploadRechecksLatestHashAndDoesNotAcknowledgeOldBytes() throws {
        let (_, a, _, folder) = try setupStores(), env = FixtureCloudEnvironment()
        let (space, _, _) = try createNote(a)
        let marker = "concurrent-purge-" + UUID().uuidString
        let history = try a.execute("history.import", params: ["space_id": .string(space), "external_id": .string("racing-source"), "events": .array([.object(["source_id": .string("racing-item"), "text": .string(marker)])])])
        let coordinator = try CloudSyncCoordinator(store: a, directory: folder, environment: env)
        var purged = false
        env.uploadHook = { url in
            let record = try JSONValue.decode(Data(contentsOf: url))
            if !purged && record["kind"].stringValue == "event" {
                purged = true
                _ = try a.execute("history.purge", params: ["session_id": history["session_id"]])
            }
        }
        let first = try coordinator.sync()
        XCTAssertTrue(purged)
        XCTAssertEqual(first["state"].stringValue, "pending", "New purge tombstone needs its own delivery receipt")
        for file in try recordFiles(folder) { XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(marker)) }
        env.uploadHook = nil
        XCTAssertEqual(try coordinator.sync()["pending_records"].intValue, 0)
    }

    /// Opt-in real cloud test. Folder must be an isolated Mio-validation-* folder,
    /// and all local stores/receipts stay under this task's cloud artifacts.
    func testRealDriveUploadThenEvictedDownloadIntoIndependentStore() throws {
        guard let path = ProcessInfo.processInfo.environment["MIO_CLOUD_LIVE_FOLDER"],
              let artifacts = ProcessInfo.processInfo.environment["MIO_CLOUD_LIVE_ARTIFACTS"] else {
            throw XCTSkip("Real iCloud test requires the isolated folder and artifact location.")
        }
        let baseFolder = URL(fileURLWithPath: path), root = URL(fileURLWithPath: artifacts).appendingPathComponent("live-" + UUID().uuidString.lowercased())
        guard baseFolder.lastPathComponent.hasPrefix("Mio-validation-") else { throw MioError("unsafe_validation_folder", "Use a new isolated Mio-validation UUID folder.") }
        let folder = baseFolder.appendingPathComponent("Mio-validation-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let a = try MioStore(directory: root.appendingPathComponent("a")), b = try MioStore(directory: root.appendingPathComponent("b"))
        let marker = "Mio real cloud " + UUID().uuidString.lowercased()
        let (spaceID, noteID, revisionID) = try createNote(a, body: marker)
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MioCoreTests/Fixtures/Hybrid")
        let pdfBytes=try Data(contentsOf:fixture.appendingPathComponent("record-01.pdf")),imageBytes=try Data(contentsOf:fixture.appendingPathComponent("record-03.png"))
        let file=try a.execute("note.create",params:["space_id":.string(spaceID),"title":.string("NativePolicy"),"body":.string(""),"file_name":.string("policy.pdf"),"mime_type":.string("application/pdf"),"file_base64":.string(pdfBytes.base64EncodedString())])
        let image=try a.execute("note.create",params:["space_id":.string(spaceID),"title":.string("NativeImage"),"body":.string("[[NativePolicy]]"),"file_name":.string("image.png"),"mime_type":.string("image/png"),"file_base64":.string(imageBytes.base64EncodedString())])
        let ca = try CloudSyncCoordinator(store: a, directory: folder), cb = try CloudSyncCoordinator(store: b, directory: folder)
        var receipt: JSONValue = .null
        let deadline = Date().addingTimeInterval(55)
        repeat {
            do { receipt = try ca.sync() }
            catch { receipt = ca.status() }
            if receipt["state"].stringValue == "uploaded" { break }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        guard receipt["state"].stringValue == "uploaded", receipt["pending_records"].intValue == 0 else {
            let failure: JSONValue = .object(["mode": .string("real-iCloud-Drive"), "folder": .string(folder.path), "sender": receipt, "cloud_delivery_verified": .bool(false)])
            try failure.encoded().write(to: root.appendingPathComponent("failed-receipt.json"), options: [.atomic])
            XCTFail("No actual uploaded receipt within deadline: \(receipt). Evidence: \(root.path)")
            return
        }
        let exported = try a.execute("replica.export")
        let cloudPaths = try recordFiles(folder)
        for file in cloudPaths { try FileManager.default.evictUbiquitousItem(at: file) }
        var nonresident = 0
        for file in cloudPaths {
            var fresh = file; fresh.removeAllCachedResourceValues()
            if try fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus == .notDownloaded { nonresident += 1 }
        }
        XCTAssertGreaterThan(nonresident, 0, "Eviction must make at least one record nonresident")
        let receive = try cb.sync()
        let note = try b.execute("snapshot")["notes"].arrayValue.first { $0["id"].stringValue == noteID }
        XCTAssertEqual(note?["body"].stringValue, marker)
        XCTAssertEqual(note?["revision_id"].stringValue, revisionID)
        XCTAssertEqual(try b.execute("replica.export")["records"], exported["records"])
        XCTAssertEqual(try b.execute("read",params:["kind":.string("source"),"id":file["file_id"]])["sha256"],file["file"]["sha256"])
        XCTAssertEqual(try b.execute("read",params:["kind":.string("source"),"id":image["file_id"]])["sha256"],image["file"]["sha256"])
        XCTAssertTrue(try b.execute("read",params:["kind":.string("note"),"id":image["id"]])["links"].arrayValue.contains{$0["to_note_id"]==file["id"]})
        let evidence: JSONValue = .object(["mode": .string("real-iCloud-Drive-two-local-stores"), "cross_device_verified": .bool(false), "nonresident_records_before_receive": .number(Double(nonresident)), "sender": receipt, "receiver": receive, "note_id": .string(noteID), "revision_id": .string(revisionID), "exact_record_match": .bool(true),"pdf_original_sha256":file["file"]["sha256"],"image_original_sha256":image["file"]["sha256"],"file_graph_link_verified":.bool(true)])
        try evidence.encoded().write(to: root.appendingPathComponent("receipt.json"), options: [.atomic])
        print("Mio real iCloud evidence: \(root.path)")
    }
}
