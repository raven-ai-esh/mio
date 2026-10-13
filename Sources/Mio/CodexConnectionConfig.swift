import Foundation
import Darwin
import MioCore
import MioBridge

/// One explicit Mio profile. It never changes Codex's global approval policy.
struct CodexConnectionConfig: Sendable {
    let profileID: String
    let token: String
    let appExecutable: URL
    let dataDirectory: URL?
    var serverName: String { "mio-" + String(profileID.prefix(8)).lowercased() }
    static let approvedTools = MCPRunner.toolNames

    func validate() throws {
        guard profileID.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil, !token.isEmpty else {
            throw MioError("invalid_profile", "Профиль подключения недоступен")
        }
    }
    static func toml(_ value: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    var toolTables: String {
        Self.approvedTools.map { "[mcp_servers.\(serverName).tools.\($0)]\napproval_mode = \"approve\"" }.joined(separator: "\n\n")
    }
    func snippet() throws -> String {
        try validate()
        var result = "[mcp_servers.\(serverName)]\ncommand = \(try Self.toml(appExecutable.path))\nargs = [\"--mcp\"]\n\n[mcp_servers.\(serverName).env]\nMIO_PROFILE_TOKEN = \(try Self.toml(token))"
        if let dataDirectory { result += "\nMIO_DATA_DIRECTORY = \(try Self.toml(dataDirectory.path))" }
        return result + "\n\n" + toolTables + "\n"
    }
    var edits: [JSONValue] {
        let root = "mcp_servers." + serverName
        var values: [(String, JSONValue)] = [(root + ".command", .string(appExecutable.path)),
            (root + ".args", .array([.string("--mcp")])), (root + ".enabled", .bool(true)),
            (root + ".env.MIO_PROFILE_TOKEN", .string(token))]
        if let dataDirectory { values.append((root + ".env.MIO_DATA_DIRECTORY", .string(dataDirectory.path))) }
        values += Self.approvedTools.map { (root + ".tools." + $0 + ".approval_mode", .string("approve")) }
        return values.map { .object(["keyPath": .string($0.0), "value": $0.1, "mergeStrategy": .string("upsert")]) }
    }

    /// Legacy CLI fallback supports only a new namespace; ambiguous/preexisting tables are preserved.
    func appendingApprovals(to text: String) throws -> String {
        let prefix = "mcp_servers." + serverName + ".tools"
        var inServerTable = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                let section = trimmed.split(separator: "]", maxSplits: 1).first.map(String.init) ?? ""
                let canonical = section.dropFirst().replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "")
                inServerTable = canonical == "mcp_servers." + serverName
                if canonical == prefix || canonical.hasPrefix(prefix + ".") {
                    throw MioError("codex_config_conflict", "Codex уже содержит настройки инструментов этого профиля. Используйте поддерживаемый редактор конфигурации.")
                }
            } else if inServerTable && trimmed.range(of: "^tools\\s*=", options: .regularExpression) != nil {
                throw MioError("codex_config_conflict", "Настройки инструментов уже заданы встроенной таблицей. Они сохранены без изменений.")
            }
        }
        return text + (text.hasSuffix("\n") ? "\n" : "\n\n") + toolTables + "\n"
    }
}

