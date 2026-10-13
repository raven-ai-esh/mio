import Foundation

/// Runtime CLI discovery for explicit configuration installation. No chat/source APIs.
public enum CodexExecutable {
    public static func discover() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in paths {
            let candidate = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // Finder-launched apps commonly receive a restricted PATH.
        for path in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
