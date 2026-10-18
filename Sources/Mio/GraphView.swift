import SwiftUI
import AppKit
import MioCore

struct GraphView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { GraphWorkspace(graph:model.graph) }
}

struct GraphWorkspace: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var graph: GraphWorkspaceModel
    @State private var stepList = false
    private var colors: [String:NSColor] { Dictionary(uniqueKeysWithValues:model.spaces.map { ($0.id,NSColor(MioFormat.color($0["color"].text))) }) }
    private var matches: [MemoryGraphNode] { Array(graph.displayNodes.filter { $0.title.localizedCaseInsensitiveContains(graph.nodeQuery) }.prefix(10)) }
    private func synchronizeSpaces() { graph.synchronizeSidebarSpace(model.selectedSpace,available:Set(model.spaces.map(\.id))) }
    var body: some View {
        VStack(spacing:0) {
            header
            Divider()
            if !graph.nodeQuery.isEmpty { searchMatches; Divider() }
            if graph.mode == .history { sessionBar; Divider() }
            HStack(spacing:0) {
                ZStack {
                    GraphCanvas(localizer:model.localizer,nodes:graph.displayNodes,edges:graph.edges,positions:graph.displayPositions,colors:colors,selected:graph.selectedNodeID,history:graph.mode == .history,highlights:graph.highlights,focusedSpaceIDs:graph.effectiveFocusedSpaceIDs,fitToken:graph.fitToken,zoomCommand:graph.zoomCommand) { id in Task { await graph.inspect(id,using:model) } }
                    if graph.nodes.isEmpty && !graph.calculating {
                        EmptyMemoryView(symbol:"point.3.connected.trianglepath.dotted",title:model.l("Граф появится вместе с памятью"),detail:model.l("Добавьте заметки или подключите другое пространство."))
                    }
                    if graph.calculating { VStack { HStack { ProgressView().controlSize(.small); Text(model.l("Расположение узлов…")).font(.caption); Spacer() }.padding(14); Spacer() }.allowsHitTesting(false) }
                    if !graph.layoutFailure.isEmpty { VStack { Text(graph.layoutFailure).foregroundStyle(.orange); Button(model.l("Повторить расчёт")) { graph.updateGraph(notes:model.allNotes,links:model.links,force:true) } }.padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) }
                }
                if graph.showInspector {
                    Divider()
                    GraphInspectorView(graph:graph).frame(width:330).background(.bar)
                }
            }
            Divider()
            if graph.mode == .history { playbackBar; Divider() }
            HStack {
                Text(model.l("%@ заметок · %@ связей", String(describing: graph.nodes.count), String(describing: graph.edges.count))).accessibilityIdentifier("graph.counts")
                if graph.spaceFilterActive { Text(model.l("%@ выделено · %@ приглушено", String(describing: graph.focusedNodeCount), String(describing: graph.displayNodes.count-graph.focusedNodeCount))).accessibilityIdentifier("graph.filterCounts") }
                Spacer()
                if graph.mode == .history { Text(model.l("Сохранённые обращения · фон: снимок текущей памяти")) }
                else { Text(model.l("Выберите узел для просмотра")) }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,11)
        }
        .onAppear { graph.purgedSourceTitle = model.l("Очищенный источник"); synchronizeSpaces(); graph.updateGraph(notes:model.allNotes,links:model.links) }
        .onChange(of:model.preferences.interfaceLanguage) { _,_ in graph.purgedSourceTitle = model.l("Очищенный источник") }
        .onChange(of:model.snapshot["notes"]) { _,_ in graph.updateGraph(notes:model.allNotes,links:model.links) }
        .onChange(of:model.snapshot["links"]) { _,_ in graph.updateGraph(notes:model.allNotes,links:model.links) }
        .onChange(of:model.snapshot["spaces"]) { _,_ in synchronizeSpaces() }
        .onChange(of:model.selectedSpace) { _,_ in synchronizeSpaces() }
        .onChange(of:graph.mode) { _,_ in graph.changeMode(using:model) }
        .onDisappear { graph.pause() }
    }
    private var header: some View {
        VStack(spacing:12) {
            HStack {
                Text(model.l("Граф памяти")).font(.title2.weight(.semibold))
                Spacer()
                Picker(model.l("Режим графа"),selection:$graph.mode) { Text(model.l("Память")).tag(GraphWorkspaceModel.Mode.memory); Text(model.l("История MCP")).tag(GraphWorkspaceModel.Mode.history) }.labelsHidden().pickerStyle(.segmented).frame(width:215).accessibilityIdentifier("graph.mode")
                Button { graph.zoomCommand -= 1 } label: { Image(systemName:"minus.magnifyingglass") }.accessibilityLabel(model.l("Уменьшить граф"))
                Button { graph.zoomCommand += 1 } label: { Image(systemName:"plus.magnifyingglass") }.accessibilityLabel(model.l("Увеличить граф"))
                Button { graph.fitToken += 1 } label: { Image(systemName:"arrow.up.left.and.arrow.down.right") }.help(model.l("Показать весь граф")).accessibilityIdentifier("graph.fit")
            }
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField(model.l("Найти узел по названию"),text:$graph.nodeQuery).textFieldStyle(.roundedBorder).frame(maxWidth:340).accessibilityIdentifier("graph.findNode")
                SpaceFilterControl(selectedSpaceIDs:graph.focusedSpaceIDs,accessibilityPrefix:"graph.spaceFilter",setSelected:{ id,selected in if graph.focusedSpaceIDs.contains(id) != selected { graph.toggleSpaceFocus(id) } },reset:graph.showAllSpaces)
                Spacer()
                if graph.mode == .history { Label(model.l("Пунктир — порядок чтений"),systemImage:"arrow.right").font(.caption).foregroundStyle(.orange) }
                else { Text(model.l("Группы определяются связями")).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(18)
    }
    private var searchMatches: some View {
        VStack(alignment:.leading,spacing:6) {
            if matches.isEmpty { Text(model.l("Узлы с таким названием не найдены")).foregroundStyle(.secondary) }
            ForEach(matches) { node in
                Button { graph.nodeQuery = ""; Task { await graph.inspect(node.id,using:model) } } label: {
                    HStack { Circle().fill(MioFormat.color(model.spaces.first{$0.id==node.spaceID}?["color"].text ?? "blue")).frame(width:7,height:7); Text(node.title).lineLimit(1); Spacer(); Image(systemName:"sidebar.right") }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("graph.find.\(node.id)")
            }
        }.font(.callout).padding(.horizontal,20).padding(.vertical,10)
    }
    private var sessionBar: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Picker(model.l("Соединение MCP"),selection:Binding(get:{graph.sessionID},set:{ id in Task { await graph.loadSession(id,using:model) } })) {
                    Text(model.l("Выберите сохранённое соединение")).tag("")
                    ForEach(model.sessions) { session in Text(model.sessionPickerLabel(session)).tag(session.id) }
                    if !graph.sessionID.isEmpty && !model.sessions.contains(where:{$0.id==graph.sessionID}) { Text(model.l("Выбранное соединение")).tag(graph.sessionID) }
                }.labelsHidden().frame(maxWidth:480).accessibilityLabel(model.l("Соединение MCP")).accessibilityIdentifier("graph.session")
                Spacer()
                Button(model.l("Обновить просмотр"),systemImage:"arrow.clockwise") { graph.updateGraph(notes:model.allNotes,links:model.links,force:true); Task { await graph.loadSession(graph.sessionID,using:model) } }.disabled(graph.sessionID.isEmpty || graph.sessionLoading)
            }
            if graph.sessionLoading { ProgressView(model.l("Загрузка сохранённой истории…")).controlSize(.small) }
            else if !graph.sessionFailure.isEmpty { HStack { Text(graph.sessionFailure).foregroundStyle(.orange); Button(model.l("Повторить")) { Task { await graph.loadSession(graph.sessionID,using:model) } } } }
            else if !graph.sessionID.isEmpty && graph.steps.isEmpty { Text(model.l("В этом соединении нет сохранённых обращений к памяти")).foregroundStyle(.secondary) }
            else if !graph.steps.isEmpty {
                HStack(spacing:14) {
                    Label(model.l("Найдено"),systemImage:"circle").foregroundStyle(.blue)
                    Label(model.l("Запрошено read"),systemImage:"circle.fill").foregroundStyle(.blue)
                    Label(model.l("Изменено"),systemImage:"circle.fill").foregroundStyle(.green)
                    Label(model.l("Выданные связи"),systemImage:"line.diagonal").foregroundStyle(.teal)
                }.font(.caption)
            }
        }.font(.callout).padding(.horizontal,18).padding(.vertical,12)
    }
    private var playbackBar: some View {
        HStack(spacing:12) {
            Button { graph.setStep(graph.stepIndex-1) } label: { Image(systemName:"backward.end") }.disabled(graph.stepIndex==0).accessibilityIdentifier("graph.previous")
            Button { graph.playing ? graph.pause():graph.play() } label: { Image(systemName:graph.playing ? "pause.fill":"play.fill") }.disabled(graph.steps.isEmpty || graph.sessionLoading).accessibilityIdentifier("graph.play")
            Button { graph.setStep(graph.stepIndex+1) } label: { Image(systemName:"forward.end") }.disabled(graph.stepIndex>=graph.steps.count).accessibilityIdentifier("graph.next")
            Slider(value:Binding(get:{Double(graph.stepIndex)},set:{graph.setStep(Int($0.rounded()))}),in:0...Double(max(1,graph.steps.count)),step:1).disabled(graph.steps.isEmpty).accessibilityIdentifier("graph.timeline").accessibilityLabel(model.l("Шаг истории MCP"))
            Button(graph.stepIndex==0 ? model.l("До начала"):model.l("Шаг %@ / %@", String(describing: graph.stepIndex), String(describing: graph.steps.count))) { stepList = true }.font(.caption.monospacedDigit()).frame(minWidth:100).accessibilityIdentifier("graph.stepList")
        }.padding(.horizontal,18).padding(.vertical,12)
        .popover(isPresented:$stepList) {
            ScrollView {
                LazyVStack(alignment:.leading,spacing:4) {
                    Button(model.l("До начала")) { graph.setStep(0); stepList = false }.buttonStyle(.plain).padding(8)
                    ForEach(Array(graph.steps.enumerated()),id:\.element.id) { index,step in
                        Button { graph.setStep(index+1); stepList = false } label: {
                            VStack(alignment:.leading,spacing:4) { Text("\(index+1). \(GraphStepCard.name(step.method,localizer:model.localizer))").font(.callout.weight(.medium)); Text(step.query.isEmpty ? model.date(.string(step.startedAt)):step.query).font(.caption).lineLimit(2).foregroundStyle(.secondary) }.padding(8).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(10)
            }.frame(width:380,height:400)
        }
    }
}

struct GraphInspectorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var graph: GraphWorkspaceModel
    @State private var evidence: JSONValue?
    @State private var versions = [JSONValue]()
    @State private var showVersions = false
    @State private var expandedBody = false
    private var note: JSONValue { graph.detail }
    private var title: String { !note["title"].text.isEmpty ? note["title"].text:graph.displayNodes.first{$0.id==graph.selectedNodeID}?.title ?? model.l("Узел памяти") }
    private var observedLinks: [JSONValue] {
        guard graph.mode == .history else { return note["links"].items }
        var result = [JSONValue](), seen = Set<String>()
        for step in graph.steps.prefix(graph.stepIndex).reversed() where step.hasRecordedGraph && step.issuedGraph["note_id"].text == graph.selectedNodeID && step.issuedGraph["revision_id"] == note["revision_id"] {
            for edge in step.issuedGraph["links"].items where seen.insert(edge.id).inserted { result.append(edge) }
        }
        return result
    }
    private var hasObservedPage: Bool { graph.steps.prefix(graph.stepIndex).contains { $0.hasRecordedGraph && $0.issuedGraph["note_id"].text == graph.selectedNodeID && $0.issuedGraph["revision_id"] == note["revision_id"] } }
    var body: some View {
        VStack(spacing:0) {
            HStack { Text(graph.selectedNodeID.isEmpty && graph.mode == .history ? model.l("Шаг истории"):model.l("Узел памяти")).font(.headline); Spacer(); Button { graph.dismissInspector() } label: { Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel(model.l("Закрыть панель графа")) }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if let step = graph.selectedStep { GraphStepCard(step:step,index:graph.stepIndex,graph:graph) }
                    if !graph.selectedNodeID.isEmpty { nodeContent }
                    if graph.selectedNodeID.isEmpty && graph.selectedStep == nil { Text(model.l("Выберите узел, чтобы увидеть его содержимое и связи.")).font(.callout).foregroundStyle(.secondary) }
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
        .sheet(item:$evidence) { EvidenceSheet(value:$0) }
        .onChange(of:graph.selectionGeneration) { _,_ in versions = []; showVersions = false; expandedBody = false; evidence = nil }
    }
    @ViewBuilder private var nodeContent: some View {
        Text(title).font(.title3.weight(.semibold)).textSelection(.enabled).accessibilityIdentifier("graph.nodeTitle")
        if graph.detailLoading { ProgressView(model.l("Загрузка узла…")) }
        else if !graph.detailFailure.isEmpty {
            Text(model.l("Источник недоступен")).font(.callout.weight(.medium))
            Text(graph.detailFailure).font(.caption).foregroundStyle(.secondary)
            Button(model.l("Повторить загрузку")) { Task { await graph.inspect(graph.selectedNodeID,using:model) } }
        } else if note != .null {
            HStack { Pill(text:model.status(note["status"].text)); Text(model.spaceName(note["space_id"].text)).font(.caption).foregroundStyle(.secondary) }
            Text(graph.mode == .history && !graph.inspectionRevisionID.isEmpty ? model.l("Версия источника из сохранённого обращения"):model.l("Актуальная версия памяти")).font(.caption).foregroundStyle(.secondary)
            Text(model.l("Обновлено в Mio: %@", String(describing: model.date(note["updated_at"] == .null ? note["timestamp"]:note["updated_at"])))).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.l("Открыть заметку")) { graph.pause(); model.selectNote(graph.selectedNodeID) }.accessibilityIdentifier("graph.openNote")
                Button(model.l("Версии")) { let id = graph.selectedNodeID, generation = graph.selectionGeneration; Task { do { let result = try await model.execute("note.history",["note_id":.string(id)]); guard graph.selectedNodeID == id, graph.selectionGeneration == generation else { return }; versions = result["revisions"].items; showVersions.toggle() } catch { if graph.selectionGeneration == generation { model.failure = error.localizedDescription } } } }
            }.font(.caption)
            if showVersions { ForEach(versions) { version in Button(model.date(version["timestamp"])) { openSource(version["id"]) }.font(.caption) } }
            ForEach(note["file_ids"].items.map(\.text),id:\.self) { file in Button(model.l("Показать исходный файл"),systemImage:"doc.viewfinder") { openSource(.string(file)) }.font(.caption).accessibilityIdentifier("graph.openFile") }
            if !note["body"].text.isEmpty {
                Divider()
                Text(expandedBody ? note["body"].text:String(note["body"].text.prefix(12000))).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("graph.nodeBody")
                if note["body"].text.count > 12000 { Button(expandedBody ? model.l("Свернуть текст"):model.l("Показать весь текст")) { expandedBody.toggle() }.font(.caption) }
            }
            Divider()
            Text(graph.mode == .history ? model.l("Связи, выданные в истории"):model.l("Связи узла")).font(.callout.weight(.semibold))
            if graph.mode == .history && observedLinks.isEmpty { Text(hasObservedPage ? model.l("В сохранённых страницах этого узла нет связей."):model.l("Для этой версии выданные связи не сохранены. Фон графа показывает текущую память.")).font(.caption).foregroundStyle(.secondary) }
            ForEach(observedLinks) { edge in
                Button { Task { await graph.inspect(edge["note"].id,using:model) } } label: { HStack(alignment:.top) { Image(systemName:edge["direction"].text == "incoming" ? "arrow.down.left":"arrow.up.right"); Text(graph.purgedSourceIDs.contains(edge["note"].id) ? model.l("Очищенный источник"):graph.displayNodes.first{$0.id==edge["note"].id}?.title ?? String(edge["note"].id.prefix(12))).lineLimit(3); Spacer() } }.buttonStyle(.plain).font(.caption)
            }
            if graph.mode == .memory && note["links_next_offset"] != .null { Button(model.l("Ещё связи")) { Task { await graph.loadMoreLinks(using:model) } }.font(.caption) }
            if !note["source_ids"].items.isEmpty {
                Divider(); Text(model.l("Источники")).font(.callout.weight(.semibold))
                ForEach(note["source_ids"].items.map(\.text),id:\.self) { source in Button(String(source.prefix(48))) { openSource(.string(source)) }.font(.caption).lineLimit(2) }
            }
        }
    }
    private func openSource(_ id: JSONValue) { let node = graph.selectedNodeID, generation = graph.selectionGeneration; Task { do { let result = try await model.execute("read",["kind":.string("source"),"id":id]); guard graph.selectedNodeID == node, graph.selectionGeneration == generation else { return }; evidence = result } catch { if graph.selectionGeneration == generation { model.failure = error.localizedDescription } } } }
}

struct GraphStepCard: View {
    @EnvironmentObject var model: AppModel
    var step: GraphReplayStep
    var index: Int
    @ObservedObject var graph: GraphWorkspaceModel
    static func name(_ method: String, localizer: MioLocalizer) -> String {
        switch method { case "search": return localizer.text("Поиск"); case "read": return localizer.text("Чтение источника"); case "note.create": return localizer.text("Создание памяти"); case "note.update": return localizer.text("Обновление памяти"); case "link.create": return localizer.text("Создание связи"); case "note.delete": return localizer.text("Удаление заметки"); default: return method }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(model.l("Шаг %@ · %@", String(describing: index), String(describing: Self.name(step.method,localizer:model.localizer)))).font(.callout.weight(.semibold)).accessibilityIdentifier("graph.stepTitle")
            HStack { Pill(text:model.status(step.outcome),color:step.isFailure ? .orange:.secondary); if let duration = step.durationMS { Text(String(format:model.l("%.0f мс"),duration)).font(.caption).foregroundStyle(.secondary) } }
            Text(model.date(.string(step.startedAt))).font(.caption).foregroundStyle(.secondary)
            if !step.query.isEmpty { Text(step.query).font(.callout).textSelection(.enabled) }
            if step.request["query_truncated"].flag { Text(model.l("В журнале сохранено начало запроса")).font(.caption).foregroundStyle(.secondary) }
            if step.replayed { Text(model.l("Повторное обращение · прежнее подтверждение операции")).font(.caption).foregroundStyle(.secondary) }
            if step.deliveryFailed { Text(model.l("Ошибка выдачи ответа MCP")).font(.caption).foregroundStyle(.orange) }
            if step.hasRecordedGraph { Text(model.l("Выданных связей в сохранённой странице: %@%@", String(describing: step.issuedEdges.count), String(describing: step.issuedGraph["next_offset"] == .null ? "":model.l(" · есть следующие страницы")))).font(.caption).foregroundStyle(.teal) }
            else if step.isRead { Text(model.l("Для этого обращения снимок выданных связей отсутствует")).font(.caption).foregroundStyle(.secondary) }
            ForEach(step.noteIDs,id:\.self) { id in
                Button { Task { await graph.inspect(id,using:model) } } label: { Label(graph.displayNodes.first{$0.id==id}?.title ?? String(id.prefix(12)),systemImage:"circle").lineLimit(3).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).font(.caption)
            }
            Divider()
        }
    }
}
