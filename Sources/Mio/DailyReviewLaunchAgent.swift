import CryptoKit
import Darwin
import Foundation

/// One cheap timer check per minute while enabled. The worker decides whether
/// a local calendar day is due, so editing the time need not stop a live run.
struct DailyReviewLaunchAgent: Sendable {
    let storage: DailyReviewStorage
    let appExecutable: URL
    let home: URL
    let bundleIdentifier: String?

    init(storage: DailyReviewStorage, appExecutable: URL,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.storage = storage
        self.appExecutable = appExecutable
        self.home = home
        self.bundleIdentifier = bundleIdentifier
    }

    var label: String {
        let digest = SHA256.hash(data: Data(storage.directory.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "app.mio.memory.daily-review.\(suffix)"
    }

    var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true).appendingPathComponent(label + ".plist")
    }

    private var domain: String { "gui/\(getuid())" }
    private var service: String { domain + "/" + label }

    func save(_ draft: DailyReviewConfiguration, enable: Bool, confirmed: Bool, now: Date = Date()) throws -> DailyReviewConfiguration {
        try draft.validateSchedule()
        return try storage.withLock("settings.lock") {
            let previous = try storage.loadConfiguration()
            var updated = draft
            if enable {
                guard previous.enabled || confirmed else { throw DailyReviewError.activationRequired }
                _ = try updated.command()
                let unchangedTime = updated.hour == previous.hour && updated.minute == previous.minute
                updated.enabledSince = previous.enabled && unchangedTime ? previous.enabledSince : now
                updated.authorizationID = previous.enabled ? previous.authorizationID : UUID()
                try storage.saveConfiguration(updated)
                do {
                    try install()
                } catch {
                    try storage.saveConfiguration(previous)
                    if !previous.enabled { try? removeRegistration() }
                    throw error
                }
            } else {
                updated.enabledSince = nil
                updated.authorizationID = nil
                try storage.saveConfiguration(updated)
                if previous.enabled || FileManager.default.fileExists(atPath: plistURL.path) {
                    try removePlist()
                    // A running harness can finish its current phase. The
                    // next timer check unregisters the disabled service.
                    _ = try storage.withLock("run.lock", nonblocking: true) {
                        try unload()
                    }
                }
            }
            return updated
        } ?? { throw DailyReviewError.lockFailed }()
    }

    func removeRegistration() throws {
        try removePlist()
        try unload()
    }

    private func install() throws {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [appExecutable.path, "--daily-review"],
            "EnvironmentVariables": [
                "MIO_DATA_DIRECTORY": storage.directory.standardizedFileURL.path,
                "MIO_REVIEW_SCHEDULED": "1"
            ],
            "RunAtLoad": true,
            "StartInterval": 60
        ]
        if let bundleIdentifier { plist["AssociatedBundleIdentifiers"] = [bundleIdentifier] }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        if try run(["print", service]).status != 0 {
            let result = try run(["bootstrap", domain, plistURL.path])
            if result.status != 0 { throw DailyReviewError.launchAgentFailed(result.message) }
        }
    }

    private func removePlist() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private func unload() throws {
        guard try run(["print", service]).status == 0 else { return }
        let result = try run(["bootout", service])
        if result.status != 0, try run(["print", service]).status == 0 {
            throw DailyReviewError.launchAgentFailed(result.message)
        }
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, message: String) {
        let process = Process()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        let data = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data.prefix(1_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
