import SwiftUI
import AppKit
import Foundation
import MioCore
import MioBridge

struct AgentConnectionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = "Codex"
    @State private var space = ""
    @State private var config = ""
    @State private var token = ""
    @State private var profileID = ""
    @State private var creating = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) { Text(model.l("Codex и агенты")).font(.largeTitle.weight(.semibold)); Text(model.l("Подключение к разрешённому пространству памяти")).font(.title3).foregroundStyle(.secondary) }
                GroupBox {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(model.l("Новое подключение")).font(.headline)
                        TextField(model.l("Название агента"), text: $name).textFieldStyle(.roundedBorder)
                        Picker(model.l("Пространство"), selection: $space) { ForEach(model.spaces) { Text($0["name"].text).tag($0.id) } }
                        Text(model.l("Профиль разрешает чтение и запись в выбранном пространстве и доступ через его явные подключения. Данные других пространств не открываются.")).font(.callout).foregroundStyle(.secondary)
                        Button(creating ? model.l("Создание…") : model.l("Создать подключение")) { Task { await create() } }.buttonStyle(.borderedProminent).disabled(space.isEmpty || name.isEmpty || creating).accessibilityIdentifier("agent.create")
                    }.padding(12)
                }
                if !config.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 15) {
                            Text(model.l("Подключить к Codex")).font(.headline)
                            Text(model.l("Токен показан один раз. Сохраните конфигурацию или установите её в Codex. Агент сможет автоматически читать и записывать память в пределах этого профиля.")).font(.callout).foregroundStyle(.secondary)
                            Text(config).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            HStack { Button(model.l("Скопировать конфигурацию"), systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config, forType: .string); model.notice = "Конфигурация скопирована" }; Button(model.l("Установить в Codex"), systemImage: "terminal") { Task { await install() } }.buttonStyle(.borderedProminent) }
                        }.padding(12)
                    }
                }
                if !model.profiles.isEmpty {
                    Text(model.l("Профили подключения")).font(.title3.weight(.semibold))
                    ForEach(model.profiles) { profile in
                        HStack(spacing: 14) {
                            Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) { Text(profile["name"].text).font(.headline); Text(model.spaceName(profile["space_id"].text)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if profile["revoked"].flag { Pill(text: model.l("Отозван"), color: .secondary) }
                            else { Button(model.l("Отозвать доступ"), role: .destructive) { Task { do { _ = try await model.execute("profile.revoke", ["profile_id": .string(profile.id)]); await model.refresh(); model.notice = "Доступ отозван" } catch { model.failure = error.localizedDescription } } } }
                        }.padding(16).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !model.connections.isEmpty {
                    Text(model.l("Связанные пространства")).font(.title3.weight(.semibold))
                    ForEach(model.connections) { connection in
                        HStack { Text(model.spaceName(connection["from_space_id"].text)); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(model.spaceName(connection["to_space_id"].text)); Spacer(); Pill(text: connection["access"].text == "write" ? model.l("Чтение и запись") : model.l("Чтение"), color: .blue); Button { Task { do { _ = try await model.execute("connection.delete", ["connection_id": .string(connection.id)]); await model.refresh() } catch { model.failure = error.localizedDescription } } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel(model.l("Отключить пространство")) }.padding(12)
                    }
                }
                Button(model.l("Связать пространства"), systemImage: "link") { model.showConnectionSheet = true }.disabled(model.spaces.count < 2)
            }.padding(34).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { if space.isEmpty { space = model.selectedSpace.isEmpty ? model.spaces.first?.id ?? "" : model.selectedSpace } }
    }
    private func create() async {
        creating = true; defer { creating = false }
        do {
            let result = try await model.execute("profile.create", ["name": .string(name), "space_id": .string(space)])
            token = result["token"].text
            profileID = result["id"].text.isEmpty ? result["profile_id"].text : result["id"].text
            let dataDirectory = ProcessInfo.processInfo.environment["MIO_DATA_DIRECTORY"] != nil ? MioPaths.directory : nil
            config = try CodexConnectionConfig(profileID: profileID, token: token, appExecutable: MioPaths.executable, dataDirectory: dataDirectory).snippet()
            await model.refresh()
        } catch { model.failure = error.localizedDescription }
    }
    private func install() async {
        guard let codex = CodexExecutable.discover(), !token.isEmpty else { model.failure = "Codex или токен подключения недоступен"; return }
        do {
            let currentToken = token; let currentProfile = profileID
            let appExecutable = MioPaths.executable
            let dataDirectory = ProcessInfo.processInfo.environment["MIO_DATA_DIRECTORY"] != nil ? MioPaths.directory : nil
            let backups = MioPaths.directory.appendingPathComponent("ConnectionBackups", isDirectory: true)
            let serverName = try await Task.detached { try CodexMCPInstaller.install(executable: codex, profileID: currentProfile, token: currentToken, appExecutable: appExecutable, dataDirectory: dataDirectory, backupDirectory: backups) }.value
            model.notice = "Подключение \(serverName) установлено. Оно появится в новых сессиях Codex."
        } catch { model.failure = error.localizedDescription }
    }
}

struct CloudView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Image(systemName: "icloud").font(.system(size: 40, weight: .light)).foregroundStyle(.blue)
                Text(model.l("Синхронизация iCloud")).font(.largeTitle.weight(.semibold))
                Text(model.l("Mio сохраняет отдельные записи памяти в выбранной папке iCloud Drive. Локальная база и индексы остаются на этом Mac.")).font(.title3).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text("iCloud Drive").font(.headline); Spacer(); Pill(text: stateLabel, color: model.cloudStatus["state"].text == "error" ? .orange : .blue) }
                        Text(model.preferences.cloudFolder.isEmpty ? model.l("Папка ещё не подключена") : model.preferences.cloudFolder).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack { Button(model.preferences.cloudFolder.isEmpty ? model.l("Подключить папку iCloud…") : model.l("Выбрать папку…"), systemImage: "folder") { Task { await model.chooseCloudFolder() } }; if !model.preferences.cloudFolder.isEmpty { Button(model.l("Синхронизировать"), systemImage: "arrow.trianglehead.2.clockwise") { Task { await model.synchronizeCloud() } }.buttonStyle(.borderedProminent); Button(model.l("Отключить")) { model.disconnectCloud() } } }
                        let error = model.cloudStatus["error"].text.isEmpty ? model.cloudStatus["message"].text : model.cloudStatus["error"].text
                        if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                        HStack(spacing: 24) { metric(model.l("В очереди"), model.cloudStatus["pending_records"].integer); metric(model.l("Загружено за проход"), model.cloudStatus["uploaded_records"].integer); metric(model.l("Получено за проход"), model.cloudStatus["downloaded_records"].integer) }
                    }.padding(15)
                }
                Text(model.l("Статус «загружено» подтверждается macOS для конкретной записи. Получение этих изменений другим устройством проверяется на том устройстве.")).font(.callout).foregroundStyle(.secondary)
                Divider()
                Text(model.l("Перенос памяти")).font(.title2.weight(.semibold))
                Text(model.l("Полный архив сохраняет знания, версии, историю и вложения. Markdown подходит для работы с заметками в Obsidian.")).foregroundStyle(.secondary)
                HStack { Button(model.l("Экспортировать архив…")) { Task { await model.chooseArchiveExport() } }; Button(model.l("Импортировать архив…")) { Task { await model.chooseImport() } } }
                HStack { Button(model.l("Экспортировать Markdown…")) { Task { await model.chooseArchiveExport(markdown: true) } }; Button(model.l("Импортировать Obsidian…")) { Task { await model.chooseImport(markdown: true) } } }
            }.padding(36).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var stateLabel: String {
        if model.preferences.cloudFolder.isEmpty { return model.l("Не подключено") }
        switch model.cloudStatus["state"].text { case "connected": return model.l("Подключено · данных пока нет"); case "uploaded", "synced": return model.l("Загружено в iCloud"); case "pending": return model.l("Ожидает загрузки"); case "error", "blocked": return model.l("Требует внимания"); default: return model.l("Проверка состояния") }
    }
    private func metric(_ title: String, _ count: Int) -> some View { VStack(alignment: .leading, spacing: 4) { Text("\(count)").font(.title2.weight(.medium)); Text(title).font(.caption).foregroundStyle(.secondary) } }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section(model.l("Приложение")) {
                Picker(model.l("Interface language"), selection: Binding(get: { model.interfaceLanguage }, set: { model.setInterfaceLanguage($0) })) {
                    Text(model.l("System language")).tag(MioLanguage.system)
                    Text("English").tag(MioLanguage.english)
                    Text("Русский").tag(MioLanguage.russian)
                }.accessibilityIdentifier("settings.language")
                Text(model.l("Applies immediately. Notes keep their original language.")).font(.caption).foregroundStyle(.secondary)
            }
            Section("Mio") {
                LabeledContent(model.l("Версия"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.1")
                LabeledContent(model.l("Хранилище"), value: model.l("Локальная SQLite"))
                Text(MioPaths.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(model.l("Показать папку данных")) { NSWorkspace.shared.open(MioPaths.directory) }
            }
            Section(model.l("Локальный поиск")) { SearchModelStatus() }
            Section(model.l("История MCP")) {
                Text(model.l("Mio записывает начало и окончание обращений агента, их исход и связанные изменения памяти."))
                Button(model.l("Показать журнал")) { model.tab = "history" }
            }
            Section(model.l("Приложение")) {
                Text(model.l("Закрытие окна сохраняет обслуживание агента. Команда «Выйти из Mio» завершает процесс; следующий запрос адаптера запускает его снова.")).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(16)
            .onAppear { updateWindowTitle() }
            .onChange(of:model.preferences.interfaceLanguage) { _,_ in updateWindowTitle() }
    }
    private func updateWindowTitle() {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?.title = "Mio — " + model.l("Settings")
    }
}
