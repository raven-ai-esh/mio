import Foundation
import AppKit
import SwiftUI
import MioCore
import MioBridge
import MioCloud
import MioEmbeddings
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot: JSONValue = .object([:])
    @Published private(set) var loadingMemory = true
    @Published var tab = "notes"
    @Published var selectedSpace: String = ""
    @Published var selectedNote: String = ""
    @Published var selectedNotes = Set<String>()
    @Published var notesPendingDeletion = Set<String>()
    @Published var editingSpace: JSONValue = .null
    @Published var connectionSourceSpaceID = ""
    let dragSessionID = UUID().uuidString
    @Published private(set) var notesFocusedSpaceIDs = Set<String>()
    private var notesSidebarSpaceID: String?
    @Published private(set) var noteDetail: JSONValue = .null
    @Published private(set) var noteLoading = false
    @Published private(set) var noteLoadFailure = ""
    @Published var selectedSession: String = ""
    @Published var query = ""
    @Published var searchScope = "all"
    @Published var searchResults: [JSONValue] = []
    @Published var searchWorking = false
    @Published var searchStatus: JSONValue = .null
    @Published var indexingStatus: JSONValue = .null
    @Published var notice: MioLocalizedMessage = ""
    @Published var failure = ""
    @Published var busy = false
    @Published var inspector = true
    @Published var showSpaceSheet = false
    @Published var showConnectionSheet = false
    @Published var cloudStatus: JSONValue = .object([:])
    @Published var preferences = MioPreferences.load()
    @Published var recoveryDraft: RecoveryDraft?
    let graph = GraphWorkspaceModel()
    struct RecoveryDraft: Identifiable { let id = UUID(); var spaceID: String; var title: String; var body: String; var status: String }
    private(set) var store: MioStore? = nil
    private var server: LocalBridgeServer?
    private var indexer: MioSourceIndexer?
    private var cloud: CloudSyncCoordinator?
    private var cloudGeneration = 0
    private var cloudRunning = false
    private var loop: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var modelDownloadTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var snapshotChangeToken: String?
    private var noteLoadGeneration = 0

    var interfaceLanguage: MioLanguage { MioLanguage(rawValue: preferences.interfaceLanguage) ?? .system }
    var localizer: MioLocalizer { .init(language: interfaceLanguage) }
    var locale: Locale { interfaceLanguage.locale }
    func l(_ key: String, _ arguments: String...) -> String { localizer.text(key, arguments) }
    func date(_ value: JSONValue) -> String { MioFormat.date(value, locale: locale) }
    func status(_ value: String) -> String { l(MioFormat.status(value)) }
    func setInterfaceLanguage(_ language: MioLanguage) {
        guard preferences.interfaceLanguage != language.rawValue else { return }
        preferences.interfaceLanguage = language.rawValue
        preferences.save()
    }

    init(startIndexing: Bool = true) {
        selectedSpace = preferences.selectedSpace
        selectedNote = preferences.selectedNote
        do {
            let opened = try MioStore(directory: MioPaths.directory)
            store = opened
            let indexing = MioSourceIndexer(store: opened, executable: MioPaths.embeddingWorker, modelDirectory: MioPaths.modelDirectory)
            indexer = indexing
            let runtime = MioPaths.runtime
            try runtime.prepare()
            let service = LocalBridgeServer(socketURL: runtime.socketURL, ownerToken: try runtime.ownerToken(), onDelivery: { observation, context in
                try opened.observeMemoryDelivery(metadata: observation.metadata, context: context, peerPID: observation.peerPID, state: observation.state, errorCode: observation.errorCode)
            }) { method, params, context in
                let result = try opened.execute(method, params: params, context: context)
                NotificationCenter.default.post(name: .mioMemoryChanged, object: nil)
                return result
            }
            try service.start()
            server = service
            if startIndexing { indexing.start() }
            Task { await refresh(); await reconnectCloud() }
            loop = Task { [weak self] in
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { break }
                    await self.refresh()
                    await self.refreshIndexing()
                    ticks += 1
                    if ticks % 5 == 0 { await self.synchronizeCloud() }
                }
            }
        } catch {
            store = nil
            loadingMemory = false
            failure = error.localizedDescription
        }
    }
    var spaces: [JSONValue] { snapshot["spaces"].items.filter { !$0["deleted"].flag } }
    var allNotes: [JSONValue] { snapshot["notes"].items.filter { !$0["deleted"].flag && !$0["redacted"].flag && !$0["purged"].flag && $0["status"].text != "purged" } }
    var deletedNotes: [JSONValue] { snapshot["notes"].items.filter { $0["deleted"].flag && !$0["redacted"].flag && !$0["purged"].flag && $0["status"].text != "purged" } }
    var connections: [JSONValue] { snapshot["connections"].items.filter { !$0["deleted"].flag } }
    var sessions: [JSONValue] {
        snapshot["sessions"].items.filter { !$0["deleted"].flag && !$0["purged"].flag && $0["source"].text == "memory_operations_v1" }.sorted {
            let first = MioFormat.timestamp($0["opened_at"]) ?? .distantPast
            let second = MioFormat.timestamp($1["opened_at"]) ?? .distantPast
            return first == second ? $0.id < $1.id : first > second
        }
    }
    var profiles: [JSONValue] { snapshot["profiles"].items }
    var links: [JSONValue] { snapshot["links"].items.filter { !$0["deleted"].flag } }
    var selectedSpaceValue: JSONValue { spaces.first { $0.id == selectedSpace } ?? .null }
    var selectedNoteValue: JSONValue { noteDetail.id == selectedNote ? noteDetail : .null }
    var visibleSpaceIDs: Set<String> {
        if selectedSpace.isEmpty { return Set(spaces.map(\.id)) }
        return expandedSpaces([selectedSpace]).union(connections.filter { $0["from_space_id"].text == selectedSpace }.map { $0["to_space_id"].text })
    }
    var visibleNotes: [JSONValue] {
        let visible=visibleSpaceIDs
        return allNotes.filter { visible.contains($0["space_id"].text) }.sorted { $0["updated_at"].text > $1["updated_at"].text }
    }
    var notesFilterActive: Bool { !notesFocusedSpaceIDs.isEmpty }
    func notesOpacity(_ note: JSONValue) -> Double { notesFocusedSpaceIDs.isEmpty || expandedSpaces(notesFocusedSpaceIDs).contains(note["space_id"].text) ? 1 : 0.06 }
    var notesInLiveSpaces: [JSONValue] {
        let available = Set(spaces.map(\.id))
        return allNotes.filter { available.contains($0["space_id"].text) }
    }
    var notesForDisplay: [JSONValue] {
        let focus=expandedSpaces(notesFocusedSpaceIDs),unfiltered=notesFocusedSpaceIDs.isEmpty
        return notesInLiveSpaces.sorted {
            let a = unfiltered || focus.contains($0["space_id"].text), b = unfiltered || focus.contains($1["space_id"].text)
            if a != b { return a }
            return $0["updated_at"] == $1["updated_at"] ? $0.id < $1.id : $0["updated_at"].text > $1["updated_at"].text
        }
    }
    var emphasizedNoteCount: Int {
        let focus=expandedSpaces(notesFocusedSpaceIDs)
        return notesFocusedSpaceIDs.isEmpty ? notesInLiveSpaces.count:notesInLiveSpaces.filter{focus.contains($0["space_id"].text)}.count
    }
    func setNotesSpaceSelected(_ id: String, selected: Bool) {
        if selected { notesFocusedSpaceIDs.insert(id) } else { notesFocusedSpaceIDs.remove(id) }
    }
    func showAllNotesSpaces() { notesFocusedSpaceIDs = [] }
    func focusNotesSpace(_ id: String) { notesFocusedSpaceIDs = id.isEmpty ? [] : [id] }
    func synchronizeNotesSpaces() {
        let available = Set(spaces.map(\.id))
        if notesSidebarSpaceID != selectedSpace {
            focusNotesSpace(available.contains(selectedSpace) ? selectedSpace : "")
            notesSidebarSpaceID = selectedSpace
        } else { notesFocusedSpaceIDs.formIntersection(available) }
    }
    var visibleSessions: [JSONValue] { sessions.filter { visibleSpaceIDs.contains($0["space_id"].text) || !visibleSpaceIDs.isDisjoint(with: Set($0["target_space_ids"].items.map(\.text))) }.sorted { $0["updated_at"].text > $1["updated_at"].text } }
    func sessionName(_ session: JSONValue) -> String { profiles.first { $0.id == session["actor"].text }?["name"].text ?? l("Подключение агента") }
    func spaceName(_ id: String) -> String { spaces.first { $0.id == id }?["name"].text ?? l("Пространство") }
    func execute(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let store else { throw NSError(domain: "Mio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Хранилище недоступно"]) }
        return try await Task.detached(priority: .userInitiated) { try store.execute(method, params: params) }.value
    }
    func refresh() async {
        guard let store else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        defer { if generation == refreshGeneration { loadingMemory = false } }
        do {
            let token = try await Task.detached { try store.currentChangeToken() }.value
            guard generation == refreshGeneration, token != snapshotChangeToken else { return }
            let next = try await execute("snapshot", ["projection": .string("compact")])
            guard generation == refreshGeneration else { return }
            // Cache the token observed before the snapshot, so a concurrent
            // later commit remains detectable on the next refresh.
            snapshotChangeToken = token
            guard next != snapshot else { return }
            let searchableChanged=next["notes"] != snapshot["notes"] || next["events"] != snapshot["events"] || next["spaces"] != snapshot["spaces"] || next["connections"] != snapshot["connections"]
            snapshot = next
            graph.updateSpaceHierarchy(spaces)
            graph.invalidatePurgedSources(Set(next["notes"].items.filter { $0["purged"].flag || $0["status"].text == "purged" }.map(\.id)))
            if !graph.sessionID.isEmpty && !sessions.contains(where: { $0.id == graph.sessionID }) { graph.clearSession(); graph.dismissInspector() }
            if searchableChanged && !query.isEmpty { search() }
            let validNotes = Set((allNotes+deletedNotes).map(\.id))
            selectedNotes.formIntersection(Set(notesInLiveSpaces.map(\.id)))
            let previousDraftCount = preferences.drafts.count
            preferences.drafts = preferences.drafts.filter { validNotes.contains($0.key) }
            if preferences.drafts.count != previousDraftCount { preferences.save() }
            if !selectedSpace.isEmpty && !spaces.contains(where: { $0.id == selectedSpace }) { selectedSpace = "" }
            if !selectedNote.isEmpty && !allNotes.contains(where: { $0.id == selectedNote }) { selectedNote = "" }
            if !selectedSession.isEmpty && !sessions.contains(where: { $0.id == selectedSession }) { selectedSession = "" }
            if selectedNote.isEmpty { noteLoadGeneration += 1; noteDetail = .null; noteLoading = false; noteLoadFailure = "" }
            else if let metadata = allNotes.first(where: { $0.id == selectedNote }), noteDetail.id != selectedNote || ["revision_id", "head_revision_ids", "has_conflict", "status", "updated_at", "space_id", "location_id"].contains(where: { noteDetail[$0] != metadata[$0] }) { await loadSelectedNote() }
        } catch { failure = error.localizedDescription }
    }
    func selectSpace(_ id: String) {
        selectedNotes=[];selectedSpace = id; selectedNote = ""; noteLoadGeneration += 1; noteDetail = .null; noteLoading = false; noteLoadFailure = ""; preferences.selectedSpace = id; preferences.selectedNote = ""; preferences.save()
        if !query.isEmpty { search() }
    }
    func selectNote(_ id: String) {
        selectedNotes=[id];selectedNote = id; preferences.selectedNote = id; preferences.save(); tab = "notes"
        if noteDetail.id != id { noteDetail = .null }
        noteLoading = true; noteLoadFailure = ""
        noteLoadGeneration += 1
        let generation = noteLoadGeneration
        Task { await loadSelectedNote(generation: generation) }
    }
    func loadSelectedNote() async {
        noteLoadGeneration += 1
        await loadSelectedNote(generation: noteLoadGeneration)
    }
    private func loadSelectedNote(generation: Int) async {
        guard generation == noteLoadGeneration else { return }
        let id = selectedNote
        guard !id.isEmpty else { return }
        noteLoading = true; noteLoadFailure = ""
        do {
            let value = try await execute("read", ["kind": .string("note"), "id": .string(id)])
            guard generation == noteLoadGeneration, selectedNote == id, allNotes.contains(where: { $0.id == id }) else { return }
            guard value.id == id, !value["body_omitted"].flag else { throw MioError("incomplete_note", "Полный текст заметки не получен") }
            noteDetail = value; noteLoading = false
        } catch {
            guard generation == noteLoadGeneration, selectedNote == id else { return }
            noteDetail = .null; noteLoading = false; noteLoadFailure = error.localizedDescription
        }
    }
    func createSpace(name: String, color: String) async {
        do {
            let result = try await execute("space.create", ["name": .string(name), "color": .string(color)])
            await refresh()
            selectSpace(result["id"].text.isEmpty ? spaces.last?.id ?? "" : result["id"].text)
            tab = "notes"; notice = "Пространство создано"
        } catch { failure = error.localizedDescription }
    }
    func createNote() async {
        guard let space = spaces.first(where: { $0.id == selectedSpace }) ?? spaces.first else { showSpaceSheet = true; return }
        do {
            let result = try await execute("note.create", ["space_id": .string(space.id), "title": .string(l("Новая заметка")), "body": .string(""), "status": .string("hypothesis"), "idempotency_key": .string(UUID().uuidString)])
            await refresh()
            let id = result["id"].text.isEmpty ? result["note_id"].text : result["id"].text
            selectNote(id.isEmpty ? visibleNotes.first?.id ?? "" : id)
        } catch { failure = error.localizedDescription }
    }
    func stageDraft(id: String, title: String, body: String, revision: String, status: String) {
        preferences.drafts[id] = .init(title: title, body: body, revision: revision, status: status)
        preferences.save()
    }
    func saveNote(id: String, title: String, body: String, revision: String, status: String) async -> Bool {
        busy = true; defer { busy = false }
        do {
            _ = try await execute("note.update", ["note_id": .string(id), "expected_revision": .string(revision), "title": .string(title), "body": .string(body), "status": .string(status), "idempotency_key": .string(UUID().uuidString)])
            preferences.drafts.removeValue(forKey: id); preferences.save()
            await refresh(); notice = "Сохранено локально"; return true
        } catch {
            if let failure = error as? MioError, failure.code == "source_purged" {
                let spaceID = snapshot["notes"].items.first { $0.id == id }?["space_id"].text ?? selectedSpace
                recoveryDraft = .init(spaceID: spaceID, title: title, body: body, status: status)
            } else { failure = error.localizedDescription }
            await refresh(); return false
        }
    }
    func recoverAsNewNote() async {
        guard let draft = recoveryDraft else { return }
        do {
            let result = try await execute("note.create", ["space_id": .string(draft.spaceID), "title": .string(draft.title), "body": .string(draft.body), "status": .string(draft.status), "source_ids": .array([]), "idempotency_key": .string(UUID().uuidString)])
            recoveryDraft = nil; await refresh(); selectNote(result["id"].text); notice = "Сохранено как новая заметка"
        } catch { failure = error.localizedDescription }
    }
    func deleteNote(_ id: String) async {
        do { _ = try await execute("note.delete", ["note_id": .string(id)]); await refresh(); notice = "Заметка удалена из актуальной памяти" }
        catch { failure = error.localizedDescription }
    }
    func purgeSession(_ id: String) async {
        let session = snapshot["sessions"].items.first { $0.id == id } ?? .null
        do {
            recoveryDraft = nil
            _ = try await execute("history.purge", ["session_id": .string(id)])
            if session["source"].text != "memory_operations_v1" {
                let external = session["external_id"].text; let space = session["space_id"].text
                preferences.historySources.removeAll { $0.id == external && $0.spaceID == space }
                let ignored = space + "|" + external
                if !preferences.ignoredHistorySources.contains(ignored) { preferences.ignoredHistorySources.append(ignored) }
            }
            preferences.save(); await refresh(); notice = "Сохранённая история очищена"
        } catch { failure = error.localizedDescription }
    }
    func shutdown() { graph.shutdown(); loop?.cancel(); searchTask?.cancel(); modelDownloadTask?.cancel(); indexer?.stop(); noteLoadGeneration += 1; cloudGeneration += 1; server?.stop(); server = nil; cloud = nil }
    func refreshIndexing() async {
        guard let indexer else { return }
        if let status = try? await Task.detached(operation: { try indexer.status() }).value {
            let previous=indexingStatus
            indexingStatus=status
            let changed=previous["model_state"] != status["model_state"] || ["generation","ready","lexical","fragments","error"].contains { previous["index"][$0] != status["index"][$0] }
            if changed && !query.isEmpty { search() }
        }
    }
    func downloadSearchModel() async {
        guard let indexer, modelDownloadTask == nil else { return }
        let downloading=Task.detached { await indexer.downloadModel() }
        modelDownloadTask=downloading;await downloading.value;modelDownloadTask=nil
        await refreshIndexing(); if !query.isEmpty { search() }
    }
    func cancelModelDownload() { modelDownloadTask?.cancel() }
    func retryIndexing() async {
        do { try indexer?.retry(); await refreshIndexing(); notice = "Неудачные задания будут повторены" }
        catch { failure = error.localizedDescription }
    }
    func chooseFileImport() async {
        guard let space = spaces.first(where: { $0.id == selectedSpace }) ?? spaces.first else { showSpaceSheet = true; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .heic, .webP, .tiff]; panel.prompt = l("Добавить в память")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; defer { busy = false }
        do {
            let params = try await Task.detached { () throws -> [String:JSONValue] in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 20_000_000 else { throw MioError("invalid_file", "Выберите файл не больше 20 МБ") }
                let bytes = try Data(contentsOf: url), mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
                return ["space_id": .string(space.id), "title": .string(url.deletingPathExtension().lastPathComponent), "body": .string(""), "status": .string("unverified"), "file_name": .string(url.lastPathComponent), "mime_type": .string(mime), "file_base64": .string(bytes.base64EncodedString()), "idempotency_key": .string(UUID().uuidString)]
            }.value
            let result = try await execute("note.create", params)
            await refresh(); selectNote(result["note_id"].text); await refreshIndexing()
            notice = "Файл сохранён · индексация выполняется в фоне"
        } catch { failure = error.localizedDescription }
    }
    func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; searchWorking = false; return }
        searchWorking = true
        let scope = searchScope; let ids = visibleSpaceIDs
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            do {
                let result = try await execute("search", ["query": .string(q), "scope": .string(scope), "space_ids": .array(ids.map(JSONValue.string)), "limit": .number(40), "max_chars": .number(18000)])
                guard !Task.isCancelled else { return }
                searchResults = result["results"].items.isEmpty && !result.items.isEmpty ? result.items : result["results"].items
                searchStatus = result
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            if !Task.isCancelled { searchWorking = false }
        }
    }
    func chooseArchiveExport(markdown: Bool = false) async {
        let panel = markdown ? NSOpenPanel() : nil
        var destination: URL?
        if let panel { panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = l("Экспортировать"); if panel.runModal() == .OK { destination = panel.url } }
        else { let save = NSSavePanel(); save.nameFieldStringValue = "Mio-memory.mioarchive"; save.prompt = l("Экспортировать"); if save.runModal() == .OK { destination = save.url } }
        guard let destination else { return }
        do { _ = try await execute(markdown ? "markdown.export" : "archive.export", ["path": .string(destination.path), "space_ids": .array(visibleSpaceIDs.map(JSONValue.string))]); notice = "Экспорт сохранён" }
        catch { failure = error.localizedDescription }
    }
    func chooseImport(markdown: Bool = false) async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = markdown; panel.canChooseFiles = !markdown; panel.prompt = l("Импортировать")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if markdown && selectedSpace.isEmpty { showSpaceSheet = true; failure = "Сначала выберите пространство для импорта"; return }
        busy = true; defer { busy = false }
        do { let result = try await execute(markdown ? "markdown.import" : "archive.import", ["path": .string(url.path), "space_id": .string(selectedSpace), "mode": .string("merge")]); await refresh(); notice = "Импорт завершён"; if !result["warnings"].items.isEmpty { notice += ": \(result["warnings"].items.count) предупреждений" } }
        catch { failure = MioLocalizer.errorKey(for: error) }
    }
    func chooseCloudFolder() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = l("Подключить iCloud")
        let candidate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) { panel.directoryURL = candidate }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let store else { return }
        cloudGeneration += 1
        let generation = cloudGeneration
        cloud = nil
        do {
            let connection = try await Task.detached { try CloudSyncCoordinator.reconnect(store: store, directory: url) }.value
            guard generation == cloudGeneration else { return }
            preferences.cloudFolder = url.path; preferences.save()
            cloud = connection; cloudStatus = connection.status()
            await synchronizeCloud()
        } catch {
            guard generation == cloudGeneration else { return }
            cloudStatus = .object(["state": .string("error"), "error": .string(error.localizedDescription)])
        }
    }
    func reconnectCloud() async {
        cloudGeneration += 1
        cloud = nil
        guard let store, !preferences.cloudFolder.isEmpty else { return }
        do { cloud = try CloudSyncCoordinator(store: store, directory: URL(fileURLWithPath: preferences.cloudFolder)); cloudStatus = cloud?.status() ?? .null }
        catch { cloudStatus = .object(["state": .string("error"), "error": .string(error.localizedDescription)]) }
    }
    func disconnectCloud() {
        cloudGeneration += 1; cloud = nil
        preferences.cloudFolder = ""; preferences.save()
        cloudStatus = .object(["state": .string("disconnected")])
        notice = "Синхронизация отключена · локальная память сохранена"
    }
    func synchronizeCloud() async {
        guard let cloud, !cloudRunning else { return }
        let generation = cloudGeneration
        cloudRunning = true; defer { cloudRunning = false }
        do {
            let status = try await Task.detached { try cloud.sync() }.value
            guard generation == cloudGeneration else { return }
            cloudStatus = status; await refresh()
        } catch {
            guard generation == cloudGeneration else { return }
            cloudStatus = cloud.status()
        }
    }
}
