import Foundation
import AppKit
import SwiftUI
import MioCore
import MioBridge

enum MioPaths {
    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["MIO_DATA_DIRECTORY"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if Bundle.main.bundleIdentifier == "app.mio.memory.acceptance", let path = Bundle.main.object(forInfoDictionaryKey:"MioAcceptanceDataDirectory") as? String { return URL(fileURLWithPath:path,isDirectory:true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("app.mio.memory", isDirectory: true)
    }
    static var runtime: BridgeRuntime { BridgeRuntime(directory: directory.appendingPathComponent("Runtime", isDirectory: true)) }
    static var executable: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL }
    static var modelDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MIO_MODEL_DIRECTORY"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        if ProcessInfo.processInfo.environment["MIO_DATA_DIRECTORY"] != nil { return directory.appendingPathComponent("Models/embeddinggemma2-q8-v1", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.mio.memory/models/embeddinggemma2-q8-v1", isDirectory: true)
    }
    static var embeddingWorker: URL {
        if let path = ProcessInfo.processInfo.environment["MIO_EMBEDDING_WORKER"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return executable.deletingLastPathComponent().appendingPathComponent("MioEmbedWorker")
    }
    static func launchBackground() throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--background"]
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

extension JSONValue: Identifiable {
    public var id: String { self["id"].text }
}
extension JSONValue {
    var text: String { if case let .string(value) = self { return value }; return "" }
    var items: [JSONValue] { if case let .array(value) = self { return value }; return [] }
    var fields: [String: JSONValue] { if case let .object(value) = self { return value }; return [:] }
    var flag: Bool { if case let .bool(value) = self { return value }; return false }
    var integer: Int { intValue }
    var decimal: Double { if case let .number(value) = self { return value }; return 0 }
    var display: String {
        if case let .string(value) = self { return value }
        return String(data: (try? encoded()) ?? Data(), encoding: .utf8) ?? ""
    }
}

enum MioFormat {
    static let iso = ISO8601DateFormatter()
    static let fractional: ISO8601DateFormatter = { let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value }()
    static func timestamp(_ value: JSONValue) -> Date? { iso.date(from: value.text) ?? fractional.date(from: value.text) }
    static func date(_ value: JSONValue, locale: Locale = .current) -> String {
        let raw = value.text
        if let date = timestamp(value) { return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) }
        return raw.isEmpty ? "—" : String(raw.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
    static func color(_ value: String) -> Color {
        switch value { case "green": return .green; case "purple": return .purple; case "orange": return .orange; case "pink": return .pink; case "teal": return .teal; default: return .blue }
    }
    static func short(_ value: String, max: Int = 120) -> String { String(value.replacingOccurrences(of: "\n", with: " ").prefix(max)) }
    static func status(_ value: String) -> String {
        switch value { case "socket_written": return "Передано адаптеру"; case "stdout_written": return "Записано в канал MCP"; case "socket_write_failed", "stdout_write_failed": return "Ошибка выдачи ответа"; case "frame_too_large": return "Ответ превышает размер канала"; default: break }
        switch value { case "unverified": return "Не проверено"; case "confirmed": return "Подтверждено"; case "hypothesis": return "Предположение"; case "obsolete": return "Устарело"; case "completed", "success": return "Завершено"; case "failed", "error": return "Ошибка"; case "interrupted": return "Прервано"; case "in_progress": return "Выполняется"; case "open": return "Соединение открыто"; case "closed": return "Соединение завершено"; default: return value.isEmpty ? "Знание" : value }
    }

}

struct MioPreferences: Codable {
    var interfaceLanguage = "system"
    var selectedSpace = ""
    var selectedNote = ""
    var cloudFolder = ""
    var historySources: [HistorySource] = []
    var historyWorkspaces: [HistoryWorkspace] = []
    var ignoredHistorySources: [String] = []
    var drafts: [String: NoteDraft] = [:]
    struct HistorySource: Codable, Identifiable { var id: String; var title: String; var spaceID: String }
    struct HistoryWorkspace: Codable, Identifiable { var id: String; var path: String; var spaceID: String; var startedAt: Date }
    struct NoteDraft: Codable { var title: String; var body: String; var revision: String; var status: String }
    init() {}
    enum CodingKeys: String, CodingKey { case interfaceLanguage, selectedSpace, selectedNote, cloudFolder, historySources, historyWorkspaces, ignoredHistorySources, drafts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interfaceLanguage = (try? c.decodeIfPresent(String.self, forKey: .interfaceLanguage)) ?? "system"
        selectedSpace = try c.decodeIfPresent(String.self, forKey: .selectedSpace) ?? ""
        selectedNote = try c.decodeIfPresent(String.self, forKey: .selectedNote) ?? ""
        cloudFolder = try c.decodeIfPresent(String.self, forKey: .cloudFolder) ?? ""
        historySources = try c.decodeIfPresent([HistorySource].self, forKey: .historySources) ?? []
        historyWorkspaces = try c.decodeIfPresent([HistoryWorkspace].self, forKey: .historyWorkspaces) ?? []
        ignoredHistorySources = try c.decodeIfPresent([String].self, forKey: .ignoredHistorySources) ?? []
        drafts = try c.decodeIfPresent([String: NoteDraft].self, forKey: .drafts) ?? [:]
    }
    static func load() -> MioPreferences {
        let url = MioPaths.directory.appendingPathComponent("preferences.json")
        return (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? .init()
    }
    func save() {
        let url = MioPaths.directory.appendingPathComponent("preferences.json")
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension Notification.Name { static let mioMemoryChanged = Notification.Name("MioMemoryChanged") }

struct EmptyMemoryView: View {
    var symbol: String; var title: String; var detail: String
    var action: String? = nil; var onAction: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
            if let action, let onAction { Button(action, action: onAction).buttonStyle(.borderedProminent).padding(.top, 7) }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Pill: View {
    var text: String; var color: Color = .secondary
    var body: some View { Text(text).font(.caption).lineLimit(1).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.10), in: Capsule()) }
}
