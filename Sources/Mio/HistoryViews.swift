import SwiftUI
import MioCore
import MioBridge

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(model.l("История MCP")).font(.title2.weight(.semibold)); Text(model.l("Обращения агентов к памяти: от начала до завершения")).font(.callout).foregroundStyle(.secondary) }; Spacer(); Button(model.l("Обновить"), systemImage: "arrow.clockwise") { Task { await model.refresh() } } }.padding(24)
            Divider()
            if model.visibleSessions.isEmpty { EmptyMemoryView(symbol: "clock.arrow.circlepath", title: model.l("Обращений пока нет"), detail: model.l("Подключите агента: его запросы к Mio, результаты и изменения памяти появятся здесь."), action: model.l("Подключить агента"), onAction: { model.tab = "agents" }) }
            else {
                HStack(spacing: 0) {
                    List(model.visibleSessions) { session in
                        Button { model.selectedSession = session.id } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(model.sessionName(session)).font(.headline).lineLimit(2)
                                HStack { Text(model.status(session["session_state"].text)); Text(model.l("· %@ событий", String(describing: session["event_count"].integer))) }.font(.caption).foregroundStyle(.secondary)
                                Text(model.date(session["updated_at"])).font(.caption2).foregroundStyle(.tertiary)
                            }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).listRowBackground(session.id == model.selectedSession ? Color.accentColor.opacity(0.10) : .clear)
                    }.listStyle(.plain).frame(width: 300)
                    Divider()
                    if model.selectedSession.isEmpty { EmptyMemoryView(symbol: "text.bubble", title: model.l("Выберите соединение"), detail: model.l("Просмотрите запросы, ответы, длительность и подтверждения операций.")) }
                    else { SessionDetail(sessionID: model.selectedSession).id(model.selectedSession) }
                }
            }
        }
    }
}

struct SessionDetail: View {
    @EnvironmentObject var model: AppModel
    var sessionID: String
    @State private var session: JSONValue = .null
    @State private var events: [JSONValue] = []
    @State private var nextOffset: Int? = nil
    @State private var loading = false
    @State private var query = ""
    @State private var purge = false
    private var metadata: JSONValue { model.sessions.first { $0.id == sessionID } ?? .null }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) { Text(model.sessionName(session)).font(.title2.weight(.semibold)); Spacer(); if session["session_state"].text == "closed" || session["session_state"].text == "interrupted" { Menu { Button(model.l("Очистить журнал соединения"), role: .destructive) { purge = true } } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30) } }
                HStack { Pill(text: model.spaceName(session["space_id"].text), color: .blue); Text(model.l("%@ событий", String(describing: session["event_count"].integer))).font(.caption).foregroundStyle(.secondary) }
                Button(model.l("Показать шаги на графе"),systemImage:"point.3.connected.trianglepath.dotted") { Task { await model.graph.openSession(sessionID,using:model) } }.accessibilityIdentifier("history.showGraph")
                HStack { Pill(text: model.status(session["session_state"].text)); Text(model.l("Начало %@", String(describing: model.date(session["opened_at"])))).font(.caption).foregroundStyle(.secondary) }
                if session["closed_at"] != .null { Text(model.l("Окончание %@", String(describing: model.date(session["closed_at"])))).font(.caption).foregroundStyle(.secondary) }
                if session["session_state"].text == "interrupted" { Text(model.l("Обычное завершение соединения не наблюдалось.")).font(.caption).foregroundStyle(.orange) }
                TextField(model.l("Найти среди загруженных событий"), text: $query).textFieldStyle(.roundedBorder)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(events.filter { query.isEmpty || $0["text"].text.localizedCaseInsensitiveContains(query) }) { event in EventCard(event: event) }
                    if let nextOffset { Button(model.l("Загрузить следующие события")) { Task { await load(offset: nextOffset) } }.disabled(loading) }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                }.padding(24)
            }
        }.task(id: sessionID + metadata["updated_at"].text + metadata["session_state"].text + metadata["event_count"].display) { await load(offset: 0) }
            .confirmationDialog(model.l("Очистить журнал этого соединения? Если заметка явно использует событие как источник, связанное содержимое тоже будет очищено."), isPresented: $purge) {
                Button(model.l("Удалить историю"), role: .destructive) { Task { await model.purgeSession(sessionID) } }
                Button(model.l("Отмена"), role: .cancel) {}
            }
    }
    private func load(offset: Int) async {
        loading = true; defer { loading = false }
        do { let result = try await model.execute("read", ["kind": .string("session"), "id": .string(sessionID), "offset": .number(Double(offset)), "limit": .number(100)]); session = result; if offset == 0 { events = result["events"].items } else { events += result["events"].items }; nextOffset = result["next_offset"] == .null ? nil : result["next_offset"].integer }
        catch { model.failure = error.localizedDescription }
    }
}

