import SwiftUI
import AppKit
import MioCore

enum MioSpacePalette {
    static let baseColors=["blue","teal","green","mint","cyan","indigo","purple","pink","red","orange","yellow","brown","gray"]
    static func isValid(_ color: String, original: String?) -> Bool {
        baseColors.contains(color) || MioSpaceRGB(hex:color) != nil || (!color.isEmpty && color==original)
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
    private var baseColors: [String] { MioSpacePalette.baseColors }
    private var validColor: Bool { MioSpacePalette.isValid(color,original:creating ? nil:space["color"].text) }
    private var customColor: Binding<Color> { Binding(get:{MioFormat.color(color)},set:{ value in
        guard let rgb=NSColor(value).usingColorSpace(.sRGB) else { return }
        color=MioSpaceRGB(red:rgb.redComponent,green:rgb.greenComponent,blue:rgb.blueComponent).hex
    }) }
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
                VStack(alignment:.leading,spacing:12) {
                    Text(model.l("Цвет")).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns:Array(repeating:GridItem(.fixed(28),spacing:8),count:7),alignment:.leading,spacing:10) {
                    ForEach(baseColors,id:\.self) { item in
                        Button { color=item } label: {
                            Circle().fill(MioFormat.color(item)).frame(width:25,height:25).overlay { if item == color { Image(systemName:"checkmark").foregroundStyle(item=="yellow" || item=="mint" ? .black:.white).font(.caption.weight(.bold)) } }
                        }.buttonStyle(.plain).accessibilityLabel(model.l("Цвет %@",item)).accessibilityIdentifier("space.color.\(item)")
                    }
                    }
                    HStack {
                        ColorPicker(model.l("Палитра…"),selection:customColor,supportsOpacity:false).accessibilityIdentifier("space.color.custom")
                        Spacer()
                        TextField("",text:Binding(get:{color.hasPrefix("#") ? color:""},set:{color=$0.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()}),prompt:Text("#RRGGBB")).labelsHidden().textFieldStyle(.roundedBorder).font(.system(.caption,design:.monospaced)).frame(width:110).accessibilityLabel(model.l("Цвет HEX")).accessibilityIdentifier("space.color.hex")
                    }
                    if !validColor { Text(model.l("Введите цвет в формате #RRGGBB.")).font(.caption).foregroundStyle(.red) }
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
                Button(model.l(creating ? "Создать":"Сохранить")) { Task { if await model.saveSpaceDetails(id:space.id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),description:details,color:color,parent:parent) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(model.busy || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !validColor).keyboardShortcut(.defaultAction).accessibilityIdentifier("space.save")
            }
        }.padding(24).frame(width:500).onAppear { name=space["name"].text;details=space["description"].text;color=space["color"].text.isEmpty ? "blue":space["color"].text;parent=space["parent_id"].text;nameFocused=true }
    }
}