enum CodexMCPInstaller {
    static func install(executable: URL, profileID: String, token: String,
                        appExecutable: URL, dataDirectory: URL? = nil, codexHome: URL? = nil,
                        backupDirectory: URL) throws -> String {
        let config = CodexConnectionConfig(profileID: profileID, token: token, appExecutable: appExecutable, dataDirectory: dataDirectory)
        try config.validate()
        var environment = ProcessInfo.processInfo.environment
        let home = codexHome ?? environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        environment["CODEX_HOME"] = home.path
        let source = home.appendingPathComponent("config.toml")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backup = backupDirectory.appendingPathComponent("codex-config-\(UUID().uuidString).toml")
            try FileManager.default.copyItem(at: source, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let api = try CodexConfigurationRPC(executable: executable, environment: environment)
        defer { api.close() }
        do {
            let before = try api.call("config/read", params: ["includeLayers": .bool(false)])["config"]
            let existing = before["mcp_servers"][config.serverName]
            if existing != .null, existing["env"]["MIO_PROFILE_TOKEN"].stringValue != token {
                throw MioError("codex_profile_conflict", "Имя подключения уже используется другим профилем. Создайте новое подключение, чтобы сохранить существующее.")
            }
            do {
                _ = try api.call("config/batchWrite", params: ["edits": .array(config.edits), "filePath": .string(source.path)])
            } catch let error as CodexConfigurationAPIError where error.code == -32601 {
                for edit in config.edits {
                    var params = edit.objectValue; params["filePath"] = .string(source.path)
                    _ = try api.call("config/value/write", params: params)
                }
            }
            let after = try api.call("config/read", params: ["includeLayers": .bool(false)])["config"]["mcp_servers"][config.serverName]
            guard after["command"].stringValue == appExecutable.path, after["args"].arrayValue == [.string("--mcp")],
                  after["env"]["MIO_PROFILE_TOKEN"].stringValue == token,
                  CodexConnectionConfig.approvedTools.allSatisfy({ after["tools"][$0]["approval_mode"].stringValue == "approve" }) else {
                throw MioError("codex_config_unverified", "Codex сохранил не все настройки подключения. Проверьте конфигурацию перед новой сессией.")
            }
        } catch let error as CodexConfigurationAPIError where error.code == -32601 {
            api.close()
            try legacyInstall(executable: executable, environment: environment, source: source, config: config)
        }
        return config.serverName
    }

    private static func legacyInstall(executable: URL, environment: [String: String], source: URL, config: CodexConnectionConfig) throws {
        let original = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        // A fallback must not replace an existing profile or append duplicate TOML tables.
        guard !original.contains(config.serverName) else { throw MioError("codex_config_conflict", "Профиль уже существует. Эта версия Codex требует ручного обновления настроек инструментов.") }
        let process = Process(); process.executableURL = executable
        var args = ["mcp", "add", config.serverName, "--env", "MIO_PROFILE_TOKEN=\(config.token)"]
        if let directory = config.dataDirectory { args += ["--env", "MIO_DATA_DIRECTORY=\(directory.path)"] }
        args += ["--", config.appExecutable.path, "--mcp"]
        process.arguments = args; process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw MioError("codex_config_timeout", "Codex не завершил установку вовремя") }
        guard process.terminationStatus == 0 else { throw MioError("codex_config_failed", "Codex не смог сохранить подключение. Используйте скопированную конфигурацию.") }
        let updated = try config.appendingApprovals(to: String(contentsOf: source, encoding: .utf8))
        try Data(updated.utf8).write(to: source, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    }
}

private struct CodexConfigurationAPIError: Error, LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { "Codex отклонил настройку подключения (\(code)): \(message)" }
}

/// Short-lived configuration-only App Server client; no account, history or model requests.
private final class CodexConfigurationRPC {
    private let process = Process(), input = Pipe(), output = Pipe()
    private var buffer = Data(), nextID = 0, closed = false
    init(executable: URL, environment: [String: String]) throws {
        process.executableURL = executable; process.environment = environment
        process.arguments = ["--disable", "apps", "--disable", "plugins", "--disable", "hooks", "app-server", "--stdio"]
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            _ = try call("initialize", params: ["clientInfo": .object(["name": .string("mio_configuration"), "version": .string("0.1.0")])])
            var data = try JSONValue.object(["method": .string("initialized")]).encoded(); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() {
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    func call(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
        guard ["initialize", "config/read", "config/batchWrite", "config/value/write"].contains(method) else { throw MioError("invalid_config_method", "Недопустимая операция настройки Codex") }
        nextID += 1
        var data = try JSONValue.object(["id": .number(Double(nextID)), "method": .string(method), "params": .object(params)]).encoded(); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline)); buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newline) + 1)
                let response = try JSONValue.decode(line)
                guard response["id"].intValue == nextID else { continue }
                if case .object = response["error"] { throw CodexConfigurationAPIError(code: response["error"]["code"].intValue, message: response["error"]["message"].stringValue ?? "Codex отклонил настройку") }
                return response["result"]
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MioError("codex_config_failed", "Не удалось прочитать ответ Codex") }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &chunk, chunk.count)
            guard count > 0 else { throw MioError("codex_config_failed", "Codex завершил соединение настройки") }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 8_388_608 else { throw MioError("codex_config_failed", "Ответ настройки Codex превышает допустимый объём") }
        }
        close(); throw MioError("codex_config_timeout", "Codex не ответил на настройку вовремя")
    }
}
