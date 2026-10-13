import SwiftUI
import Combine
import MioCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var compactInspector = false
    private var canInspect: Bool { model.tab == "graph" || (model.tab == "notes" && !model.selectedNote.isEmpty) }
    var body: some View {
        GeometryReader { geometry in
        NavigationSplitView {
            List {
                Section {
                    HStack(spacing: 11) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.title).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) { Text("Mio").font(.title2.weight(.semibold)); Text(model.l("Память и опыт")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 12)
                    navigation("notes", model.l("Заметки"), "square.stack.3d.up", count: model.notesInLiveSpaces.count)
                    navigation("graph", model.l("Граф памяти"), "point.3.connected.trianglepath.dotted")
                    navigation("search", model.l("Поиск"), "magnifyingglass")
                    navigation("history", model.l("История MCP"), "clock.arrow.circlepath", count: model.sessions.count)
                    navigation("activity", model.l("Журнал изменений"), "waveform.path")
                    navigation("deleted", model.l("Удалённые заметки"), "trash", count: model.deletedNotes.count)
                }
                Section(model.l("Пространства")) {
                    Button { model.selectSpace(""); if model.tab == "graph" { model.graph.showAllSpaces() } else if model.tab == "notes" { model.showAllNotesSpaces() } } label: { Label(model.l("Вся память"), systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                        .listRowBackground(model.selectedSpace.isEmpty ? Color.accentColor.opacity(0.10) : .clear)
                    ForEach(model.spaces) { space in
                        Button { let graphVisible = model.tab == "graph"; model.selectSpace(space.id); if graphVisible { model.graph.focusSpace(space.id) } else { model.focusNotesSpace(space.id); model.tab = "notes" } } label: {
                            HStack { Circle().fill(MioFormat.color(space["color"].text)).frame(width: 9, height: 9); Text(space["name"].text); Spacer(); Text("\(model.allNotes.filter { $0["space_id"].text == space.id }.count)").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("space.\(space.id)")
                            .listRowBackground(model.selectedSpace == space.id ? Color.accentColor.opacity(0.10) : .clear)
                    }
                    Button { model.showSpaceSheet = true } label: { Label(model.l("Новое пространство"), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("space.create")
                }
                Section(model.l("Подключения")) {
                    navigation("agents", model.l("Codex и агенты"), "terminal")
                    navigation("sync", model.l("Синхронизация"), "icloud")
                }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.loadingMemory { ProgressView(model.l("Открытие памяти…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { switch model.tab {
                case "notes": NotesWorkspace()
                case "graph": GraphView()
                case "search": SearchView()
                case "history": HistoryView()
                case "activity": ActivityView()
                case "agents": AgentConnectionsView()
                case "sync": CloudView()
                case "deleted": DeletedNotesView()
                default: NotesWorkspace()
                } }
                Divider()
                statusBar
            }
            if geometry.size.width >= 1250 && model.inspector && canInspect && model.tab == "notes" {
                Divider()
                NoteInspector().frame(width: 290).background(.bar)
            }
            }
            .navigationTitle(model.selectedSpace.isEmpty ? "Mio" : model.selectedSpaceValue["name"].text)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(model.l("Поиск по памяти"), text: $model.query).textFieldStyle(.plain).frame(width: 260).focused($searchFocused)
                            .accessibilityIdentifier("memory.search")
                            .onChange(of: model.query) { _, _ in model.tab = "search"; model.search() }
                    }.padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                ToolbarItemGroup {
                    Button { Task { await model.createNote() } } label: { Label(model.l("Новая заметка"), systemImage: "square.and.pencil") }.help(model.l("Новая заметка ⌘N")).accessibilityIdentifier("note.create")
                    Menu {
                        Button(model.l("Подключить пространство…")) { model.showConnectionSheet = true }
                        Divider()
                        Button(model.l("Импортировать Obsidian…")) { Task { await model.chooseImport(markdown: true) } }
                        Button(model.l("Добавить PDF или изображение…")) { Task { await model.chooseFileImport() } }
                        Button(model.l("Импортировать архив…")) { Task { await model.chooseImport() } }
                        Button(model.l("Экспортировать архив…")) { Task { await model.chooseArchiveExport() } }
                        Button(model.l("Экспортировать Markdown…")) { Task { await model.chooseArchiveExport(markdown: true) } }
                    } label: { Label(model.l("Действия с памятью"), systemImage: "ellipsis.circle") }.accessibilityIdentifier("memory.actions")
                    Button {
                        if model.tab == "graph" { model.graph.showInspector.toggle() }
                        else if geometry.size.width < 1250 { compactInspector = true }
                        else { model.inspector.toggle() }
                    } label: { Label(model.l("Инспектор"), systemImage: "sidebar.right") }.help(model.l("Источники и версии")).disabled(!canInspect)
                }
            }
        }
        .sheet(isPresented: $compactInspector) {
            VStack(spacing: 0) {
                HStack { Text(model.l("Источники и версии")).font(.headline); Spacer(); Button(model.l("Закрыть")) { compactInspector = false }.keyboardShortcut(.cancelAction) }.padding(16)
                Divider()
                NoteInspector()
            }.frame(width: 390, height: 600)
        }
        .sheet(isPresented: $model.showSpaceSheet) { SpaceSheet() }
        .sheet(isPresented: $model.showConnectionSheet) { ConnectionSheet() }
        .sheet(item: $model.recoveryDraft) { draft in
            VStack(alignment: .leading, spacing: 20) {
                Text(model.l("Черновик не сохранён")).font(.title2.weight(.semibold))
                Text(model.l("Источник прежней заметки очищен. Если этот текст содержит новую нужную информацию, сохраните его как отдельную заметку.")).foregroundStyle(.secondary)
                Text(draft.title).font(.headline)
                ScrollView { Text(draft.body).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 220)
                HStack { Spacer(); Button(model.l("Закрыть")) { model.recoveryDraft = nil }; Button(model.l("Сохранить как новую")) { Task { await model.recoverAsNewNote() } }.buttonStyle(.borderedProminent) }
            }.padding(28).frame(width: 570)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mioMemoryChanged).debounce(for: .milliseconds(100), scheduler: RunLoop.main)) { _ in Task { await model.refresh() } }
        .alert("Mio", isPresented: Binding(get: { !model.failure.isEmpty }, set: { if !$0 { model.failure = "" } })) { Button(model.l("Понятно")) { model.failure = "" } } message: { Text(model.l(model.failure)) }
        }
    }
    private func navigation(_ id: String, _ label: String, _ symbol: String, count: Int? = nil) -> some View {
        Button { model.tab = id } label: {
            HStack { Label(label, systemImage: symbol); Spacer(); if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.vertical, 3).accessibilityIdentifier("tab.\(id)")
            .listRowBackground(model.tab == id ? Color.accentColor.opacity(0.12) : .clear)
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.busy ? "arrow.trianglehead.2.clockwise" : "checkmark.circle").foregroundStyle(model.busy ? .orange : .secondary)
            Text(model.busy ? model.l("Обработка…") : model.notice.isEmpty ? model.l("Локальная память") : model.notice.rendered(using:model.localizer)).lineLimit(1)
            Spacer()
            let pending = model.snapshot["pending_sync"].integer
            if pending > 0 { Text(model.l("%@ изменений ожидают синхронизации", String(describing: pending))).foregroundStyle(.secondary) }
            Text(model.l("%@ пространств · %@ заметок", String(describing: model.spaces.count), String(describing: model.notesInLiveSpaces.count))).foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
    }
}

struct SpaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var color = "blue"
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(model.l("Новое пространство")).font(.title2.weight(.semibold))
            Text(model.l("Отдельная память проекта или агента. Позже можно подключить другие пространства.")).foregroundStyle(.secondary)
            TextField(model.l("Название"), text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("space.name")
            HStack(spacing: 12) {
                ForEach(["blue", "teal", "green", "purple", "orange", "pink"], id: \.self) { item in
                    Button { color = item } label: {
                        Circle().fill(MioFormat.color(item)).frame(width: 25, height: 25)
                            .overlay { if item == color { Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.weight(.bold)) } }
                    }.buttonStyle(.plain).accessibilityLabel(model.l("Цвет %@", String(describing: item)))
                }
            }
            HStack { Spacer(); Button(model.l("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction); Button(model.l("Создать")) { Task { await model.createSpace(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color); if model.failure.isEmpty { dismiss() } } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 420)
    }
}

struct ConnectionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var from = ""; @State private var to = ""; @State private var access = "read"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.l("Подключить пространство")).font(.title2.weight(.semibold))
            Text(model.l("Агенты исходного пространства получат выбранный доступ. Подключения следующего уровня автоматически не открываются.")).foregroundStyle(.secondary)
            Picker(model.l("Из пространства"), selection: $from) { ForEach(model.spaces) { Text($0["name"].text).tag($0.id) } }
            Picker(model.l("Подключить"), selection: $to) { ForEach(model.spaces.filter { $0.id != from }) { Text($0["name"].text).tag($0.id) } }
            Picker(model.l("Доступ"), selection: $access) { Text(model.l("Только чтение")).tag("read"); Text(model.l("Чтение и запись")).tag("write") }.pickerStyle(.segmented)
            HStack { Spacer(); Button(model.l("Отмена")) { dismiss() }; Button(model.l("Подключить")) { Task { do { _ = try await model.execute("connection.create", ["from_space_id": .string(from), "to_space_id": .string(to), "access": .string(access)]); await model.refresh(); dismiss() } catch { model.failure = error.localizedDescription } } }.buttonStyle(.borderedProminent).disabled(from.isEmpty || to.isEmpty || from == to) }
        }.padding(28).frame(width: 450).onAppear { from = model.selectedSpace.isEmpty ? model.spaces.first?.id ?? "" : model.selectedSpace; to = model.spaces.first { $0.id != from }?.id ?? "" }
    }
}

