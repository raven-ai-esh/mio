import SwiftUI
import MioCore

struct NoteEditor: View {
    @EnvironmentObject var model: AppModel
    var note: JSONValue
    @State private var title = ""
    @State private var text = ""
    @State private var revision = ""
    @State private var status = "hypothesis"
    @State private var preview = false
    @State private var loaded = false
    @State private var showDelete = false
    @State private var baselineTitle = ""
    @State private var baselineText = ""
    @State private var baselineStatus = "hypothesis"
    @State private var fileSource: JSONValue?
    private var dirty: Bool { title != baselineTitle || text != baselineText || status != baselineStatus }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Pill(text: model.spaceName(note["space_id"].text), color: MioFormat.color(model.spaces.first { $0.id == note["space_id"].text }?["color"].text ?? "blue"))
                if dirty { Pill(text: model.l("Черновик"), color: .orange) }
                Spacer()
                Picker(model.l("Вид заметки"), selection: $preview) { Image(systemName: "pencil").tag(false); Image(systemName: "doc.richtext").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 80).accessibilityLabel(model.l("Вид заметки"))
                Button { Task { if await model.saveNote(id: note.id, title: title, body: text, revision: revision, status: status) { revision = model.selectedNoteValue["revision_id"].text; baselineTitle = title; baselineText = text; baselineStatus = status } } } label: { Label(model.l("Сохранить"), systemImage: "checkmark") }.buttonStyle(.borderedProminent).disabled(!dirty || model.busy).keyboardShortcut("s").accessibilityIdentifier("note.save")
            }.padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 18)
            if note["has_conflict"].flag {
                HStack { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text(model.l("Есть конкурирующие версии. Выберите итоговую версию в инспекторе.")).font(.callout); Spacer() }.padding(12).background(.orange.opacity(0.08)).padding(.horizontal, 30)
            }
            TextField(model.l("Название заметки"), text: $title).textFieldStyle(.plain).font(.system(size: 30, weight: .semibold)).padding(.horizontal, 30).padding(.vertical, 12).accessibilityIdentifier("note.title")
            HStack {
                Picker(model.l("Статус знания"), selection: $status) {
                    Text(model.l("Не проверено")).tag("unverified")
                    Text(model.l("Предположение")).tag("hypothesis")
                    Text(model.l("Подтверждено")).tag("confirmed")
                    Text(model.l("Устарело")).tag("obsolete")
                    if !["unverified", "hypothesis", "confirmed", "obsolete"].contains(status) {
                        Text(model.status(status)).tag(status)
                    }
                }.labelsHidden().frame(width: 170)
                Text(model.date(note["updated_at"])).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu { Button(model.l("Удалить из актуальной памяти"), role: .destructive) { showDelete = true } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
            }.padding(.horizontal, 30).padding(.bottom, 18)
            Divider().padding(.horizontal, 30)
            if let fileID=note["file_ids"].items.first {
                HStack {
                    Label(model.l("Файл сохранён в памяти · текст ниже — ваши заметки к нему"), systemImage: "doc.viewfinder").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.l("Открыть файл")) { Task { do { fileSource = try await model.execute("read", ["kind": .string("source"), "id": fileID]) } catch { model.failure = error.localizedDescription } } }.accessibilityIdentifier("file.open")
                }.padding(.horizontal,30).padding(.vertical,12)
            }
            if preview {
                ScrollView { MarkdownPreview(text: text).padding(30).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                TextEditor(text: $text).font(.system(size: 15, design: .monospaced)).scrollContentBackground(.hidden).padding(.horizontal, 24).padding(.vertical, 20).accessibilityLabel(model.l("Текст заметки")).accessibilityIdentifier("note.body")
            }
            HStack { Text(model.l("Markdown · [[ссылки на заметки]]")); Spacer(); Text(model.l("%@ символов", String(describing: text.count))) }.font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 30).padding(.vertical, 12)
        }
        .onAppear { load() }
        .sheet(item: $fileSource) { EvidenceSheet(value: $0) }
        .onChange(of: title) { _, _ in stage() }
        .onChange(of: text) { _, _ in stage() }
        .onChange(of: status) { _, _ in stage() }
        .onChange(of: model.preferences.drafts[note.id]?.revision) { old,new in
            if let draft=model.preferences.drafts[note.id],old == revision,new == note["revision_id"].text,draft.title == title,draft.body == text {
                revision=draft.revision;status=draft.status;baselineStatus=note["status"].text
            }
        }
        .onChange(of: note["revision_id"].text) { _, _ in if !dirty { load() } }
        .confirmationDialog(model.l("Удалить заметку из актуальной памяти? История версий сохранится."), isPresented: $showDelete) { Button(model.l("Удалить заметку"), role: .destructive) { Task { await model.deleteNote(note.id) } }; Button(model.l("Отмена"), role: .cancel) {} }
    }
    private func load() {
        loaded = false
        baselineTitle = note["title"].text; baselineText = note["body"].text; baselineStatus = note["status"].text
        if let draft = model.preferences.drafts[note.id] { title = draft.title; text = draft.body; revision = draft.revision; status = draft.status }
        else { title = note["title"].text; text = note["body"].text; revision = note["revision_id"].text; status = note["status"].text.isEmpty ? "hypothesis" : note["status"].text }
        DispatchQueue.main.async { loaded = true }
    }
    private func stage() {
        guard loaded, dirty else { return }
        model.stageDraft(id: note.id, title: title, body: text, revision: revision, status: status)
    }
}

