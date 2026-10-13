import XCTest
import Foundation
import MioCore
import MioBridge
@testable import Mio

final class CodexConnectionConfigTests: XCTestCase {
    private let profileID = "01234567-89ab-4cde-8123-456789abcdef"

    func testMemoryAppAndBridgeDefaultNamespacesAgree() {
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.mio.memory/Runtime", isDirectory: true)
        XCTAssertEqual(BridgeRuntime.defaultDirectory, expected)
        if ProcessInfo.processInfo.environment["MIO_DATA_DIRECTORY"] == nil {
            XCTAssertEqual(MioPaths.runtime.directory, expected)
        }
    }

    func testSnippetExplicitlyApprovesOnlyMioToolsAndEscapesValues() throws {
        let config = CodexConnectionConfig(profileID: profileID, token: "quoted\"token\\value", appExecutable: URL(fileURLWithPath: "/Applications/Mio Memory.app/Contents/MacOS/Mio"), dataDirectory: URL(fileURLWithPath: "/tmp/Mio fixture"))
        let snippet = try config.snippet()
        for tool in MCPRunner.toolNames {
            XCTAssertTrue(snippet.contains("[mcp_servers.mio-01234567.tools.\(tool)]\napproval_mode = \"approve\""))
        }
        XCTAssertEqual(snippet.components(separatedBy: "approval_mode = \"approve\"").count - 1, 5)
        XCTAssertFalse(snippet.contains("approval_policy"))
        XCTAssertFalse(snippet.contains("[apps"))
        XCTAssertTrue(snippet.contains("quoted\\\"token\\\\value"))
        XCTAssertTrue(snippet.contains("MIO_DATA_DIRECTORY"))
        XCTAssertFalse(snippet.contains("\\/"), "JSON slash escaping is not a valid TOML basic-string escape")
        XCTAssertTrue(config.edits.allSatisfy { $0["keyPath"].stringValue!.hasPrefix("mcp_servers.mio-01234567.") })
        XCTAssertThrowsError(try CodexConnectionConfig(profileID: "bad.\n[policy]", token: "x", appExecutable: URL(fileURLWithPath: "/Mio"), dataDirectory: nil).snippet())
    }

    func testLegacyAppendRejectsExistingToolTablesRatherThanDuplicatingTOML() throws {
        let config = CodexConnectionConfig(profileID: profileID, token: "test", appExecutable: URL(fileURLWithPath: "/Mio"), dataDirectory: nil)
        let clean = "model = \"unchanged\"\n[mcp_servers.mio-01234567]\ncommand = \"/Mio\"\n"
        let appended = try config.appendingApprovals(to: clean)
        XCTAssertTrue(appended.hasPrefix(clean))
        XCTAssertThrowsError(try config.appendingApprovals(to: appended)) { XCTAssertEqual(($0 as? MioError)?.code, "codex_config_conflict") }
        XCTAssertThrowsError(try config.appendingApprovals(to: "[mcp_servers.\"mio-01234567\".tools.capture]\napproval_mode=\"prompt\"\n"))
        XCTAssertThrowsError(try config.appendingApprovals(to: "[mcp_servers.mio-01234567]\ntools = { capture = { approval_mode = \"prompt\" } }\n"))
    }

    func testGeneratedSnippetParsesInRealCodexWithQuotedTokenAndUnicodePath() throws {
        guard let codex = CodexExecutable.discover() else { throw XCTSkip("Codex CLI required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mio-snippet-parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = URL(fileURLWithPath: "/Applications/Память Mio \"native\".app/Contents/MacOS/Mio")
        let token = "quoted\"token\\value"
        let config = CodexConnectionConfig(profileID: profileID, token: token, appExecutable: app, dataDirectory: root.appendingPathComponent("notes with spaces"))
        try config.snippet().write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        // The installer first reads and validates existing Codex TOML via its real API.
        let server = try CodexMCPInstaller.install(executable: codex, profileID: profileID, token: token, appExecutable: app, dataDirectory: config.dataDirectory, codexHome: root, backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertEqual(server, config.serverName)
    }

    func testRealIsolatedCodexConfigRoundtripPreservesUserPolicyOtherServersAndBackups() throws {
        guard let codex = CodexExecutable.discover() else { throw XCTSkip("Codex CLI required for real config roundtrip") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mio-connection-config-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("codex", isDirectory: true), backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = home.appendingPathComponent("config.toml")
        let original = """
        # preserve this user comment and unrelated values
        approval_policy = "on-request"
        model = "user-chosen-model"
        [mcp_servers.unrelated]
        command = "/usr/bin/false"
        args = ["kept"]
        [mcp_servers.unrelated.tools.protected]
        approval_mode = "prompt"
        [mcp_servers.mio-01234567]
        command = "/old/Mio"
        args = ["--mcp"]
        startup_timeout_sec = 25
        [mcp_servers.mio-01234567.env]
        MIO_PROFILE_TOKEN = "fixture-token"
        EXTRA_USER_VALUE = "preserved"
        [mcp_servers.mio-01234567.tools.capture]
        approval_mode = "prompt"
        output_token_limit = 4096
        """ + "\n"
        try original.write(to: source, atomically: true, encoding: .utf8)
        let app = URL(fileURLWithPath: "/Applications/Mio Memory.app/Contents/MacOS/Mio")
        let installed = try CodexMCPInstaller.install(executable: codex, profileID: profileID, token: "fixture-token", appExecutable: app, dataDirectory: root.appendingPathComponent("data"), codexHome: home, backupDirectory: backups)
        XCTAssertEqual(installed, "mio-01234567")
        let after = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(after.contains("approval_policy = \"on-request\""))
        XCTAssertTrue(after.contains("model = \"user-chosen-model\""))
        XCTAssertTrue(after.contains("EXTRA_USER_VALUE = \"preserved\""))
        XCTAssertTrue(after.contains("startup_timeout_sec = 25"))
        XCTAssertTrue(after.contains("output_token_limit = 4096"))
        XCTAssertTrue(after.contains("[mcp_servers.unrelated.tools.protected]\napproval_mode = \"prompt\""))
        let firstBackups = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(firstBackups.count, 1)
        XCTAssertEqual(try String(contentsOf: firstBackups[0], encoding: .utf8), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: firstBackups[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Reinstall updates keys structurally; it does not append duplicate tool tables.
        _ = try CodexMCPInstaller.install(executable: codex, profileID: profileID, token: "fixture-token", appExecutable: app, dataDirectory: root.appendingPathComponent("data"), codexHome: home, backupDirectory: backups)
        let repeated = try String(contentsOf: source, encoding: .utf8)
        for tool in MCPRunner.toolNames { XCTAssertEqual(repeated.components(separatedBy: "[mcp_servers.mio-01234567.tools.\(tool)]").count - 1, 1) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 2)
        // A namespace collision must not replace another profile's credential.
        XCTAssertThrowsError(try CodexMCPInstaller.install(executable: codex, profileID: profileID, token: "different-profile", appExecutable: app, codexHome: home, backupDirectory: backups)) {
            XCTAssertEqual(($0 as? MioError)?.code, "codex_profile_conflict")
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), repeated)
    }
}
