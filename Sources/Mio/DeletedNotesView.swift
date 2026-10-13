import SwiftUI
import MioCore

struct DeletedNotesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) { Text(model.l("Удалённые заметки")).font(.title2.weight(.semibold)); Text(model.l("История мягко удалённых заметок позволяет восстановить их содержимое.")).foregroundStyle(.secondary) }.padding(24)
            Divider()
            if model.deletedNotes.isEmpty { EmptyMemoryView(symbol: "trash", title: model.l("Удалённых заметок нет"), detail: model.l("Здесь появятся заметки, убранные из актуальной памяти.")) }
            else {
                List(model.deletedNotes) { note in
                    HStack(spacing: 14) {
                        Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) { Text(note["title"].text).font(.headline); Text(model.spaceName(note["space_id"].text)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(model.l("Восстановить")) {
                            Task {
                                do { _ = try await model.execute("note.restore", ["note_id": .string(note.id), "revision_id": note["revision_id"]]); await model.refresh(); model.selectNote(note.id); model.notice = "Заметка восстановлена новой версией" }
                                catch { model.failure = error.localizedDescription }
                            }
                        }.buttonStyle(.bordered)
                    }.padding(.vertical, 12)
                }.listStyle(.inset)
            }
        }
    }
}
