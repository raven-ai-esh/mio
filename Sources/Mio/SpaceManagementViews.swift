import SwiftUI
import UniformTypeIdentifiers
import MioCore

struct SpaceSidebarRow: View {
    @EnvironmentObject var model: AppModel
    let entry: MioSpaceTree.Entry
    @State private var dropTargeted=false
    private var space: JSONValue { entry.space }
    private var count: Int { let ids=model.spaceTree.subtreeIDs(of:entry.id);return model.allNotes.filter{ids.contains($0["space_id"].text)}.count }
    private var connected: Int { model.connections.filter{$0["from_space_id"].text == entry.id || $0["to_space_id"].text == entry.id}.count }
    var body: some View {
        Button {
            let graphVisible=model.tab == "graph";model.selectSpace(entry.id)
            if graphVisible { model.graph.focusSpace(entry.id) }
            else { model.focusNotesSpace(entry.id);model.tab="notes" }
        } label: {
            HStack(spacing:7) {
                if entry.depth>0 { Image(systemName:"arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary) }
                Circle().fill(MioFormat.color(space["color"].text)).frame(width:9,height:9)
                Text(space["name"].text).lineLimit(2)
                Spacer(minLength:2)
                if connected>0 { Image(systemName:"link").font(.caption2).foregroundStyle(.secondary).help(model.l("Подключений: %@",String(connected))) }
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }.padding(.leading,CGFloat(min(entry.depth,8))*12).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("space.\(entry.id)")
            .help(space["description"].text.isEmpty ? model.spacePath(entry.id):space["description"].text)
            .listRowBackground(dropTargeted ? Color.accentColor.opacity(0.25):model.selectedSpace == entry.id ? Color.accentColor.opacity(0.10):.clear)
            .contextMenu {
                Button(model.l("Изменить пространство…")) { model.editingSpace=space;model.showSpaceSheet=true }
                Button(model.l("Создать дочернее пространство…")) { model.editingSpace = .object(["parent_id":.string(entry.id)]);model.showSpaceSheet=true }
                Menu(model.l("Поместить в пространство")) {
                    Button(model.l("Без родительского пространства")) { Task { await model.setSpaceParent(entry.id,parent:"") } }
                    ForEach(model.spaceEntries.filter{!model.spaceTree.subtreeIDs(of:entry.id).contains($0.id)}) { parent in
                        Button(model.spacePath(parent.id)) { Task { await model.setSpaceParent(entry.id,parent:parent.id) } }
                    }
                }
                Divider()
                Button(model.l("Подключить пространство…")) { model.connectionSourceSpaceID=entry.id;model.showConnectionSheet=true }
            }
            .onDrop(of:[MioNoteDrag.contentType],isTargeted:$dropTargeted) { model.acceptNoteDrop($0,destination:entry.id) }
    }
}

struct SpaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var space: JSONValue = .null
    @State private var name=""
    @State private var details=""
    @State private var color="blue"
    @State private var parent=""
    @FocusState private var nameFocused: Bool
    private var creating: Bool { space.id.isEmpty }
    private var connections: [JSONValue] { model.connections.filter{$0["from_space_id"].text == space.id || $0["to_space_id"].text == space.id} }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text(model.l(creating ? "Новое пространство":"Изменить пространство")).font(.title2.weight(.semibold))
            Form {
                TextField(model.l("Название"),text:$name).textFieldStyle(.roundedBorder).focused($nameFocused).accessibilityIdentifier("space.name")
                VStack(alignment:.leading,spacing:6) {
                    Text(model.l("Описание")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text:$details).frame(height:65).padding(4).overlay(RoundedRectangle(cornerRadius:6).stroke(.quaternary)).accessibilityIdentifier("space.description")
                }
                Picker(model.l("Родительское пространство"),selection:$parent) {
                    Text(model.l("Без родительского пространства")).tag("")
                    ForEach(model.spaceEntries.filter{creating || !model.spaceTree.subtreeIDs(of:space.id).contains($0.id)}) { entry in Text(model.spacePath(entry.id)).tag(entry.id) }
                }.accessibilityIdentifier("space.parent")
                Text(model.l("Вложенность упорядочивает память и фильтры. Доступ агента задаётся подключениями отдельно.")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing:12) {
                    Text(model.l("Цвет")).font(.caption).foregroundStyle(.secondary)
                    ForEach(["blue","teal","green","purple","orange","pink"],id:\.self) { item in
                        Button { color=item } label: {
                            Circle().fill(MioFormat.color(item)).frame(width:25,height:25).overlay { if item == color { Image(systemName:"checkmark").foregroundStyle(.white).font(.caption.weight(.bold)) } }
                        }.buttonStyle(.plain).accessibilityLabel(model.l("Цвет %@",item)).accessibilityIdentifier("space.color.\(item)")
                    }
                }
            }.formStyle(.grouped)
            if !creating {
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(model.l("Подключения агента")).font(.headline);Spacer();Button(model.l("Добавить…")) { model.connectionSourceSpaceID=space.id;dismiss() } }
                    if connections.isEmpty { Text(model.l("Прямых подключений нет")).font(.caption).foregroundStyle(.secondary) }
                    else { ScrollView {
                        VStack(spacing:8) {
                            ForEach(connections) { connection in
                                HStack {
                                    Text("\(model.spaceName(connection["from_space_id"].text)) → \(model.spaceName(connection["to_space_id"].text))").lineLimit(2)
                                    Spacer()
                                    Text(model.l(connection["access"].text == "write" ? "Чтение и запись":"Только чтение")).font(.caption).foregroundStyle(.secondary)
                                    Button { Task { do { _=try await model.execute("connection.delete",["connection_id":.string(connection.id)]);await model.refresh() } catch { model.failure=error.localizedDescription } } } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).help(model.l("Убрать подключение"))
                                }.font(.caption)
                            }
                        }
                    }.frame(maxHeight:95) }
                }
            }
            HStack {
                Spacer();Button(model.l("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.l(creating ? "Создать":"Сохранить")) { Task { if await model.saveSpaceDetails(id:space.id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),description:details,color:color,parent:parent) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(model.busy || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction).accessibilityIdentifier("space.save")
            }
        }.padding(24).frame(width:500).onAppear { name=space["name"].text;details=space["description"].text;color=space["color"].text.isEmpty ? "blue":space["color"].text;parent=space["parent_id"].text;nameFocused=true }
    }
}
