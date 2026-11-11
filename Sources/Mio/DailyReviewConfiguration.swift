import Darwin
import Foundation

struct DailyReviewConfiguration: Codable, Equatable, Sendable {
    var executable = ""
    var arguments = ""
    var workspace = ""
    var hour = 0
    var minute = 0
    var enabledSince: Date?
    var authorizationID: UUID?

    var enabled: Bool { enabledSince != nil && authorizationID != nil }

    func validateSchedule() throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw DailyReviewError.invalidSchedule
        }
    }

    func command() throws -> (executable: URL, arguments: [String], workspace: URL) {
        var isDirectory: ObjCBool = false
        guard executable.hasPrefix("/"), FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executable) else {
            throw DailyReviewError.invalidExecutable
        }
        guard workspace.hasPrefix("/"), FileManager.default.fileExists(atPath: workspace, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw DailyReviewError.invalidWorkspace }
        return (URL(fileURLWithPath: executable),
                arguments.split(whereSeparator: \.isNewline).map(String.init),
                URL(fileURLWithPath: workspace, isDirectory: true))
    }
}

enum DailyReviewError: LocalizedError {
    case invalidSchedule, invalidExecutable, invalidWorkspace, activationRequired
    case lockFailed, launchAgentFailed(String), missingAnalysis

    var errorDescription: String? {
        switch self {
        case .invalidSchedule: return "Choose a valid review time."
        case .invalidExecutable: return "Choose a runnable harness executable."
        case .invalidWorkspace: return "Choose an existing project folder."
        case .activationRequired: return "Confirm enabling the daily review."
        case .lockFailed: return "Could not lock the daily review state."
        case .launchAgentFailed(let detail): return "macOS could not update the background schedule. \(detail)"
        case .missingAnalysis: return "The harness exited without writing an analysis to stdout."
        }
    }
}

struct DailyReviewSchedule {
    let hour: Int
    let minute: Int
    let calendar: Calendar

    static func localCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    init(_ configuration: DailyReviewConfiguration, calendar: Calendar = localCalendar()) {
        hour = configuration.hour
        minute = configuration.minute
        self.calendar = calendar
    }

    func due(at now: Date, enabledSince: Date) -> DailyReviewWindow? {
        guard let today = occurrence(on: now) else { return nil }
        let day = today <= now ? now : calendar.date(byAdding: .day, value: -1, to: now)
        guard let day, let end = occurrence(on: day), end >= enabledSince,
              let previous = calendar.date(byAdding: .day, value: -1, to: day),
              let start = occurrence(on: previous), start < end else { return nil }
        return DailyReviewWindow(day: key(for: end), start: start, end: end, timeZone: calendar.timeZone.identifier)
    }

    func next(after now: Date, claimed: (String) -> Bool) -> Date? {
        guard let today = occurrence(on: now) else { return nil }
        if today > now, !claimed(key(for: today)) { return today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return occurrence(on: tomorrow)
    }

    private func occurrence(on date: Date) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let start = calendar.startOfDay(for: date)
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        guard let result = calendar.nextDate(after: start.addingTimeInterval(-1), matching: components,
                                            matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                            direction: .forward),
              calendar.isDate(result, inSameDayAs: date) else { return nil }
        return result
    }

    private func key(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct DailyReviewWindow: Equatable, Sendable {
    let day: String
    let start: Date
    let end: Date
    let timeZone: String
}

struct DailyReviewRun: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case analyzing, working, succeeded, failed, interrupted }
    let day: String
    let scheduledAt: Date
    let startedAt: Date
    var endedAt: Date?
    var state: State
    var error: String?
}

struct DailyReviewStorage: Sendable {
    let directory: URL

    private var root: URL { directory.appendingPathComponent("DailyReview", isDirectory: true) }
    private var configURL: URL { root.appendingPathComponent("configuration.json") }
    private var lastURL: URL { root.appendingPathComponent("last-run.json") }
    var runsURL: URL { root.appendingPathComponent("runs", isDirectory: true) }

    func loadConfiguration() throws -> DailyReviewConfiguration {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return DailyReviewConfiguration() }
        return try JSONDecoder().decode(DailyReviewConfiguration.self, from: Data(contentsOf: configURL))
    }

    func saveConfiguration(_ value: DailyReviewConfiguration) throws {
        try prepare()
        try JSONEncoder().encode(value).write(to: configURL, options: .atomic)
    }

    func lastRun() -> DailyReviewRun? {
        guard let data = try? Data(contentsOf: lastURL),
              var run = try? JSONDecoder().decode(DailyReviewRun.self, from: data) else { return nil }
        if [.analyzing, .working].contains(run.state),
           (try? withLock("run.lock", nonblocking: true, { true })) == true {
            run.state = .interrupted
        }
        return run
    }

    func directory(for day: String) -> URL { runsURL.appendingPathComponent(day, isDirectory: true) }

    func claimed(_ day: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: day).path)
    }

    func claim(_ day: String) throws -> URL {
        try prepare()
        try FileManager.default.createDirectory(at: runsURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = directory(for: day)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return target
    }

    func saveRun(_ run: DailyReviewRun) throws {
        let data = try JSONEncoder().encode(run)
        try data.write(to: directory(for: run.day).appendingPathComponent("status.json"), options: .atomic)
        try data.write(to: lastURL, options: .atomic)
    }

    func withLock<T>(_ name: String, nonblocking: Bool = false, _ work: () throws -> T) throws -> T? {
        try prepare()
        let descriptor = open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DailyReviewError.lockFailed }
        defer { close(descriptor) }
        let operation = LOCK_EX | (nonblocking ? LOCK_NB : 0)
        while flock(descriptor, operation) != 0 {
            if nonblocking && errno == EWOULDBLOCK { return nil }
            if errno != EINTR { throw DailyReviewError.lockFailed }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