struct MarkdownPreview: View {
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") { Text(String(line.dropFirst(4))).font(.headline).padding(.top, 12) }
                else if line.hasPrefix("## ") { Text(String(line.dropFirst(3))).font(.title2.weight(.semibold)).padding(.top, 16) }
                else if line.hasPrefix("# ") { Text(String(line.dropFirst(2))).font(.title.weight(.semibold)).padding(.top, 16) }
                else if line.hasPrefix("- ") { HStack(alignment: .top, spacing: 9) { Text("•").foregroundStyle(.secondary); inline(String(line.dropFirst(2))) } }
                else if line.hasPrefix("```") { Divider().padding(.vertical, 5) }
                else if line.isEmpty { Spacer().frame(height: 5) }
                else { inline(line) }
            }
        }.font(.system(size: 15)).textSelection(.enabled)
    }
    private func inline(_ text: String) -> some View { Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)).frame(maxWidth: .infinity, alignment: .leading) }
}

struct NoteInspector: View {
    @EnvironmentObject var model: AppModel
    @State private var revisions: [JSONValue] = []
    @State private var showLink = false
    @State private var source: JSONValue?
    var note: JSONValue { model.selectedNoteValue }
    private var outgoing: [JSONValue] { model.links.filter { $0["from_note_id"].text == note.id } }
    private var incoming: [JSONValue] { model.links.filter { $0["to_note_id"].text == note.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text(model.l("О заметке")).font(.headline); Spacer(); Image(systemName: "info.circle").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.status(note["status"].text)).font(.callout)
                    Text(model.spaceName(note["space_id"].text)).foregroundStyle(.secondary)
                    Text(model.l("Обновлено %@", String(describing: model.date(note["updated_at"])))).font(.caption).foregroundStyle(.secondary)
                    Text(note.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(model.l("Связи")).font(.headline); Spacer(); Button { showLink = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel(model.l("Добавить связь")) }
                    if outgoing.isEmpty { Text(model.l("Связей пока нет")).foregroundStyle(.tertiary).font(.callout) }
                    ForEach(outgoing) { link in relation(link, target: link["to_note_id"].text) }
                    Text(model.l("Обратные ссылки")).font(.headline).padding(.top, 8)
                    if incoming.isEmpty { Text(model.l("Другие заметки пока не ссылаются сюда")).foregroundStyle(.tertiary).font(.callout) }
                    ForEach(incoming) { link in relation(link, target: link["from_note_id"].text) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.l("Источники")).font(.headline)
                    if note["source_ids"].items.isEmpty { Text(model.l("Источник не указан")).font(.callout).foregroundStyle(.tertiary) }
                    ForEach(note["source_ids"].items.map(\.text), id: \.self) { id in
                        Button { Task { do { source = try await model.execute("read", ["kind": .string("source"), "id": .string(id)]) } catch { model.failure = error.localizedDescription } } } label: { Label(String(id.prefix(24)), systemImage: "quote.bubble") }.buttonStyle(.plain).font(.caption)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.l("Версии · %@", String(describing: revisions.count))).font(.headline)
                    ForEach(revisions) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(model.date(item["timestamp"])).font(.caption); Spacer(); if item.id == note["revision_id"].text { Pill(text: model.l("Текущая"), color: .blue) } }
                            Text(item["title"].text).font(.callout).lineLimit(2)
                            Text(item["author"].text).font(.caption).foregroundStyle(.secondary)
                            Text(item.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
                            Button(model.l("Прочитать версию")) {
                                Task {
                                    do { source = try await model.execute("read", ["kind": .string("source"), "id": .string(item.id)]) }
                                    catch { model.failure = error.localizedDescription }
                                }
                            }.font(.caption).accessibilityIdentifier("revision.read.\(item.id)")
                            if note["has_conflict"].flag || item.id != note["revision_id"].text {
                                Button(note["has_conflict"].flag ? model.l("Использовать эту версию") : model.l("Восстановить")) { Task { do { _ = try await model.execute(note["has_conflict"].flag ? "note.resolve" : "note.restore", ["note_id": .string(note.id), "revision_id": .string(item.id)]); await model.refresh(); await loadVersions() } catch { model.failure = error.localizedDescription } } }.font(.caption)
                            }
                        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.padding(20)
        }.task(id: note.id + note["revision_id"].text + note["head_revision_ids"].display + note["has_conflict"].display) { await loadVersions() }
            .sheet(isPresented: $showLink) { NoteLinkSheet(note: note) }
            .sheet(item: $source) { EvidenceSheet(value: $0) }
    }
    private func relation(_ link: JSONValue, target: String) -> some View {
        Button { model.selectNote(target) } label: {
            HStack(alignment: .top) { Image(systemName: "arrow.up.right").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 3) { Text(model.allNotes.first { $0.id == target }?["title"].text ?? model.l("Удалённая заметка")).lineLimit(2); Text(link["kind"].text).font(.caption2).foregroundStyle(.tertiary) } }
        }.buttonStyle(.plain).font(.callout)
    }
    private func loadVersions() async { guard !note.id.isEmpty else { return }; do { revisions = try await model.execute("note.history", ["note_id": .string(note.id)])["revisions"].items.sorted { $0["timestamp"].text > $1["timestamp"].text } } catch { model.failure = error.localizedDescription } }
}

struct NoteLinkSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var note: JSONValue
    @State private var target = ""
    @State private var kind = "related"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.l("Связать заметки")).font(.title2.weight(.semibold))
            Text(note["title"].text).foregroundStyle(.secondary)
            Picker(model.l("Заметка"), selection: $target) { ForEach(model.allNotes.filter { $0.id != note.id }) { Text($0["title"].text).tag($0.id) } }
            Picker(model.l("Отношение"), selection: $kind) { Text(model.l("Связано")).tag("related"); Text(model.l("Подтверждает")).tag("supports"); Text(model.l("Уточняет")).tag("clarifies"); Text(model.l("Заменяет")).tag("supersedes") }
            HStack { Spacer(); Button(model.l("Отмена")) { dismiss() }; Button(model.l("Связать")) { Task { do { _ = try await model.execute("link.create", ["from_note_id": .string(note.id), "to_note_id": .string(target), "kind": .string(kind)]); await model.refresh(); dismiss() } catch { model.failure = error.localizedDescription } } }.buttonStyle(.borderedProminent).disabled(target.isEmpty) }
        }.padding(28).frame(width: 420).onAppear { target = model.allNotes.first { $0.id != note.id }?.id ?? "" }
    }
}
