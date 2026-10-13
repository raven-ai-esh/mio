import Foundation
import Darwin
import MioCore

/// The native Metal process is shared by indexing and queries. Its protocol is
/// bounded and supervised; a crash/timeout discards the process, never an index.
public final class MioEmbeddingWorker: @unchecked Sendable {
    public static let modelID = "embeddinggemma2-q8-v1"
    public let modelDirectory: URL
    public let executable: URL
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var stopped = false
    private let timeout: TimeInterval
    public init(executable: URL, modelDirectory: URL, timeout: TimeInterval = 40) {
        self.executable = executable; self.modelDirectory = modelDirectory; self.timeout = timeout
    }
    deinit { stop() }
    public func stop() { lock.lock(); defer { lock.unlock() }; stopped=true;discard() }
    private func discard() {
        try? input?.close(); try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil; buffer.removeAll()
    }
    private func readLine(deadline: Date) throws -> JSONValue {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let data = Data(buffer.prefix(upTo: end)); buffer.removeFirst(buffer.distance(from:buffer.startIndex,to:end) + 1)
                return try JSONValue.decode(data)
            }
            guard buffer.count < 500_000 else { throw MioError("embedding_protocol_error", "Embedding response exceeds its byte limit") }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let output else { throw MioError("embedding_timeout", "Local model did not reply in time") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 { if errno == EINTR { continue }; throw MioError("embedding_process_failed", "Cannot read the local model response") }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
            guard count > 0 else { throw MioError("embedding_process_failed", "Local model exited before replying") }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
    private func start() throws {
        if process?.isRunning == true { return }
        discard()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MioError("embedding_runtime_missing", "The bundled local model runtime is unavailable") }
        let task = Process(), incoming = Pipe(), outgoing = Pipe()
        task.executableURL = executable; task.arguments = [modelDirectory.path]
        task.standardInput = incoming; task.standardOutput = outgoing; task.standardError = FileHandle.nullDevice
        try task.run(); process = task; input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        let ready = try readLine(deadline: Date().addingTimeInterval(timeout))
        guard ready["state"] == .string("ready"), ready["model"] == .string(Self.modelID), ready["dimensions"].intValue == 768 else { throw MioError("embedding_load_failed", ready["error"].stringValue ?? "Local model could not be loaded") }
    }
    public func encode(task: String, texts: [String] = [], title: String = "", image: URL? = nil) throws -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw MioError("embedding_stopped","Local model service is stopped") }
        do {
            try start()
            let id = UUID().uuidString
            var request: [String: JSONValue] = ["id": .string(id), "task": .string(task), "texts": .array(texts.map(JSONValue.string)), "title": .string(title)]
            if let image { request["image"] = .string(image.path) }
            var data = try JSONValue.object(request).encoded(); data.append(10)
            guard data.count <= 2_000_000 else { throw MioError("embedding_request_too_large", "Embedding input exceeds its byte limit") }
            try input!.write(contentsOf: data)
            let value = try readLine(deadline: Date().addingTimeInterval(timeout))
            guard value["id"] == .string(id), value["error"] == .null else { throw MioError("embedding_encode_failed", value["error"].stringValue ?? "Unexpected local model response") }
            let vectors = value["vectors"].arrayValue.map { $0.arrayValue.map { value -> Float in if case .number(let number) = value { return Float(number) }; return .nan } }
            guard vectors.count == (task == "image" ? 1 : texts.count), vectors.allSatisfy({ $0.count == 768 && $0.allSatisfy(\.isFinite) && abs($0.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.02 }) else { throw MioError("invalid_embedding", "Local model returned invalid vectors") }
            return vectors
        } catch { discard(); throw error }
    }
    public func query(_ text: String) throws -> MioSemanticQuery { MioSemanticQuery(modelID: Self.modelID, values: try encode(task: "query", texts: [text])[0]) }
}
