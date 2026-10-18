import Foundation
import CryptoKit
import MioCore

/// Local SQLite stays local. This transport exchanges only credential-free records
/// in an explicitly selected iCloud Drive folder; upload receipts do not prove a
/// second device has imported them. Call sync off the main thread.
public final class CloudSyncCoordinator: @unchecked Sendable {
    private static let bindingAccessLock = NSRecursiveLock()
    public let directory: URL
    private let store: MioStore
    private let environment: CloudEnvironment
    private let lock = NSRecursiveLock()
    private let bindingURL: URL
    private let binding: AccountBinding
    private var identityObserver: NSObjectProtocol?
    private var lastStatus: JSONValue = .object(["state": .string("pending"), "transport": .string("iCloud Drive"), "cross_device_verified": .bool(false)])
    private var importedGenerations: [String: RecordGeneration] = [:]
    private var importedReceipts: [String: RecordReceipt] = [:]
    private var confirmedReceipts: [String: String] = [:]
    private let maximumRecordBytes = 32 * 1024 * 1024
    private let maximumTotalBytes = 128 * 1024 * 1024

    public convenience init(store: MioStore, directory: URL) throws {
        try self.init(store: store, directory: directory, environment: SystemCloudEnvironment())
    }

    init(store: MioStore, directory: URL, environment: CloudEnvironment) throws {
        Self.bindingAccessLock.lock(); defer { Self.bindingAccessLock.unlock() }
        self.store = store
        self.directory = directory.standardizedFileURL
        self.environment = environment
        self.bindingURL = store.directory.appendingPathComponent("icloud-drive-binding.json")
        guard directory.isFileURL,
              let identity = try environment.identity(),
              try environment.metadata(directory).ubiquitous else {
            throw MioError("icloud_unavailable", "Select a folder in iCloud Drive while signed in to iCloud.")
        }
        let folderIdentity = try environment.folderIdentity(directory)
        if FileManager.default.fileExists(atPath: bindingURL.path) {
            let prior = try JSONDecoder().decode(AccountBinding.self, from: Data(contentsOf: bindingURL))
            guard prior.schemaVersion == 1 else { throw MioError("cloud_binding_incompatible", "Unsupported iCloud binding version.") }
            guard try environment.identitiesEqual(prior.identity, identity) else {
                throw MioError("icloud_account_changed", "The iCloud account changed. Sending the existing memory requires an explicit transfer.")
            }
            guard prior.folderIdentity == folderIdentity else {
                throw MioError("icloud_folder_changed", "The selected sync folder differs from the bound folder. Select the original folder or explicitly reconnect.")
            }
            binding = prior
        } else {
            binding = AccountBinding(schemaVersion: 1, identity: identity, folderIdentity: folderIdentity)
            let data = try JSONEncoder().encode(binding)
            try data.write(to: bindingURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bindingURL.path)
        }
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { _ = self?.status() }
        }
    }

    deinit { if let identityObserver { NotificationCenter.default.removeObserver(identityObserver) } }

    /// Explicit local-owner folder/account transfer. Validate the destination
    /// before replacing the binding. Run off the UI thread: an active old sync
    /// finishes before rebind returns, then old coordinators become invalid.
    public static func reconnect(store: MioStore, directory: URL) throws -> CloudSyncCoordinator {
        try reconnect(store: store, directory: directory, environment: SystemCloudEnvironment())
    }
    static func reconnect(store: MioStore, directory: URL, environment: CloudEnvironment) throws -> CloudSyncCoordinator {
        bindingAccessLock.lock(); defer { bindingAccessLock.unlock() }
        guard directory.isFileURL, let identity = try environment.identity(), try environment.metadata(directory).ubiquitous else {
            throw MioError("icloud_unavailable", "Select a folder in iCloud Drive while signed in to iCloud.")
        }
        // Confirm that this macOS token can be compared before touching a prior
        // binding. Directory identity also rejects nonexistent/replaced folders.
        guard try environment.identitiesEqual(identity, identity) else { throw MioError("cloud_identity_unsupported", "The iCloud identity cannot be validated.") }
        let destination = AccountBinding(schemaVersion: 1, identity: identity, folderIdentity: try environment.folderIdentity(directory))
        let path = store.directory.appendingPathComponent("icloud-drive-binding.json")
        let prior = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
        do {
            try JSONEncoder().encode(destination).write(to: path, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return try CloudSyncCoordinator(store: store, directory: directory, environment: environment)
        } catch {
            if let prior { try prior.write(to: path, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
            else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            throw error
        }
    }

    /// Only call after a deliberate local-owner reconnect/transfer action. This
    /// does not clear memory or pending changes and never signs the user out.
    public static func removeLocalBinding(store: MioStore) throws {
        bindingAccessLock.lock(); defer { bindingAccessLock.unlock() }
        let path = store.directory.appendingPathComponent("icloud-drive-binding.json")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    public func status() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        do { try checkBinding() } catch {
            lastStatus = .object(["state": .string("error"), "code": .string((error as? MioError)?.code ?? "icloud_io_error"), "message": .string(error.localizedDescription), "transport": .string("iCloud Drive"), "cross_device_verified": .bool(false)])
        }
        var value = lastStatus.objectValue
        let pending = try? store.execute("sync.status")
        let records = (try? store.execute("sync.inventory"))?["records"].arrayValue ?? []
        let confirmed = records.filter { confirmedReceipts[$0["id"].stringValue ?? ""] == $0["content_hash"].stringValue }.count
        let verified = !records.isEmpty && confirmed == records.count && pending?["count"].intValue == 0 && pending?["pending_dependencies"].intValue == 0
        value["pending_records"] = pending?["count"] ?? .null
        value["pending_dependencies"] = pending?["pending_dependencies"] ?? .null
        value["total_records"] = .number(Double(records.count))
        value["confirmed_uploaded_records"] = .number(Double(confirmed))
        value["delivery_verified"] = .bool(verified && value["state"]?.stringValue != "error")
        if value["state"]?.stringValue != "error" {
            value["state"] = .string(records.isEmpty ? "connected" : verified ? "uploaded" : "pending")
        }
        return .object(value)
    }

    @discardableResult
    public func sync() throws -> JSONValue {
        Self.bindingAccessLock.lock(); defer { Self.bindingAccessLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        do {
            try checkBinding()
            let recordDirectory = directory.appendingPathComponent("Mio-records-v1", isDirectory: true)
            try coordinatedWrite(at: recordDirectory) { url in
                try self.checkBinding()
                if FileManager.default.fileExists(atPath: url.path) {
                    let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard info.isDirectory == true, info.isSymbolicLink != true else { throw MioError("cloud_invalid_folder", "The Mio record directory must be a real directory.") }
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let urls = try FileManager.default.contentsOfDirectory(at: recordDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
                .filter { $0.lastPathComponent.hasSuffix(".mio-record.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard urls.count <= 100_000 else { throw MioError("cloud_limit", "The sync folder exceeds the supported record limit.") }
            let knownNames = Set(urls.map(\.lastPathComponent))
            var nextGenerations = importedGenerations.filter { knownNames.contains($0.key) }
            var nextReceipts = importedReceipts.filter { knownNames.contains($0.key) }
            var verifiedHashes: [String: String] = [:]
            var requiresReceipt = Set<String>()
            var conflictedNames = Set<String>()
            var remote: [JSONValue] = [], total = 0
            for url in urls {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw MioError("cloud_invalid_record", "A sync record cannot be a symbolic link.") }
                let provider = try environment.metadata(url)
                if provider.unresolvedConflicts { conflictedNames.insert(url.lastPathComponent) }
                if !provider.unresolvedConflicts, let generation = try recordGeneration(url), let old = nextGenerations[url.lastPathComponent], generation.matches(old), let receipt = nextReceipts[url.lastPathComponent] {
                    if let after=try recordGeneration(url),after.matches(generation) {
                        if hasDeliveryProof(provider) { verifiedHashes[receipt.id] = receipt.hash }
                        else { requiresReceipt.insert(url.lastPathComponent) }
                        continue
                    }
                }
                try checkBinding()
                try environment.requestDownload(url)
                let data = try coordinatedRead(at: url)
                guard data.count <= maximumRecordBytes else { throw MioError("cloud_limit", "A sync record exceeds the supported size.") }
                total += data.count
                guard total <= maximumTotalBytes else { throw MioError("cloud_limit", "The sync batch exceeds the supported size.") }
                let record = try validatedRecord(data, filename: url.lastPathComponent)
                remote.append(record)
                nextGenerations[url.lastPathComponent] = try recordGeneration(url)
                let receipt = RecordReceipt(id: record["id"].stringValue!, hash: record["content_hash"].stringValue!)
                nextReceipts[url.lastPathComponent] = receipt
                let currentProvider = try environment.metadata(url)
                if hasDeliveryProof(currentProvider) { verifiedHashes[receipt.id] = receipt.hash }
                else { requiresReceipt.insert(url.lastPathComponent) }
            }
            try checkBinding()
            if !remote.isEmpty {
                _ = try store.execute("replica.merge", params: ["document": .object(["schema_version": .number(2), "format": .string("mio-records"), "records": .array(remote), "profiles": .array([])])])
                // Late source bytes may normalize to an already known redaction.
                // Even when SQLite needs no change, repair the stale cloud payload
                // and retain a new exact-hash delivery requirement across restart.
                let repairs = try remote.compactMap { incoming -> JSONValue? in
                    let canonical = try self.currentRecord(incoming["id"].stringValue!)
                    guard canonical["content_hash"] != incoming["content_hash"] else { return nil }
                    return .object(["id": canonical["id"], "content_hash": canonical["content_hash"]])
                }
                if !repairs.isEmpty { _ = try store.execute("sync.queue", params: ["records": .array(repairs)]) }
            }
            importedGenerations = nextGenerations
            importedReceipts = nextReceipts
            try checkBinding()
            let document = try store.execute("sync.inventory")
            let allRecords = document["records"].arrayValue
            let pendingBefore = try store.execute("sync.status",params:["include_ids":.bool(true)])
            let pendingIDs = Set(pendingBefore["record_ids"].arrayValue.compactMap(\.stringValue))
            let records = try allRecords.filter { record in
                if pendingIDs.contains(record["id"].stringValue ?? "") { return true }
                let name = try recordFilename(record)
                return !knownNames.contains(name) || conflictedNames.contains(name) || requiresReceipt.contains(name)
            }
            let restaged = records.filter { !pendingIDs.contains($0["id"].stringValue ?? "") }.map { JSONValue.object(["id": $0["id"], "content_hash": $0["content_hash"]]) }
            if !restaged.isEmpty { _ = try store.execute("sync.queue", params: ["records": .array(restaged)]) }
            var uploaded: [JSONValue] = [], written = 0
            var deliveryErrors: [MioError] = []
            var unstable = 0
            for exportedRecord in records {
                guard let id = exportedRecord["id"].stringValue else { throw MioError("cloud_invalid_record", "A local record has no ID.") }
                var stabilized = false
                for _ in 0..<3 {
                    try checkBinding()
                    let record = try currentRecord(id)
                    let payload = try record.encoded()
                    guard payload.count <= maximumRecordBytes else { throw MioError("cloud_limit", "A local record exceeds the supported sync size.") }
                    let filename = try recordFilename(record)
                    _ = try validatedRecord(payload, filename: filename)
                    let url = recordDirectory.appendingPathComponent(filename)
                    var changed = false, stale = false
                    try coordinatedWrite(at: url) { coordinatedURL in
                        try self.checkBinding()
                        guard try self.currentRecord(id)["content_hash"] == record["content_hash"] else { stale = true; return }
                        if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                            let oldBytes = try Data(contentsOf: coordinatedURL)
                            let old = try self.validatedRecord(oldBytes, filename: filename)
                            if old != record {
                                guard self.isRedacted(record) else {
                                    throw MioError("cloud_record_conflict", "An immutable cloud record has different content. No version was overwritten.")
                                }
                                try payload.write(to: coordinatedURL, options: [.atomic])
                                changed = true
                            }
                        } else {
                            try payload.write(to: coordinatedURL, options: [.atomic])
                            changed = true
                        }
                        if self.isRedacted(record) {
                            // Privacy deletion is the exception to immutable payloads.
                            // Remove provider-maintained previous/conflict copies too.
                            try NSFileVersion.removeOtherVersionsOfItem(at: coordinatedURL)
                        }
                    }
                    if changed { written += 1 }
                    if stale { continue }
                    // Read/metadata after releasing the write accessor. Never wait
                    // for uploaded status inside a coordinated accessor.
                    let persisted = try coordinatedRead(at: url)
                    guard persisted == payload else { throw MioError("cloud_record_conflict", "The cloud record changed during synchronization.") }
                    let metadata = try environment.metadata(url)
                    if metadata.unresolvedConflicts { throw MioError("cloud_file_conflict", "iCloud reports an unresolved file conflict.") }
                    if metadata.uploadError != nil { deliveryErrors.append(providerFailure(metadata, uploading: true)) }
                    if metadata.downloadError != nil { throw providerFailure(metadata, uploading: false) }
                    // A purge can occur while the provider reports upload status.
                    // Republish the latest redaction instead of acknowledging stale
                    // bytes; sustained changes retain pending status for the retry.
                    guard try currentRecord(id)["content_hash"] == record["content_hash"] else { continue }
                    if hasDeliveryProof(metadata) {
                        uploaded.append(.object(["id": record["id"], "content_hash": record["content_hash"]]))
                        verifiedHashes[id] = record["content_hash"].stringValue!
                    } else { verifiedHashes.removeValue(forKey: id) }
                    importedGenerations[filename] = try recordGeneration(url)
                    importedReceipts[filename] = RecordReceipt(id: id, hash: record["content_hash"].stringValue!)
                    stabilized = true
                    break
                }
                if !stabilized { unstable += 1 }
            }
            try checkBinding()
            // Exact ID+hash acknowledgement cannot clear a newer redaction or edit.
            if !uploaded.isEmpty { _ = try store.execute("sync.ack", params: ["records": .array(uploaded)]) }
            let pendingState = try store.execute("sync.status")
            let pending = pendingState["count"], dependencies = pendingState["pending_dependencies"]
            confirmedReceipts = verifiedHashes
            let currentRecords = try store.execute("sync.inventory")["records"].arrayValue
            let confirmed = currentRecords.filter { verifiedHashes[$0["id"].stringValue ?? ""] == $0["content_hash"].stringValue }.count
            let verified = !currentRecords.isEmpty && confirmed == currentRecords.count && pending.intValue == 0 && dependencies.intValue == 0 && unstable == 0
            if let error = deliveryErrors.first {
                var details = error.details.objectValue
                details["failed_records"] = .number(Double(deliveryErrors.count)); details["pending_records"] = pending
                throw MioError(error.code, error.message, details: .object(details))
            }
            lastStatus = .object([
                "state": .string(currentRecords.isEmpty ? "connected" : verified ? "uploaded" : "pending"),
                "total_records": .number(Double(currentRecords.count)),
                "confirmed_uploaded_records": .number(Double(confirmed)),
                "delivery_verified": .bool(verified),
                "transport": .string("iCloud Drive"),
                "pending_records": pending,
                "pending_dependencies": dependencies,
                "uploaded_records": .number(Double(uploaded.count)),
                "written_records": .number(Double(written)),
                "downloaded_records": .number(Double(remote.count)),
                "unstable_records": .number(Double(unstable)),
                "cross_device_verified": .bool(false),
                "checked_at": .string(ISO8601DateFormatter().string(from: Date()))
            ])
            return lastStatus
        } catch {
            let reported = normalizedFailure(error)
            lastStatus = .object(["state": .string("error"), "code": .string(reported.code), "message": .string(reported.message), "provider": reported.details, "delivery_verified": .bool(false), "transport": .string("iCloud Drive"), "cross_device_verified": .bool(false)])
            throw reported
        }
    }

    private func normalizedFailure(_ error: Error) -> MioError {
        if let error = error as? MioError { return error }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable.rawValue {
            return MioError("icloud_server_unavailable", "Could not connect to iCloud servers. Local changes remain queued.", details: .object(["domain": .string(error.domain), "code": .number(Double(error.code)), "kind": .string("NSUbiquitousFileUbiquityServerNotAvailable")]))
        }
        return MioError("icloud_io_error", error.localizedDescription, details: .object(["domain": .string(error.domain), "code": .number(Double(error.code))]))
    }
    private func hasDeliveryProof(_ metadata: CloudMetadata) -> Bool {
        metadata.ubiquitous && metadata.uploaded && !metadata.unresolvedConflicts && metadata.uploadError == nil && metadata.downloadError == nil
    }
    private func providerFailure(_ metadata: CloudMetadata, uploading: Bool) -> MioError {
        let domain = uploading ? metadata.uploadErrorDomain : metadata.downloadErrorDomain
        let code = uploading ? metadata.uploadErrorCode : metadata.downloadErrorCode
        let message = (uploading ? metadata.uploadError : metadata.downloadError) ?? "iCloud file operation failed."
        var details: [String: JSONValue] = ["operation": .string(uploading ? "upload" : "download")]
        if let domain { details["domain"] = .string(domain) }
        if let code { details["code"] = .number(Double(code)) }
        if domain == NSCocoaErrorDomain && code == CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable.rawValue {
            details["kind"] = .string("NSUbiquitousFileUbiquityServerNotAvailable")
            return MioError("icloud_server_unavailable", "Could not connect to iCloud servers. Local changes remain queued.", details: .object(details))
        }
        return MioError(uploading ? "icloud_upload_failed" : "icloud_download_failed", message, details: .object(details))
    }
    private func checkBinding() throws {
        guard FileManager.default.fileExists(atPath: bindingURL.path) else { throw MioError("icloud_binding_replaced", "This cloud connection was disconnected. Select the active connection.") }
        let active = try JSONDecoder().decode(AccountBinding.self, from: Data(contentsOf: bindingURL))
        guard active.folderIdentity == binding.folderIdentity, try environment.identitiesEqual(active.identity, binding.identity) else {
            throw MioError("icloud_binding_replaced", "The cloud connection changed. This previous connection cannot transfer memory.")
        }
        guard let current = try environment.identity() else { throw MioError("icloud_unavailable", "iCloud is unavailable. Pending memory remains local.") }
        guard try environment.identitiesEqual(binding.identity, current) else { throw MioError("icloud_account_changed", "The iCloud account changed. Synchronization stopped before transferring pending memory.") }
        guard try environment.metadata(directory).ubiquitous,
              try environment.folderIdentity(directory) == binding.folderIdentity else { throw MioError("icloud_folder_changed", "The bound iCloud Drive folder is unavailable or was replaced.") }
    }

    // Foundation generation identifiers change with data-fork writes and survive
    // restarts. Combine with file identity because atomic replacement changes the
    // inode; unsupported volumes fall back to full integrity-checked reads.
    private func recordGeneration(_ original: URL) throws -> RecordGeneration? {
        var url = original; url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .generationIdentifierKey])
        guard let file = values.fileResourceIdentifier as? NSObject,
              let generation = values.generationIdentifier as? NSObject else { return nil }
        return RecordGeneration(file: file, generation: generation)
    }
    private func currentRecord(_ id: String) throws -> JSONValue {
        let response = try store.execute("replica.record", params: ["id": .string(id)])
        return response["record"] == .null ? response : response["record"]
    }
    private func recordFilename(_ record: JSONValue) throws -> String {
        guard let id = record["id"].stringValue, !id.isEmpty else { throw MioError("cloud_invalid_record", "A sync record is missing its ID.") }
        return digest(Data(id.utf8)) + ".mio-record.json"
    }
    private func validatedRecord(_ bytes: Data, filename: String) throws -> JSONValue {
        let record = try JSONValue.decode(bytes)
        guard record["kind"].stringValue != "profile", let storedHash = record["content_hash"].stringValue,
              try recordFilename(record) == filename else { throw MioError("cloud_invalid_record", "Invalid or credential-bearing sync record.") }
        var content = record.objectValue; content.removeValue(forKey: "content_hash")
        guard digest(try JSONValue.object(content).encoded()) == storedHash else { throw MioError("cloud_invalid_record", "Sync record integrity check failed.") }
        return record
    }
    private func isRedacted(_ record: JSONValue) -> Bool {
        record["data"]["purged"].boolValue || record["data"]["redacted"].boolValue
    }
    private func coordinatedRead(at url: URL) throws -> Data {
        var coordinatorError: NSError?, bodyError: Error?, result: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { resolved in
            do {
                try self.checkBinding()
                let size = try resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= self.maximumRecordBytes else { throw MioError("cloud_limit", "A sync record exceeds the supported size.") }
                result = try Data(contentsOf: resolved)
            } catch { bodyError = error }
        }
        if let error = coordinatorError { throw error }; if let error = bodyError { throw error }
        guard let result else { throw MioError("icloud_io_error", "The coordinated read did not return data.") }
        return result
    }
    private func coordinatedWrite(at url: URL, body: (URL) throws -> Void) throws {
        var coordinatorError: NSError?, bodyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { resolved in
            do { try body(resolved) } catch { bodyError = error }
        }
        if let error = coordinatorError { throw error }; if let error = bodyError { throw error }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct AccountBinding: Codable {
    let schemaVersion: Int
    let identity: Data
    let folderIdentity: String
}
struct CloudMetadata {
    var ubiquitous: Bool
    var uploaded: Bool
    var unresolvedConflicts: Bool = false
    var uploadError: String? = nil
    var downloadError: String? = nil
    var uploadErrorCode: Int? = nil
    var uploadErrorDomain: String? = nil
    var downloadErrorCode: Int? = nil
    var downloadErrorDomain: String? = nil
}
protocol CloudEnvironment {
    func identity() throws -> Data?
    func identitiesEqual(_ lhs: Data, _ rhs: Data) throws -> Bool
    func folderIdentity(_ directory: URL) throws -> String
    func metadata(_ url: URL) throws -> CloudMetadata
    func requestDownload(_ url: URL) throws
}
struct SystemCloudEnvironment: CloudEnvironment {
    func identity() throws -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
    func identitiesEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let classes: [AnyClass] = [NSData.self, NSString.self, NSUUID.self, NSDictionary.self, NSArray.self, NSNumber.self]
        guard let first = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: lhs) as? NSObject,
              let second = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: rhs) else { throw MioError("cloud_identity_unsupported", "The iCloud identity token cannot be validated on this macOS version.") }
        return first.isEqual(second)
    }
    func folderIdentity(_ directory: URL) throws -> String {
        var url = directory; url.removeAllCachedResourceValues()
        let v = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true, let file = v.fileResourceIdentifier, let volume = v.volumeIdentifier else { throw MioError("icloud_folder_changed", "The sync folder cannot be identified safely.") }
        return SHA256.hash(data: Data((String(describing: volume) + ":" + String(describing: file)).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func metadata(_ original: URL) throws -> CloudMetadata {
        var url = original; url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey]
        let v = try url.resourceValues(forKeys: keys)
        return CloudMetadata(ubiquitous: v.isUbiquitousItem == true, uploaded: v.ubiquitousItemIsUploaded == true,
                             unresolvedConflicts: v.ubiquitousItemHasUnresolvedConflicts == true,
                             uploadError: v.ubiquitousItemUploadingError?.localizedDescription,
                             downloadError: v.ubiquitousItemDownloadingError?.localizedDescription,
                             uploadErrorCode: v.ubiquitousItemUploadingError?.code, uploadErrorDomain: v.ubiquitousItemUploadingError?.domain,
                             downloadErrorCode: v.ubiquitousItemDownloadingError?.code, downloadErrorDomain: v.ubiquitousItemDownloadingError?.domain)
    }
    func requestDownload(_ url: URL) throws { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
}

private struct RecordGeneration {
    let file: NSObject
    let generation: NSObject
    func matches(_ other: RecordGeneration) -> Bool { file.isEqual(other.file) && generation.isEqual(other.generation) }
}

private struct RecordReceipt {
    let id: String
    let hash: String
}