struct EventCard: View {
    @EnvironmentObject var model: AppModel
    var event: JSONValue
    @State private var expanded = false
    @State private var evidence: JSONValue?
    private var role: String { event["role"].text }
    private var tool: String { switch event["method"].text { case "note.create": return "capture"; case "note.update": return "revise"; case "link.create": return "link"; default: return event["method"].text } }
    private var label: String { event["phase"].text.isEmpty ? (role == "user" ? model.l("Пользователь") : role == "assistant" ? model.l("Агент") : event["tool_name"].text.isEmpty ? event["kind"].text : event["tool_name"].text) : "\(event["phase"].text == "start" ? model.l("Начало") : event["phase"].text == "delivery" ? model.l("Выдача ответа") : model.l("Завершение")) · \(tool)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: role == "user" ? "person" : role == "assistant" ? "sparkle" : "terminal").foregroundStyle(role == "user" ? .blue : .secondary); Text(label).font(.callout.weight(.semibold)); Spacer(); if !event["outcome"].text.isEmpty { Pill(text: event["phase"].text == "start" ? model.l("Принят") : model.status(event["outcome"].text), color: ["failed", "error", "interrupted"].contains(event["outcome"].text) ? .orange : .secondary) }; Text(model.date(event["timestamp"])).font(.caption).foregroundStyle(.tertiary) }
            if !event["phase"].text.isEmpty {
                if !event["request"]["query"].text.isEmpty { Text(event["request"]["query"].text).textSelection(.enabled) }
                if event["duration_ms"] != .null { Text(String(format: model.l("%.1f мс"), event["duration_ms"].decimal)).font(.caption).foregroundStyle(.secondary) }
                if event["replayed"].flag { Text(model.l("Повторный запрос · использовано прежнее подтверждение")).font(.caption).foregroundStyle(.secondary) }
                if !event["delivery_state"].text.isEmpty { Text(model.status(event["delivery_state"].text)).font(.caption).foregroundStyle(event["delivery_state"].text.contains("failed") || event["delivery_state"].text == "frame_too_large" ? .orange : .secondary) }
                if event["phase"].text == "end" && event["receipt"]["status"].text == "local_committed" { Label(model.l("Изменение подтверждено локально"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                ForEach(event["result_refs"].items) { ref in
                    if !ref["from_note_id"].text.isEmpty || !ref["to_note_id"].text.isEmpty {
                        HStack {
                            Button(model.l("Из заметки")) { Task { await open(.object(["id": ref["from_note_id"]])) } }
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Button(model.l("К заметке")) { Task { await open(.object(["id": ref["to_note_id"]])) } }
                        }.font(.caption).buttonStyle(.plain)
                    } else if ref["kind"].text == "space" {
                        Label(model.l("ID пространства: %@", String(describing: ref.id)),systemImage:"square.grid.2x2").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Button { Task { await open(ref) } } label: { Label(String(ref.id.prefix(32)), systemImage: "arrow.up.right.square") }.font(.caption).buttonStyle(.plain)
                    }
                }
                DisclosureGroup(model.l("Данные обращения"), isExpanded: $expanded) { Text(event.display).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Text(expanded ? event["text"].text : String(event["text"].text.prefix(1800))).font(role == "tool" ? .system(size: 12, design: .monospaced) : .system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if event["text"].text.count > 1800 { Button(expanded ? model.l("Свернуть") : model.l("Показать целиком")) { expanded.toggle() }.font(.caption) }
            }
            Text(event["source_id"].text).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
        }.padding(16).background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12)).sheet(item: $evidence) { EvidenceSheet(value: $0) }
    }
    private func open(_ ref: JSONValue) async {
        let id = ref["revision_id"].text.isEmpty ? ref.id : ref["revision_id"].text
        do { evidence = try await model.execute("read", ["kind": .string(id.hasPrefix("session-") ? "session" : "source"), "id": .string(id)]) }
        catch { model.failure = error.localizedDescription }
    }
}

struct EvidenceSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var model: AppModel
    var value: JSONValue
    @State private var pagePreview: JSONValue?
    @State private var previewLoading = false
    @State private var previewError = ""
    @State private var alternate:JSONValue?
    private var display: JSONValue { pagePreview ?? value }
    private var samePage:Bool { value["locator"]["page"].integer==0 || display["locator"]["page"]==value["locator"]["page"] }
    private var content: String {
        if !samePage { return "" }
        if !value["text"].text.isEmpty { return value["text"].text }
        if !value["body"].text.isEmpty { return value["body"].text }
        if value["kind"].text == "url" { return value["url"].text }
        if ["file","fragment"].contains(value["kind"].text) { return "" }
        return value.display
    }
    private var kindLabel: String {
        switch value["kind"].text { case "note": return model.l("Заметка"); case "revision": return model.l("Версия заметки"); case "file": return model.l("Исходный файл"); case "fragment": return value["locator"]["text_method"].text == "ocr" ? model.l("Распознанный фрагмент") : model.l("Точный фрагмент источника"); case "url": return model.l("Ссылка · содержимое не загружалось"); default: return value["kind"].text }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(model.l("Исходное свидетельство")).font(.title2.weight(.semibold)); Spacer(); Button(model.l("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("\(kindLabel) · \(value["role"].text) · \(model.date(value["timestamp"]))").font(.caption).foregroundStyle(.secondary)
            if !value["title"].text.isEmpty { Text(value["title"].text).font(.headline) }
            if !value["supporting_sources"].items.isEmpty {
                HStack { Text(model.l("Ещё в этом источнике:")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(value["supporting_sources"].items.enumerated()),id:\.offset) { index,item in
                        Button(item["locator"]["page"].integer>0 ? model.l("Страница %@", String(describing: item["locator"]["page"].integer)):model.l("Фрагмент %@", String(describing: index+2))) { Task { do { alternate=try await model.execute("read",["kind":.string("source"),"id":item["source_id"]]) } catch { previewError=error.localizedDescription } } }
                    }
                }
            }
            HStack {
                if value["locator"]["page"].integer > 0 { Text(model.l("Страница %@", String(describing: display["locator"]["page"].integer))).font(.callout) }
                if display["page_count"].integer > 1 {
                    Button(model.l("Предыдущая")) { loadPage(display["locator"]["page"].integer-2) }.disabled(display["locator"]["page"].integer<=1 || previewLoading)
                    Text(model.l("из %@", String(describing: display["page_count"].integer))).font(.caption)
                    Button(model.l("Следующая")) { loadPage(display["locator"]["page"].integer) }.disabled(display["locator"]["page"].integer>=display["page_count"].integer || previewLoading).accessibilityIdentifier("source.nextPage")
                } else if !value["file_id"].text.isEmpty && value["media"] == .null { Button(model.l("Показать исходное изображение")) { loadPage(max(0,value["locator"]["page"].integer-1)) }.disabled(previewLoading).accessibilityIdentifier("source.showPage") }
                Spacer()
                if !value["note_id"].text.isEmpty { Button(model.l("Открыть заметку")) { model.selectNote(value["note_id"].text); dismiss() } }
            }
            if !previewError.isEmpty { Text(previewError).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if previewLoading { ProgressView(model.l("Открытие источника…")) }
                    if let bytes=Data(base64Encoded:display["media"]["data"].text),let image=NSImage(data:bytes) {
                        Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:.infinity).overlay {
                            if samePage,value["locator"]["bounds"].items.count==4 {
                                GeometryReader { geometry in
                                    let box=value["locator"]["bounds"].items.map(\.decimal)
                                    Rectangle().stroke(Color.accentColor,lineWidth:2).frame(width:geometry.size.width*box[2],height:geometry.size.height*box[3]).position(x:geometry.size.width*(box[0]+box[2]/2),y:geometry.size.height*(1-box[1]-box[3]/2))
                                }.allowsHitTesting(false)
                            }
                        }.accessibilityLabel(model.l("Изображение исходной страницы"))
                    }
                    if !content.isEmpty { Text(content).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            let citation=samePage ? value:display
            if !citation["revision_id"].text.isEmpty { Text(model.l("Версия: %@", String(describing: citation["revision_id"].text))).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            Text(citation["source_id"].text.isEmpty ? citation.id : citation["source_id"].text).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }.padding(26).frame(width: 780, height: 680)
        .sheet(item:$alternate){EvidenceSheet(value:$0)}
        .onChange(of:model.snapshot["notes"]) { _,notes in
            guard !value["note_id"].text.isEmpty else { return }
            let owner=notes.items.first{$0.id==value["note_id"].text}
            if owner==nil || owner?["deleted"].flag==true || owner?["status"].text=="purged" { dismiss() }
        }
    }
    private func loadPage(_ offset: Int) {
        previewLoading=true;previewError=""
        Task { do { pagePreview=try await model.execute("read",["kind":.string("source"),"id":value["file_id"],"offset":.number(Double(offset))]) } catch { previewError=error.localizedDescription };previewLoading=false }
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) { Text(model.l("Журнал изменений")).font(.title2.weight(.semibold)); Text(model.l("Локальные действия и подтверждения сохранения")).foregroundStyle(.secondary) }.padding(24)
            Divider()
            if model.snapshot["audit"].items.isEmpty { EmptyMemoryView(symbol: "waveform.path", title: model.l("Журнал пока пуст"), detail: model.l("Здесь появятся обращения к памяти, изменения и подтверждения записи.")) }
            else {
                List(model.snapshot["audit"].items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "arrow.down.left.circle").foregroundStyle(.blue).font(.title3)
                        VStack(alignment: .leading, spacing: 7) { Text(item["method"].text.isEmpty ? item["action"].text : item["method"].text).font(.headline); Text(item["actor"].text).font(.caption).foregroundStyle(.secondary); Text(item["receipt"].display).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(2) }
                        Spacer(); Text(model.date(item["timestamp"])).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)
                }.listStyle(.inset)
            }
        }
    }
}
