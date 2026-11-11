import AppKit
import SwiftUI

struct DailyReviewSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var saved = DailyReviewConfiguration()
    @State private var draft = DailyReviewConfiguration()
    @State private var time = "00:00"
    @State private var last: DailyReviewRun?
    @State private var now = Date()
    @State private var saving = false
    @State private var error = ""
    @State private var confirmation = false
    @State private var pending: DailyReviewConfiguration?

    private var storage: DailyReviewStorage { DailyReviewStorage(directory: MioPaths.directory) }

    var body: some View {
        Section(model.l("Ежедневный аудит Mio")) {
            Toggle(model.l("Запускать аудит и улучшения"), isOn: Binding(get: { saved.enabled }, set: changeEnabled))
                .accessibilityIdentifier("dailyReview.enabled")
                .disabled(saving)
            LabeledContent(model.l("Время запуска на Mac")) {
                TextField("00:00", text: $time)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .frame(width: 64)
                    .accessibilityIdentifier("dailyReview.time")
            }.disabled(saving)
            pathField(model.l("Харнесс"), text: $draft.executable, identifier: "dailyReview.executable", directory: false)
            pathField(model.l("Папка проекта"), text: $draft.workspace, identifier: "dailyReview.workspace", directory: true)
            TextField(model.l("Аргументы, по одному на строку"), text: $draft.arguments, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("dailyReview.arguments")
                .disabled(saving)
            Text(model.l("Используйте пакетный режим харнесса. Задание передаётся через stdin."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.l("Сохранить параметры аудита")) {
                    prepare { apply($0, enable: saved.enabled, confirmed: false) }
                }
                .accessibilityIdentifier("dailyReview.save")
                .disabled(saving)
                if saving { ProgressView().controlSize(.small) }
            }
            if let next {
                LabeledContent(model.l("Следующий запуск"), value: formatted(next))
                    .accessibilityIdentifier("dailyReview.next")
            }
            if let last {
                LabeledContent(model.l("Последний запуск"), value: formatted(last.startedAt) + " · " + stateLabel(last.state))
                    .accessibilityIdentifier("dailyReview.last")
                if let error = last.error {
                    Text(model.l(error)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(model.l("Открыть результаты аудита")) {
                    NSWorkspace.shared.open(storage.directory(for: last.day))
                }.accessibilityIdentifier("dailyReview.openResults")
            }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("dailyReview.error")
            }
        }
        .alert(model.l("Включить ежедневный аудит?"), isPresented: $confirmation, presenting: pending) { configuration in
            Button(model.l("Включить аудит")) { apply(configuration, enable: true, confirmed: true) }
                .accessibilityIdentifier("dailyReview.confirm")
            Button(model.l("Отмена"), role: .cancel) { pending = nil }
        } message: { configuration in
            Text(model.l("Каждый день в %@ по времени Mac харнесс %@ получит сводку MCP за сутки, затем сможет править проект в %@ и запускать тесты. Это разрешение действует для запланированных запусков, пока аудит включён.",
                         displayTime(configuration), configuration.executable, configuration.workspace))
        }
        .task {
            load()
            while !Task.isCancelled {
                last = storage.lastRun()
                now = Date()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { break }
            }
        }
    }

    private func pathField(_ title: String, text: Binding<String>, identifier: String, directory: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: text).labelsHidden().accessibilityIdentifier(identifier)
                Button(model.l("Выбрать…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.allowsMultipleSelection = false
                    panel.prompt = model.l("Выбрать")
                    if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
                }.accessibilityIdentifier(identifier + ".choose")
            }
        }.disabled(saving)
    }

    private var next: Date? {
        guard saved.enabled, let enabledSince = saved.enabledSince else { return nil }
        let schedule = DailyReviewSchedule(saved)
        if let due = schedule.due(at: now, enabledSince: enabledSince), !storage.claimed(due.day) { return due.end }
        return schedule.next(after: now, claimed: storage.claimed)
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(.dateTime.day().month().hour().minute().locale(model.locale))
    }

    private func displayTime(_ configuration: DailyReviewConfiguration) -> String {
        String(format: "%02d:%02d", configuration.hour, configuration.minute)
    }

    private func load() {
        do {
            saved = try storage.loadConfiguration()
            draft = saved
            time = displayTime(saved)
        } catch {
            self.error = model.l("Не удалось прочитать параметры аудита.")
        }
    }

    private func stateLabel(_ state: DailyReviewRun.State) -> String {
        switch state {
        case .analyzing: return model.l("Анализ")
        case .working: return model.l("Правки и тесты")
        case .succeeded: return model.l("Завершено")
        case .failed: return model.l("Ошибка")
        case .interrupted: return model.l("Прервано")
        }
    }

    private func prepare(_ action: (DailyReviewConfiguration) throws -> Void) {
        do {
            let input = time.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = input.count == 4 && !input.contains(":")
                ? [input.prefix(2), input.suffix(2)]
                : input.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
                throw DailyReviewError.invalidSchedule
            }
            var configuration = draft
            configuration.hour = hour
            configuration.minute = minute
            try configuration.validateSchedule()
            error = ""
            try action(configuration)
        } catch {
            self.error = model.l(error.localizedDescription)
        }
    }

    private func changeEnabled(_ enable: Bool) {
        if !enable {
            apply(saved, enable: false, confirmed: false)
            return
        }
        prepare { configuration in
            _ = try configuration.command()
            pending = configuration
            confirmation = true
        }
    }

    private func apply(_ configuration: DailyReviewConfiguration, enable: Bool, confirmed: Bool) {
        saving = true
        error = ""
        pending = nil
        let agent = DailyReviewLaunchAgent(storage: storage, appExecutable: MioPaths.executable)
        Task { @MainActor in
            defer { saving = false }
            do {
                saved = try await Task.detached(priority: .utility) {
                    try agent.save(configuration, enable: enable, confirmed: confirmed)
                }.value
                draft = saved
                time = displayTime(saved)
                now = Date()
                last = storage.lastRun()
            } catch {
                saved = (try? storage.loadConfiguration()) ?? saved
                self.error = model.l(error.localizedDescription)
            }
        }
    }
}