struct NotesWorkspace: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
        if model.spaces.isEmpty {
            EmptyMemoryView(symbol: "square.stack.3d.up", title: model.l("Память начинается с пространства"), detail: model.l("Создайте место для знаний и опыта своего агента."), action: model.l("Создать пространство"), onAction: { model.showSpaceSheet = true })
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(alignment:.leading,spacing:10) {
                        HStack { Text(model.l("Заметки")).font(.headline); Spacer(); Text("\(model.notesInLiveSpaces.count)").foregroundStyle(.secondary) }.accessibilityIdentifier("notes.counts")
                        SpaceFilterControl(selectedSpaceIDs:model.notesFocusedSpaceIDs,accessibilityPrefix:"notes.spaceFilter",setSelected:{model.setNotesSpaceSelected($0,selected:$1)},reset:model.showAllNotesSpaces)
                        if model.notesFilterActive { Text(model.l("%@ выделено · %@ приглушено", String(describing: model.emphasizedNoteCount), String(describing: model.notesInLiveSpaces.count-model.emphasizedNoteCount))).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("notes.filterCounts") }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                    Divider()
                    if model.notesInLiveSpaces.isEmpty { EmptyMemoryView(symbol: "doc.text", title: model.l("Заметок пока нет"), detail: model.l("Создайте заметку или импортируйте память."), action: model.l("Новая заметка"), onAction: { Task { await model.createNote() } }) }
                    else {
                        List(model.notesForDisplay) { note in
                            Button { model.selectNote(note.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text(note["title"].text.isEmpty ? model.l("Без названия") : note["title"].text).font(.headline).lineLimit(2); if model.preferences.drafts[note.id] != nil { Circle().fill(.orange).frame(width: 5, height: 5) } }
                                    Text(MioFormat.short(note["body_preview"].text, max: 85)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    HStack { Text(model.date(note["updated_at"])); Text("· \(model.spaceName(note["space_id"].text))") }.font(.caption2).foregroundStyle(.tertiary)
                                }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).opacity(model.notesOpacity(note))
                            }.buttonStyle(.plain).accessibilityIdentifier("notes.row.\(note.id)").accessibilityValue(model.notesOpacity(note)==1 ? model.l("Выделенная заметка"):model.l("Приглушённая заметка")).listRowBackground(note.id == model.selectedNote ? Color.accentColor.opacity(0.10*model.notesOpacity(note)) : .clear)
                                .contextMenu { Button(model.l("Удалить заметку"), role: .destructive) { Task { await model.deleteNote(note.id) } } }
                        }.listStyle(.plain)
                    }
                }.frame(width: 270)
                Divider()
                if model.selectedNote.isEmpty { EmptyMemoryView(symbol: "doc.text.magnifyingglass", title: model.l("Выберите заметку"), detail: model.l("Читайте, редактируйте и изучайте её источники и связи.")) }
                else if !model.selectedNoteValue.id.isEmpty { NoteEditor(note: model.selectedNoteValue).id(model.selectedNote) }
                else if model.noteLoading { ProgressView(model.l("Загрузка заметки…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { EmptyMemoryView(symbol: "exclamationmark.triangle", title: model.l("Не удалось открыть заметку"), detail: model.l(model.noteLoadFailure), action: model.l("Повторить"), onAction: { Task { await model.loadSelectedNote() } }) }
            }
        }
        }
        .onAppear { model.synchronizeNotesSpaces() }
        .onChange(of:model.selectedSpace) { _,_ in model.synchronizeNotesSpaces() }
        .onChange(of:model.snapshot["spaces"]) { _,_ in model.synchronizeNotesSpaces() }
    }
}

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var evidence: JSONValue?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(model.l("Поиск по памяти")).font(.title2.weight(.semibold)); Spacer(); Picker(model.l("Источники"), selection: $model.searchScope) { Text(model.l("Всё")).tag("all"); Text(model.l("Заметки")).tag("notes"); Text(model.l("Файлы")).tag("files"); Text(model.l("История MCP")).tag("history") }.pickerStyle(.segmented).frame(width: 420).onChange(of: model.searchScope) { _, _ in model.search() } }.padding(24)
            SearchModelStatus().padding(.horizontal, 24).padding(.bottom, 14)
            if !model.searchStatus["semantic_state"].text.isEmpty && !model.query.isEmpty {
                Text(searchModeLabel).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
                Text(model.l("Результаты — кандидаты. Откройте источник, чтобы проверить его содержание.")).font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.bottom,10)
            }
            Divider()
            if model.searchWorking { ProgressView(model.l("Поиск…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.query.isEmpty { EmptyMemoryView(symbol: "magnifyingglass", title: model.l("Что нужно вспомнить?"), detail: model.l("Ищите решения, факты и прошлый опыт через поле в верхней панели.")) }
            else if model.searchResults.isEmpty { EmptyMemoryView(symbol: "magnifyingglass", title: model.l("Совпадений пока нет"), detail: model.searchStatus["lexical_pending_sources"].integer>0 ? model.l("Часть файлов ещё обрабатывается. Результаты обновятся после индексации."):model.l("Попробуйте другие слова или выберите другое пространство.")) }
            else {
                List(Array(model.searchResults.enumerated()), id: \.offset) { _, item in
                    Button { open(item) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Image(systemName: item["kind"].text == "file" ? "doc.viewfinder" : item["kind"].text == "note" ? "doc.text" : "clock").foregroundStyle(.blue); Text(item["title"].text).font(.headline); Spacer(); Pill(text: item["kind"].text == "file" ? model.l("Файл") : item["kind"].text == "note" ? model.l("Заметка") : model.l("История")) }
                            if item["locator"]["page"].integer > 0 { Text(model.l("Страница %@ · %@", String(describing: item["locator"]["page"].integer), String(describing: item["modality"].text == "image" ? model.l("изображение") : item["locator"]["text_method"].text == "ocr" ? model.l("распознанный текст") : model.l("текст")))).font(.caption).foregroundStyle(.blue) }
                            Text(item["snippet"].text).font(.body).foregroundStyle(.secondary).lineLimit(5)
                            HStack { Text(model.spaceName(item["space_id"].text)); Text("·"); Text(model.date(item["timestamp"])); if !item["status"].text.isEmpty { Text("· \(model.status(item["status"].text))") } }.font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }
        }.sheet(item: $evidence) { EvidenceSheet(value: $0) }
    }
    private var searchModeLabel: String {
        let status=model.searchStatus
        if status["semantic_state"].text == "ready" { return model.l("Гибридный поиск · семантически проиндексировано %@ из %@ источников", String(describing: status["semantic_indexed_sources"].integer), String(describing: status["visible_sources"].integer)) }
        if status["semantic_state"].text == "history_lexical" { return model.l("Поиск по обращениям к Mio") }
        if status["semantic_state"].text == "error" { return model.l("Поиск по словам · ошибка локальной модели: %@", String(describing: status["semantic_error"].text)) }
        return model.l("Поиск по словам · семантический индекс ещё не готов")
    }
    private func open(_ item: JSONValue) {
        if !item["source_id"].text.isEmpty && item["source_id"].text.hasPrefix("source-") {
            Task { do { var source=try await model.execute("read", ["kind": .string("source"), "id": item["source_id"]]).fields;source["supporting_sources"] = item["supporting_sources"];evidence = .object(source) } catch { model.failure = error.localizedDescription } }; return
        }
        if item["kind"].text == "file" { model.selectNote(item["id"].text); return }
        if item["kind"].text == "note" { model.selectNote(item["id"].text); return }
        Task { do { evidence = try await model.execute("read", ["kind": .string("event"), "id": .string(item["id"].text)]) } catch { model.failure = error.localizedDescription } }
    }
}
