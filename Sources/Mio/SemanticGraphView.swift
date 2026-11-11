import AppKit
import SwiftUI
import MioCore
import MioEmbeddings

struct SemanticGraphRequest: Equatable {
    let revisions: [String: String]
    let indexGeneration: String
    let readyCount: Int
    let retry: Int
}

@MainActor final class SemanticGraphModel: ObservableObject {
    @Published private(set) var points: [String: SemanticGraphPoint] = [:]
    private var layout = SemanticGraphLayout()
    @Published private(set) var loading = true
    @Published private(set) var failure = false
    private var completed: SemanticGraphRequest?
    private var generation = 0

    func refresh(_ request: SemanticGraphRequest, from store: MioStore?) async {
        guard !Task.isCancelled, request != completed else { return }
        generation += 1
        let current = generation
        failure = false
        guard let store else {
            loading = false
            failure = true
            return
        }

        loading = layout.points.isEmpty
        let previous = layout
        let work = Task.detached(priority: .userInitiated) {
            try previous.refreshed(from: store, modelID: MioEmbeddingWorker.modelID, revisions: request.revisions)
        }
        defer { if current == generation { loading = false } }
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard current == generation, !Task.isCancelled else { return }
            layout = result
            if points != result.points { points = result.points }
            completed = request
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            failure = true
        }
    }

    func invalidatePurgedSources(_ ids: Set<String>) {
        guard layout.containsDerivedData(for: ids) else { return }
        generation += 1
        completed = nil
        layout = SemanticGraphLayout()
        points = [:]
        loading = true
    }
}

struct SemanticGraphView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var graph: GraphWorkspaceModel
    @ObservedObject var semantic: SemanticGraphModel
    let colors: [String: NSColor]
    @State private var retry = 0

    var body: some View {
        let liveSpaces = Set(model.spaces.map(\.id))
        let nodes = graph.nodes.filter { liveSpaces.contains($0.spaceID) }
        let revisions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.revisionID) })
        let positions = semantic.points.filter { id, point in revisions[id] == point.revisionID }
        let index = model.indexingStatus["index"]
        let request = SemanticGraphRequest(revisions: revisions, indexGeneration: index["generation"].text,
                                           readyCount: index["ready"].integer, retry: retry)
        ZStack(alignment: .bottomLeading) {
            SemanticGraphCanvas(localizer: model.localizer, nodes: nodes, edges: graph.edges,
                                positions: positions, colors: colors, selected: graph.selectedNodeID,
                                focusedSpaceIDs: graph.effectiveFocusedSpaceIDs, fitToken: graph.fitToken,
                                zoomCommand: graph.zoomCommand) { id in
                Task { await graph.inspect(id, using: model) }
            }

            if semantic.failure {
                ContentUnavailableView {
                    Label(model.l("Не удалось построить 3D-карту"), systemImage: "exclamationmark.triangle")
                } actions: {
                    Button(model.l("Повторить расчёт")) { retry += 1 }
                }
            } else if nodes.isEmpty {
                EmptyMemoryView(symbol: "point.3.connected.trianglepath.dotted",
                                title: model.l("Граф появится вместе с памятью"),
                                detail: model.l("Добавьте заметки или подключите другое пространство."))
            } else if positions.isEmpty {
                if semantic.loading {
                    ProgressView(model.l("Расположение узлов…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
            } else if positions.count < nodes.count {
                Text(model.l("На 3D-карте %@ из %@ заметок", String(positions.count), String(nodes.count)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .accessibilityIdentifier("graph.semantic.coverage")
            }
        }
        .task(id: request) {
            await semantic.refresh(request, from: model.store)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.l("На 3D-карте пока нет заметок"), systemImage: "cube")
        } description: {
            Text(model.l("Точки появятся после семантической индексации."))
        } actions: {
            if model.indexingStatus["model_state"].text == "missing" {
                SettingsLink { Text(model.l("Открыть настройки")) }
            }
        }
    }
}
