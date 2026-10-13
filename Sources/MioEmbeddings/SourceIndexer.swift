import Foundation
import Darwin
import MioCore

public final class MioSourceIndexer: @unchecked Sendable {
    public let modelDirectory: URL
    public let worker: MioEmbeddingWorker
    private let store: MioStore
    private let workDirectory:URL
    private let lock = NSLock()
    private var ready = false
    private var stopped = false
    private var modelState = "checking"
    private var modelError = ""
    private var progress: Double = 0
    private var currentTitle = ""
    private var indexed = 0
    private var total = 0
    private var loop: Task<Void, Never>?
    public init(store: MioStore, executable: URL, modelDirectory: URL) {
        self.store = store; self.modelDirectory = modelDirectory
        workDirectory=store.directory.appendingPathComponent("IndexWork/\(getpid())-"+UUID().uuidString,isDirectory:true)
        worker = MioEmbeddingWorker(executable: executable, modelDirectory: modelDirectory)
        store.configureSemanticSearch(queryEncoder: { [weak self] text in
            guard let self, self.isReady else { throw MioError("model_missing", "Локальная модель ещё не загружена или проверяется") }
            return try self.worker.query(text)
        }, imageRenderer: { file, bytes, locator in try MioDocumentExtraction.preview(file: file, bytes: bytes, locator: locator) })
    }
    private var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func setModel(state: String, error: String = "", progress: Double = 0) {
        lock.lock(); defer { lock.unlock() }; modelState = state; modelError = error; self.progress = progress; ready = state == "ready"
    }
    public func status() throws -> JSONValue {
        let index = try store.sourceIndexStatus()
        lock.lock(); defer { lock.unlock() }
        return .object(["model_state": .string(modelState), "model_error": .string(modelError), "download_progress": .number(progress), "model_id": .string(MioEmbeddingWorker.modelID), "model_bytes": .number(513_432_047), "current_title": .string(currentTitle), "completed_fragments": .number(Double(indexed)), "total_fragments": .number(Double(total)), "index": index])
    }
    public func checkModel() {
        cleanAbandonedWork()
        setModel(state: "checking")
        do {
            let manifest = try MioModelManifest.bundled()
            try manifest.verify(in: modelDirectory)
            guard FileManager.default.isExecutableFile(atPath: worker.executable.path) else { throw MioError("embedding_runtime_missing", "Локальный вычислитель отсутствует в приложении") }
            setModel(state: "ready")
        } catch { setModel(state: "missing", error: error.localizedDescription) }
    }
    private func cleanAbandonedWork() {
        let base=workDirectory.deletingLastPathComponent()
        for url in (try? FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:nil)) ?? [] {
            guard let prefix=url.lastPathComponent.split(separator:"-").first,let pid=Int32(prefix),pid>0 else { continue }
            if Darwin.kill(pid,0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at:url) }
        }
    }
    public func downloadModel() async {
        guard beginDownload() else { return }
        do {
            let manifest = try MioModelManifest.bundled()
            try await MioModelFiles.download(manifest: manifest, directory: modelDirectory) { [weak self] progress in self?.setModel(state: "downloading", progress: progress) }
            if !isStopped { setModel(state: "ready"); try store.resetSourceIndexErrors() }
        } catch { setModel(state: error is CancellationError ? "missing":"error", error: error is CancellationError ? "":error.localizedDescription) }
    }
    private func beginDownload() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !["downloading","checking"].contains(modelState) else { return false }
        modelState="downloading";modelError="";progress=0;ready=false
        return true
    }
    public func retry() throws { try store.resetSourceIndexErrors() }
    public func start() {
        guard loop == nil else { return }
        loop = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            self.checkModel()
            while !Task.isCancelled && !self.isStopped {
                do {
                    let worked = try self.indexNext()
                    if !worked { try? await Task.sleep(for: .seconds(2)) }
                } catch { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }
    public func stop() { lock.lock(); stopped = true; lock.unlock(); loop?.cancel(); worker.stop();try? FileManager.default.removeItem(at:workDirectory) }
    /// Returns false after the generation is complete. Canonical originals
    /// remain unchanged; interrupted work is safely repeated on the next run.
    @discardableResult public func indexNext() throws -> Bool {
        let semantic = isReady
        let model = semantic ? MioEmbeddingWorker.modelID : "lexical-native-v1"
        guard let job = try store.nextSourceIndexJob(modelID: model) else { return false }
        lock.lock(); currentTitle = job["note"]["title"].stringValue ?? ""; indexed = 0; total = 0; lock.unlock()
        defer { lock.lock(); currentTitle = ""; indexed = 0; total = 0; lock.unlock() }
        do {
            let file = job["file"]
            var bytes = Data(), fragments: [JSONValue] = []
            if file != .null {
                guard let original = Data(base64Encoded: file["bytes"].stringValue ?? "") else { throw MioError("invalid_source", "Original file bytes are unavailable") }
                bytes = original
                fragments = try MioDocumentExtraction.fragments(file: file, bytes: bytes)
            }
            let documents = try store.sourceDocuments(job: job, fileFragments: fragments)
            lock.lock(); total = documents.count; lock.unlock()
            var vectors: [[Float]] = []
            if semantic {
                for document in documents {
                    guard !isStopped else { return false }
                    if document["modality"] == .string("image") {
                        let preview = try MioDocumentExtraction.preview(file: file, bytes: bytes, locator: document["locator"])
                        try FileManager.default.createDirectory(at:workDirectory,withIntermediateDirectories:true)
                        let temporary = workDirectory.appendingPathComponent(job["note"]["id"].stringValue!+"-"+UUID().uuidString+".png")
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        try preview.write(to: temporary, options: [.atomic, .completeFileProtection])
                        vectors += try worker.encode(task: "image", image: temporary)
                    } else {
                        vectors += try worker.encode(task: "document", texts: [document["text"].stringValue ?? ""], title: document["title"].stringValue ?? "")
                    }
                    lock.lock(); indexed += 1; lock.unlock()
                }
            }
            guard !isStopped else { return false }
            _ = try store.publishSourceIndex(job: job, documents: documents, embeddings: vectors)
        } catch { if isStopped { return false };try store.failSourceIndex(job: job, error: error.localizedDescription) }
        return true
    }
}
