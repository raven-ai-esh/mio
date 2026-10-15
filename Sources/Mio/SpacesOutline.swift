import AppKit
import SwiftUI
import MioCore

struct SpacesOutlineSection: View {
    @State private var height: CGFloat=64
    var body: some View {
        SpacesOutline(height:$height).frame(height:height)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
    }
}

/// A native outline owns both ends of the drag. A SwiftUI List row's drop
/// modifier does not receive AppKit's between-row insertion proposals.
struct SpacesOutline: NSViewRepresentable {
    @EnvironmentObject var model: AppModel
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(model:model,height:$height) }
    func makeNSView(context: Context) -> SpaceOutlineView {
        let view=SpaceOutlineView(),column=NSTableColumn(identifier:.init("space"))
        view.addTableColumn(column);view.outlineTableColumn=column;view.headerView=nil
        view.style = .sourceList;view.backgroundColor = .clear
        view.rowHeight=32;view.intercellSpacing = .zero;view.indentationPerLevel=12
        view.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        view.allowsMultipleSelection=false;view.allowsEmptySelection=true
        view.dataSource=context.coordinator;view.delegate=context.coordinator
        view.contextMenuForItem={ [weak coordinator=context.coordinator] item in coordinator?.menu(item) }
        view.setDraggingSourceOperationMask(.move,forLocal:true)
        view.setDraggingSourceOperationMask([],forLocal:false)
        view.registerForDraggedTypes([.init(MioSpaceDrag.typeID),.init(MioNoteDrag.typeID)])
        view.setAccessibilityIdentifier("spaces.outline")
        return view
    }
    func updateNSView(_ view: SpaceOutlineView, context: Context) {
        context.coordinator.model=model;context.coordinator.height=$height
        context.coordinator.update(view)
    }

    final class Item: NSObject {
        enum Kind { case all, space, create }
        let id: String
        let kind: Kind
        init(_ id: String, _ kind: Kind) { self.id=id;self.kind=kind }
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var model: AppModel
        var height: Binding<CGFloat>
        private var items=[String:Item]()
        private let allItem=Item("$all",.all)
        private let createItem=Item("$create",.create)
        private var roots=[Item]()
        private var spaces=[String:JSONValue]()
        private var tree=MioSpaceTree(spaces:[])
        private var counts=[String:Int]()
        private var connectionCounts=[String:Int]()
        private var signature: JSONValue = .null
        private var updating=false
        private weak var outline: NSOutlineView?
        init(model: AppModel,height: Binding<CGFloat>) { self.model=model;self.height=height }
        func update(_ view: NSOutlineView) {
            outline=view
            let entries=model.spaces
            var direct=[String:Int](),connections=[String:Int]()
            for note in model.allNotes { direct[note["space_id"].text,default:0]+=1 }
            for edge in model.connections { connections[edge["from_space_id"].text,default:0]+=1;connections[edge["to_space_id"].text,default:0]+=1 }
            let next: JSONValue = .object(["spaces":.array(entries),"counts":.object(direct.mapValues{.number(Double($0))}),"connections":.object(connections.mapValues{.number(Double($0))}),"language":.string(model.interfaceLanguage.resolved())])
            updating=true;defer { updating=false }
            if next != signature {
                signature=next;tree=MioSpaceTree(spaces:entries)
                spaces=Dictionary(uniqueKeysWithValues:entries.map{($0.id,$0)})
                let valid=Set(spaces.keys)
                items=items.filter{valid.contains($0.key)}
                for id in spaces.keys where items[id]==nil { items[id]=Item(id,.space) }
                roots=[allItem]+tree.siblingIDs(parent:nil).compactMap{items[$0]}+[createItem]
                counts=spaces.keys.reduce(into:[:]) { values,id in values[id]=tree.subtreeIDs(of:id).reduce(0){$0+(direct[$1] ?? 0)} }
                connectionCounts=connections
                view.reloadData();view.expandItem(nil,expandChildren:true);publishHeight(view)
            }
            let selected=(model.selectedSpace.isEmpty ? allItem:items[model.selectedSpace]).map{view.row(forItem:$0)} ?? -1
            if selected>=0,view.selectedRow != selected { view.selectRowIndexes(IndexSet(integer:selected),byExtendingSelection:false) }
            else if selected<0 { view.deselectAll(nil) }
        }
        private func publishHeight(_ view: NSOutlineView) {
            let next=CGFloat(view.numberOfRows)*32+2
            guard height.wrappedValue != next else { return }
            let binding=height
            DispatchQueue.main.async { binding.wrappedValue=next }
        }
        private func children(_ item: Any?) -> [Item] {
            guard let item=item as? Item else { return roots }
            return item.kind == .space ? tree.childIDs(of:item.id).compactMap{items[$0]}:[]
        }
        func outlineView(_ outlineView: NSOutlineView,numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
        func outlineView(_ outlineView: NSOutlineView,child index: Int,ofItem item: Any?) -> Any { children(item)[index] }
        func outlineView(_ outlineView: NSOutlineView,isItemExpandable item: Any) -> Bool { !children(item).isEmpty }
        func outlineView(_ outlineView: NSOutlineView,viewFor tableColumn: NSTableColumn?,item: Any) -> NSView? {
            guard let item=item as? Item else { return nil }
            let identifier=NSUserInterfaceItemIdentifier("space.cell")
            let cell=(outlineView.makeView(withIdentifier:identifier,owner:self) as? SpaceOutlineCell) ?? SpaceOutlineCell()
            cell.identifier=identifier
            let value=spaces[item.id] ?? .null
            let name=item.kind == .all ? model.l("Вся память"):item.kind == .create ? model.l("Новое пространство"):value["name"].text
            cell.label.stringValue=name
            cell.count.stringValue=item.kind == .space ? String(counts[item.id] ?? 0):""
            cell.link.isHidden=item.kind != .space || connectionCounts[item.id,default:0]==0
            cell.icon.image=NSImage(systemSymbolName:item.kind == .space ? "circle.fill":item.kind == .all ? "square.grid.2x2":"plus",accessibilityDescription:nil)
            cell.icon.symbolConfiguration = .init(pointSize:item.kind == .space ? 9:15,weight:.regular)
            cell.icon.contentTintColor=item.kind == .space ? NSColor(MioFormat.color(value["color"].text)):.secondaryLabelColor
            cell.label.textColor=item.kind == .create ? .secondaryLabelColor:.labelColor
            cell.toolTip=item.kind == .all ? model.l("Перетащите сюда пространство, чтобы вернуть его на верхний уровень."):item.kind == .space ? (value["description"].text.isEmpty ? model.spacePath(item.id):value["description"].text):nil
            cell.setAccessibilityIdentifier("space.\(item.id)")
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating,let view=notification.object as? NSOutlineView,let item=view.item(atRow:view.selectedRow) as? Item else { return }
            switch item.kind {
            case .all:
                model.selectSpace("");if model.tab == "graph" { model.graph.showAllSpaces() } else if model.tab == "notes" { model.showAllNotesSpaces() }
            case .create: model.editingSpace = .null;model.showSpaceSheet=true
            case .space:
                let graphVisible=model.tab == "graph";model.selectSpace(item.id)
                if graphVisible { model.graph.focusSpace(item.id) } else { model.focusNotesSpace(item.id);model.tab="notes" }
            }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { if let outline { publishHeight(outline) } }
        func outlineViewItemDidCollapse(_ notification: Notification) { if let outline { publishHeight(outline) } }
        func outlineView(_ outlineView: NSOutlineView,pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard !model.busy,let item=item as? Item,item.kind == .space else { return nil }
            MioSpaceDragLog.phase("native source writer")
            let drag=model.makeSpaceDrag(item.id),pasteboard=NSPasteboardItem()
            guard let data=try? JSONEncoder().encode(drag) else { return nil }
            pasteboard.setData(data,forType:.init(MioSpaceDrag.typeID));return pasteboard
        }
        func outlineView(_ outlineView: NSOutlineView,draggingSession session: NSDraggingSession,willBeginAt screenPoint: NSPoint,forItems draggedItems: [Any]) { MioSpaceDragLog.phase("native session began") }
        func outlineView(_ outlineView: NSOutlineView,draggingSession session: NSDraggingSession,endedAt screenPoint: NSPoint,operation: NSDragOperation) { MioSpaceDragLog.phase(operation == [] ? "native session cancelled":"native session finished") }
        private struct Destination { let parent: String?;let before: String? }
        private func destination(_ item: Any?,_ index: Int) -> Destination? {
            if let item=item as? Item {
                if item.kind == .all { return .init(parent:nil,before:nil) }
                guard item.kind == .space else { return nil }
                if index==NSOutlineViewDropOnItemIndex { return .init(parent:item.id,before:nil) }
                let siblings=tree.childIDs(of:item.id)
                guard (0...siblings.count).contains(index) else { return nil }
                return .init(parent:item.id,before:index<siblings.count ? siblings[index]:nil)
            }
            // Root offsets also include All memory and New space.
            guard index>=1,index<roots.count else { return nil }
            let item=roots[index]
            return .init(parent:nil,before:item.kind == .space ? item.id:nil)
        }
        private func spaceDrag(_ info: NSDraggingInfo) -> MioSpaceDrag? {
            guard let data=info.draggingPasteboard.data(forType:.init(MioSpaceDrag.typeID)),let drag=try? JSONDecoder().decode(MioSpaceDrag.self,from:data),drag.sessionID==model.dragSessionID,spaces[drag.spaceID] != nil else { return nil }
            return drag
        }
        private func noteDrag(_ info: NSDraggingInfo) -> MioNoteDrag? {
            guard let data=info.draggingPasteboard.data(forType:.init(MioNoteDrag.typeID)),let drag=try? JSONDecoder().decode(MioNoteDrag.self,from:data),drag.sessionID==model.dragSessionID,!drag.spaces.isEmpty else { return nil };return drag
        }
        func outlineView(_ outlineView: NSOutlineView,validateDrop info: NSDraggingInfo,proposedItem item: Any?,proposedChildIndex index: Int) -> NSDragOperation {
            guard !model.busy else { return [] }
            MioSpaceDragLog.phase("native destination validation")
            if let drag=spaceDrag(info),let destination=destination(item,index) {
                guard destination.parent.map({!tree.subtreeIDs(of:drag.spaceID).contains($0)}) ?? true,destination.before != drag.spaceID else { return [] }
                return .move
            }
            if noteDrag(info) != nil,let item=item as? Item,item.kind == .space {
                outlineView.setDropItem(item,dropChildIndex:NSOutlineViewDropOnItemIndex);return .move
            }
            return []
        }
        func outlineView(_ outlineView: NSOutlineView,acceptDrop info: NSDraggingInfo,item: Any?,childIndex index: Int) -> Bool {
            guard !model.busy else { return false }
            MioSpaceDragLog.phase("native drop accepted")
            if let drag=spaceDrag(info),let destination=destination(item,index) {
                Task { await model.dropSpace(drag,target:destination.before ?? destination.parent,placement:destination.before==nil ? .inside:.before) };return true
            }
            if let drag=noteDrag(info),let item=item as? Item,item.kind == .space {
                Task { await model.bulkNotes("move",ids:Set(drag.spaces.keys),destination:item.id,expectedSpaces:drag.spaces) };return true
            }
            return false
        }
        func menu(_ item: Item) -> NSMenu? {
            guard item.kind == .space,let space=spaces[item.id] else { return nil }
            let menu=NSMenu()
            func add(_ label: String,to menu: NSMenu,action: @escaping ()->Void) {
                let entry=NSMenuItem(title:label,action:#selector(invokeMenu(_:)),keyEquivalent:"");entry.target=self;entry.representedObject=MenuAction(action);menu.addItem(entry)
            }
            add(model.l("Изменить пространство…"),to:menu) { self.model.editingSpace=space;self.model.showSpaceSheet=true }
            add(model.l("Создать дочернее пространство…"),to:menu) { self.model.editingSpace = .object(["parent_id":.string(item.id)]);self.model.showSpaceSheet=true }
            let parent=NSMenuItem(title:model.l("Поместить в пространство"),action:nil,keyEquivalent:""),parents=NSMenu();parent.submenu=parents;menu.addItem(parent)
            add(model.l("Без родительского пространства"),to:parents) { Task { await self.model.setSpaceParent(item.id,parent:"") } }
            for entry in tree.entries where !tree.subtreeIDs(of:item.id).contains(entry.id) { add(model.spacePath(entry.id),to:parents) { Task { await self.model.setSpaceParent(item.id,parent:entry.id) } } }
            menu.addItem(.separator())
            add(model.l("Подключить пространство…"),to:menu) { self.model.connectionSourceSpaceID=item.id;self.model.showConnectionSheet=true }
            return menu
        }
        private final class MenuAction: NSObject { let run: ()->Void;init(_ run: @escaping ()->Void) { self.run=run } }
        @objc private func invokeMenu(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.run() }
    }
}

final class SpaceOutlineView: NSOutlineView {
    var contextMenuForItem: ((SpacesOutline.Item)->NSMenu?)?
    override func layout() {
        super.layout()
        if let column=tableColumns.first,abs(column.width-bounds.width)>1 { column.width=max(100,bounds.width) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row=row(at:convert(event.locationInWindow,from:nil))
        guard row>=0,let item=item(atRow:row) as? SpacesOutline.Item else { return nil }
        return contextMenuForItem?(item)
    }
}

private final class SpaceOutlineCell: NSTableCellView {
    let icon=NSImageView(),label=NSTextField(labelWithString:""),count=NSTextField(labelWithString:""),link=NSImageView()
    override init(frame: NSRect) {
        super.init(frame:frame)
        imageView=icon;textField=label
        label.font = .systemFont(ofSize:13);label.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize:11);count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required,for:.horizontal)
        link.image=NSImage(systemSymbolName:"link",accessibilityDescription:nil);link.contentTintColor = .secondaryLabelColor
        link.symbolConfiguration = .init(pointSize:11,weight:.regular)
        let stack=NSStackView(views:[icon,label,link,count]);stack.orientation = .horizontal;stack.alignment = .centerY;stack.spacing=7;stack.translatesAutoresizingMaskIntoConstraints=false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:2),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),stack.centerYAnchor.constraint(equalTo:centerYAnchor),icon.widthAnchor.constraint(equalToConstant:18),icon.heightAnchor.constraint(equalToConstant:18),link.widthAnchor.constraint(equalToConstant:12)])
    }
    convenience init() { self.init(frame:.zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
