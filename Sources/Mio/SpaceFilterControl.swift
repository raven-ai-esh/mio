import SwiftUI

struct SpaceFilterControl: View {
    @EnvironmentObject var model: AppModel
    var selectedSpaceIDs: Set<String>
    var accessibilityPrefix: String
    var setSelected: (String,Bool) -> Void
    var reset: () -> Void
    @State private var presented = false
    private var title: String {
        if selectedSpaceIDs.isEmpty { return model.l("Пространства: все") }
        if selectedSpaceIDs.count == 1, let id = selectedSpaceIDs.first { return model.spaceName(id) }
        return model.l("Пространства: %@", String(describing: selectedSpaceIDs.count))
    }
    var body: some View {
        Button { presented.toggle() } label: {
            Label(title,systemImage:selectedSpaceIDs.isEmpty ? "line.3.horizontal.decrease.circle":"line.3.horizontal.decrease.circle.fill").lineLimit(1)
        }.frame(maxWidth:200).accessibilityLabel(model.l("Фильтр пространств: %@", String(describing: title))).accessibilityIdentifier(accessibilityPrefix)
            .popover(isPresented:$presented) {
                VStack(alignment:.leading,spacing:12) {
                    HStack { Text(model.l("Выделить пространства")).font(.headline); Spacer(); Button(model.l("Сбросить"),action:reset).disabled(selectedSpaceIDs.isEmpty).accessibilityIdentifier(accessibilityPrefix+".reset") }
                    Text(model.l("Выберите одно или несколько. Остальные записи остаются видимыми, но почти прозрачными.")).font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment:.leading,spacing:12) {
                            ForEach(model.spaces) { space in
                                Toggle(isOn:Binding(get:{selectedSpaceIDs.contains(space.id)},set:{setSelected(space.id,$0)})) {
                                    HStack { Circle().fill(MioFormat.color(space["color"].text)).frame(width:8,height:8); Text(space["name"].text); Spacer(); Text("\(model.allNotes.filter{$0["space_id"].text==space.id}.count)").foregroundStyle(.secondary) }
                                }.toggleStyle(.checkbox).accessibilityIdentifier(accessibilityPrefix+"."+space.id)
                            }
                        }.padding(.vertical,5)
                    }.frame(maxHeight:280)
                }.padding(16).frame(width:340)
            }
    }
}
