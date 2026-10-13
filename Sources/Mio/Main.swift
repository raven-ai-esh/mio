import AppKit
import SwiftUI
import MioCore
import MioBridge

@main enum MioEntrypoint {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--mcp") || args.contains("--rpc") {
            do {
                let runtime = MioPaths.runtime
                try runtime.prepare()
                let credential: BridgeCredential
                if args.contains("--mcp") {
                    guard let token = ProcessInfo.processInfo.environment["MIO_PROFILE_TOKEN"], !token.isEmpty else {
                        throw NSError(domain: "Mio", code: 401, userInfo: [NSLocalizedDescriptionKey: "MIO_PROFILE_TOKEN is required for MCP"])
                    }
                    credential = .agent(token)
                } else { credential = .owner(try runtime.ownerToken()) }
                let client = LocalBridgeClient(socketURL: runtime.socketURL, credential: credential, autoLaunch: { try MioPaths.launchBackground() })
                if args.contains("--mcp") { try MCPRunner.run(client: client) }
                else {
                    guard let index = args.firstIndex(of: "--rpc"), args.count > index + 1 else { throw NSError(domain: "Mio", code: 400, userInfo: [NSLocalizedDescriptionKey: "--rpc requires method and optional JSON parameters"]) }
                    let params = args.count > index + 2 ? try JSONValue.decode(Data(args[index + 2].utf8)).fields : [:]
                    let result = try client.call(args[index + 1], params: params)
                    FileHandle.standardOutput.write(try result.encoded()); FileHandle.standardOutput.write(Data([10]))
                }
            } catch {
                let result = JSONValue.object(["error": .string(error.localizedDescription)])
                FileHandle.standardError.write((try? result.encoded()) ?? Data()); FileHandle.standardError.write(Data([10])); exit(1)
            }
            return
        }
        MioApplication.main()
    }
}

final class MioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Per-process appearance override for isolated native acceptance runs.
        // Normal launches follow the user's system appearance.
        if let appearance = ProcessInfo.processInfo.environment["MIO_UI_APPEARANCE"] ?? (Bundle.main.bundleIdentifier == "app.mio.memory.acceptance" ? Bundle.main.object(forInfoDictionaryKey:"MioAcceptanceAppearance") as? String:nil) {
            if appearance == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            else if appearance == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        }
        if CommandLine.arguments.contains("--background") {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.windows.forEach { $0.orderOut(nil) } }
        } else { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

struct MioApplication: App {
    @NSApplicationDelegateAdaptor(MioAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Mio") { MainView().environmentObject(model).environment(\.locale,model.locale).frame(minWidth: 1000, minHeight: 650) }
            .defaultSize(width: 1320, height: 860)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(model.l("Новая заметка")) { Task { await model.createNote() } }.keyboardShortcut("n")
                    Button(model.l("Новое пространство")) { model.showSpaceSheet = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                }
                CommandGroup(after: .importExport) {
                    Button(model.l("Добавить PDF или изображение…")) { Task { await model.chooseFileImport() } }.keyboardShortcut("i")
                    Button(model.l("Импортировать память…")) { Task { await model.chooseImport() } }
                    Button(model.l("Импортировать Obsidian…")) { Task { await model.chooseImport(markdown: true) } }
                    Divider()
                    Button(model.l("Экспортировать архив…")) { Task { await model.chooseArchiveExport() } }
                    Button(model.l("Экспортировать Markdown…")) { Task { await model.chooseArchiveExport(markdown: true) } }
                }
            }
        Settings { SettingsView().environmentObject(model).environment(\.locale,model.locale).frame(width: 650, height: 560) }
    }
}
