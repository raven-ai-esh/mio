import SwiftUI
import UniformTypeIdentifiers
import MioCore

struct MioNoteDrag: Codable {
    static let typeID="app.mio.note-selection"
    static let contentType=UTType(exportedAs:typeID,conformingTo:.data)
    var sessionID: String
    var spaces: [String:String]
}

extension AppModel {
    var spaceTree: MioSpaceTree { MioSpaceTree(spaces:spaces) }
    var spaceEntries: [MioSpaceTree.Entry] { spaceTree.entries }
    func expandedSpaces(_ ids: Set<String>) -> Set<String> { ids.reduce(into:Set<String>()) { $0.formUnion(spaceTree.subtreeIDs(of:$1)) } }
    func spacePath(_ id: String) -> String { spaceTree.path(to:id).map{$0["name"].text}.joined(separator:" / ") }
    func notesSelectionChanged(_ ids: Set<String>) {
        selectedNotes=ids
        if ids.count == 1,let id=ids.first { selectNote(id) }
        else if !selectedNote.isEmpty { selectedNote="";preferences.selectedNote="";preferences.save() }
    }
    func actionNoteIDs(for row: String) -> Set<String> { selectedNotes.contains(row) ? selectedNotes:[row] }
    func saveSpaceDetails(id: String, name: String, description: String, color: String, parent: String) async -> Bool {
        guard !busy else { return false }
        busy=true;defer { busy=false }
        do {
            var params: [String:JSONValue] = ["name":.string(name),"description":.string(description),"color":.string(color),"parent_id":parent.isEmpty ? .null:.string(parent)]
            if !id.isEmpty { params["space_id"] = .string(id) }
            let result=try await execute(id.isEmpty ? "space.create":"space.update",params)
            await refresh()
            if id.isEmpty { selectSpace(result.id);tab="notes" }
            notice="Пространство сохранено";return true
        } catch { failure=error.localizedDescription;return false }
    }
    func setSpaceParent(_ id: String, parent: String) async {
        do { _=try await execute("space.update",["space_id":.string(id),"parent_id":parent.isEmpty ? .null:.string(parent)]);await refresh();notice="Пространство сохранено" }
        catch { failure=error.localizedDescription }
    }
    func bulkNotes(_ action: String, ids: Set<String>, destination: String="", status: String="", expectedSpaces: [String:String]?=nil) async {
        guard !ids.isEmpty,!busy else { return }
        busy=true;defer { busy=false }
        let previous=Dictionary(uniqueKeysWithValues:allNotes.filter{ids.contains($0.id)}.map{($0.id,$0["revision_id"].text)})
        do {
            var params: [String:JSONValue] = ["action":.string(action),"note_ids":.array(ids.sorted().map(JSONValue.string))]
            if action == "move" { params["space_id"] = .string(destination) }
            if action == "status" { params["status"] = .string(status) }
            if let expectedSpaces { params["expected_spaces"] = .object(expectedSpaces.mapValues(JSONValue.string)) }
            let result=try await execute("notes.bulk",params)
            await refresh()
            if action == "status" {
                for id in ids {
                    if var draft=preferences.drafts[id],draft.revision == previous[id],let current=allNotes.first(where:{$0.id == id}) { draft.status=status;draft.revision=current["revision_id"].text;preferences.drafts[id]=draft }
                }
                preferences.save()
            }
            notice="Обработано заметок: \(result["changed_count"].integer)"
        } catch { failure=error.localizedDescription;await refresh() }
    }
    func noteDragProvider(for id: String) -> NSItemProvider {
        let ids=actionNoteIDs(for:id)
        let values=Dictionary(uniqueKeysWithValues:notesInLiveSpaces.filter{ids.contains($0.id)}.map{($0.id,$0["space_id"].text)})
        let data=(try? JSONEncoder().encode(MioNoteDrag(sessionID:dragSessionID,spaces:values))) ?? Data()
        let provider=NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier:MioNoteDrag.contentType.identifier,visibility:.ownProcess) { completion in completion(data,nil);return nil }
        return provider
    }
    func acceptNoteDrop(_ providers: [NSItemProvider], destination: String) -> Bool {
        guard !busy,let provider=providers.first(where:{$0.hasItemConformingToTypeIdentifier(MioNoteDrag.typeID)}) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier:MioNoteDrag.typeID) { data,error in
            Task { @MainActor in
                guard error == nil,let data,let drag=try? JSONDecoder().decode(MioNoteDrag.self,from:data),drag.sessionID == self.dragSessionID,!drag.spaces.isEmpty else { self.failure="Не удалось перенести заметки. Повторите перетаскивание из этого окна.";return }
                await self.bulkNotes("move",ids:Set(drag.spaces.keys),destination:destination,expectedSpaces:drag.spaces)
            }
        }
        return true
    }
}

struct NoteActionsMenu: View {
    @EnvironmentObject var model: AppModel
    let ids: Set<String>
    var body: some View {
        Menu {
            ForEach(model.spaceEntries) { entry in
                Button(model.spacePath(entry.id)) { Task { await model.bulkNotes("move",ids:ids,destination:entry.id) } }
            }
        } label: { Label(model.l("Переместить в…"),systemImage:"folder") }
        Menu {
            ForEach(["unverified","hypothesis","confirmed","obsolete"],id:\.self) { status in
                Button(model.status(status)) { Task { await model.bulkNotes("status",ids:ids,status:status) } }
            }
        } label: { Label(model.l("Изменить статус"),systemImage:"checkmark.seal") }
        Button(role:.destructive) { model.notesPendingDeletion=ids } label: { Label(model.l("Удалить выбранные заметки…"),systemImage:"trash") }
    }
}

struct NoteListRow: View {
    @EnvironmentObject var model: AppModel
    let note: JSONValue
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Text(note["title"].text.isEmpty ? model.l("Без названия"):note["title"].text).font(.headline).lineLimit(2);if model.preferences.drafts[note.id] != nil { Circle().fill(.orange).frame(width:5,height:5) } }
            Text(MioFormat.short(note["body_preview"].text,max:85)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack { Text(model.date(note["updated_at"]));Text("· \(model.spaceName(note["space_id"].text))") }.font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical,7).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).opacity(model.notesOpacity(note))
            .accessibilityIdentifier("notes.row.\(note.id)").accessibilityValue(model.notesOpacity(note)==1 ? model.l("Выделенная заметка"):model.l("Приглушённая заметка"))
            .contextMenu { NoteActionsMenu(ids:model.actionNoteIDs(for:note.id)) }
    }
}
