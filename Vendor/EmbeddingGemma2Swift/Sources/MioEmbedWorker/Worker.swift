import Foundation
import EmbeddingGemma2
import MLX

private struct Request: Decodable {
    var id: String
    var task: String
    var texts: [String]?
    var title: String?
    var image: String?
}

@main struct MioEmbedWorker {
    static func emit(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
    static func main() async {
        do {
            Memory.cacheLimit = 64 * 1024 * 1024
            let args = CommandLine.arguments
            guard args.count == 2 else { throw EmbeddingError.invalid("Expected model directory") }
            let base = URL(fileURLWithPath: args[1], isDirectory: true)
            let encoder = try await TextEncoder(directory: base.appendingPathComponent("text-q8"))
            var visionLoaded = false
            try emit(["state": "ready", "model": "embeddinggemma2-q8-v1", "dimensions": 768])
            while let line = readLine() {
                if line.isEmpty { continue }
                var requestID = ""
                do {
                    guard line.utf8.count <= 2_000_000 else { throw EmbeddingError.invalid("Embedding request exceeds limit") }
                    let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                    requestID = request.id
                    let started = Date()
                    let vectors: [[Float]]
                    if request.task == "image" {
                        guard let image = request.image else { throw EmbeddingError.invalid("Missing prepared image") }
                        if !visionLoaded { try await encoder.enableVision(directory: base.appendingPathComponent("vision-q8")); visionLoaded = true }
                        vectors = [try await encoder.encodeImage(url: URL(fileURLWithPath: image), maxSoftTokens: 280)]
                    } else {
                        guard let texts = request.texts, !texts.isEmpty, texts.count <= 8 else { throw EmbeddingError.invalid("Expected one to eight texts") }
                        switch request.task {
                        case "query": vectors = try await encoder.encode(texts, task: .search)
                        case "document":
                            let formatted = texts.map { EmbeddingTask.document.format($0, title: request.title) }
                            vectors = try await encoder.encode(formatted, task: .raw)
                        default: throw EmbeddingError.invalid("Unknown embedding task")
                        }
                    }
                    guard vectors.allSatisfy({ $0.count == 768 && $0.allSatisfy(\.isFinite) }) else { throw EmbeddingError.invalid("Invalid embedding shape") }
                    try emit(["id": requestID, "vectors": vectors, "seconds": Date().timeIntervalSince(started), "memory": await encoder.memory()])
                } catch { try emit(["id": requestID, "error": String(describing: error)]) }
            }
        } catch {
            try? emit(["state": "error", "error": String(describing: error)])
            exit(1)
        }
    }
}
