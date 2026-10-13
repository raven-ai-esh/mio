import SwiftUI
import MioCore

struct SearchModelStatus: View {
    @EnvironmentObject var model: AppModel
    private var status: JSONValue { model.indexingStatus }
    private var state: String { status["model_state"].text }
    private var label: String {
        switch state { case "ready": return model.l("EmbeddingGemma 2 · на этом Mac"); case "checking": return model.l("Проверка локальной модели…"); case "downloading": return model.l("Загрузка локальной модели…"); case "error": return model.l("Не удалось загрузить модель"); default: return model.l("Семантическая модель не загружена") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label(label, systemImage: state == "ready" ? "checkmark.circle" : "cpu").font(.callout); Spacer()
                if ["missing", "error"].contains(state) { Button(state == "error" ? model.l("Повторить загрузку") : model.l("Загрузить · 514 МБ")) { Task { await model.downloadSearchModel() } }.accessibilityIdentifier("model.download") }
                if state == "downloading" { Button(model.l("Отменить")) { model.cancelModelDownload() }.accessibilityIdentifier("model.cancelDownload") }
            }
            if state == "downloading" { ProgressView(value: status["download_progress"].decimal) }
            if state != "ready" { Text(model.l("Поиск по словам и распознанному тексту доступен без модели. После загрузки модель обрабатывает данные локально.")).font(.caption).foregroundStyle(.secondary) }
            if !status["model_error"].text.isEmpty && state == "error" { Text(status["model_error"].text).font(.caption).foregroundStyle(.orange) }
            if !status["current_title"].text.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(model.l("Индексация: %@", String(describing: status["current_title"].text))).lineLimit(1); Spacer(); Text(status["total_fragments"].integer>0 ? "\(status["completed_fragments"].integer)/\(status["total_fragments"].integer)":model.l("извлечение текста")).monospacedDigit() }.font(.caption)
            }
            HStack {
                let index = status["index"]
                Text(model.l("Семантика: %@ источников · только текст: %@ · в очереди: %@", String(describing: index["ready"].integer), String(describing: index["lexical"].integer), String(describing: index["pending"].integer + index["indexing"].integer))).font(.caption).foregroundStyle(.secondary)
                if index["error"].integer > 0 { Button(model.l("Повторить ошибки (%@)", String(describing: index["error"].integer))) { Task { await model.retryIndexing() } }.controlSize(.small).accessibilityIdentifier("index.retry") }
            }
            ForEach(status["index"]["errors"].items,id:\.display) { item in Text("\(item["title"].text): \(item["error"].text)").font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }.task { await model.refreshIndexing() }
    }
}
