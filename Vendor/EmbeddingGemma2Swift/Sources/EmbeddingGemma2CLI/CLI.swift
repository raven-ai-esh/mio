import Foundation
import EmbeddingGemma2
import CryptoKit
import MLX

struct Request: Decodable {
    var texts: [String]?
    var task: String?
    var dimensions: Int?
    var input_ids: [[Int]]?
    var attention_mask: [[Int]]?
    var repetitions: Int?
    var query: String?
    var documents: [String]?
    var images: [String]?
    var vision_directory: String?
    var max_soft_tokens: Int?
    var pixel_reference: String?
    var audio: [String]?
    var audio_directory: String?
    var feature_reference: String?
}
@main struct CLI {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("Error: \(error)\n").utf8))
            exit(1)
        }
    }
    static func run() async throws {
        // CLI policy: bound reusable GPU buffers; library callers choose their own limit.
        Memory.cacheLimit = 64*1024*1024
        let args = CommandLine.arguments
        if args.count==5,args[1]=="--quantize",let bits=Int(args[4]) {
            try QuantizedCheckpoint.convert(source:URL(fileURLWithPath:args[2]),destination:URL(fileURLWithPath:args[3]),bits:bits)
            try emit(["converted":true,"bits":bits]);return
        }
        guard args.count >= 3 else {
            print("Usage: eg2-embed MODEL_DIRECTORY REQUEST.json [--float32]\nRequest: {\"texts\":[\"hello\"],\"task\":\"document\",\"dimensions\":768}; or {\"query\":\"...\",\"documents\":[\"...\"]}")
            throw EmbeddingError.invalid("Model directory and request are required")
        }
        let request = try JSONDecoder().decode(Request.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        if args.contains("--audio-preprocess-only") {
            guard let path=request.audio?.first else { throw EmbeddingError.invalid("Expected audio path") }
            let prepared=try AudioProcessor.prepare(samples:AudioProcessor.loadWAV(URL(fileURLWithPath:path)))
            var result=audioMetadata(prepared)
            if let path=request.feature_reference {
                let reference=try MLX.loadArrays(url:URL(fileURLWithPath:path))
                guard let features=reference["features"],let mask=reference["mask"],features.size==prepared.features.count else { throw EmbeddingError.invalid("Feature shape mismatch") }
                result["feature_max_error"]=zip(features.asArray(Float.self),prepared.features).map { abs($0-$1) }.max()!
                result["mask_match"]=mask.asArray(Int32.self)==prepared.mask
            }
            try emit(result);return
        }
        if args.contains("--preprocess-only") {
            guard let path = request.images?.first else { throw EmbeddingError.invalid("Preprocessing requires an image") }
            let prepared = try ImageProcessor.prepare(RGBImage.load(URL(fileURLWithPath:path)),maxSoftTokens:request.max_soft_tokens ?? 280)
            var result = imageMetadata(prepared)
            if let reference = request.pixel_reference {
                let tensors = try MLX.loadArrays(url:URL(fileURLWithPath:reference))
                guard let pixels = tensors["pixels"], let positions = tensors["positions"], pixels.size == prepared.pixels.count, positions.size == prepared.positions.count else { throw EmbeddingError.invalid("Preprocessing reference shape mismatch") }
                let expected = pixels.asArray(Float.self)
                result["pixel_max_absolute_error"] = zip(expected,prepared.pixels).map { abs($0-$1) }.max()!
                result["positions_match"] = positions.asArray(Int32.self) == prepared.positions
            }
            try emit(result); return
        }
        let start = Date()
        let encoder = try await TextEncoder(directory:URL(fileURLWithPath:args[1]),float32:args.contains("--float32"),progress: { message in FileHandle.standardError.write(Data((message+"\n").utf8)) })
        if let paths=request.audio {
            guard !paths.isEmpty,let directory=request.audio_directory,request.images==nil,request.texts==nil,request.documents==nil,request.input_ids==nil,request.task==nil else { throw EmbeddingError.invalid("Audio request needs audio paths and audio_directory only (query/dimensions optional)") }
            try await encoder.enableAudio(directory:URL(fileURLWithPath:directory))
            let load=Date().timeIntervalSince(start),dimensions=request.dimensions ?? 768
            var vectors=[[Float]](),ids=[[Int]](),metadata=[[String:Any]](),elapsed=[Double]()
            for path in paths {
                let t=Date(),prepared=try AudioProcessor.prepare(samples:AudioProcessor.loadWAV(URL(fileURLWithPath:path)))
                ids.append(try await encoder.audioTokenIDs(softTokenCount:prepared.softTokenCount))
                vectors.append(try await encoder.encodeAudio(prepared,dimensions:dimensions))
                elapsed.append(Date().timeIntervalSince(t));metadata.append(audioMetadata(prepared))
            }
            var result:[String:Any]=["embeddings":vectors,"input_ids":ids,"audio":metadata,"dimensions":dimensions,"precision":args.contains("--float32") ? "float32":"bfloat16","load_seconds":load,"encode_seconds":elapsed,"memory":await encoder.memory(),"text_weight_format":await encoder.weightFormat()]
            if let query=request.query {
                let q=try await encoder.encode([query],task:.search,dimensions:dimensions)[0]
                result["ranking"]=paths.enumerated().map { i,path in ["audio":path,"score":zip(q,vectors[i]).reduce(Float(0)) { $0+$1.0*$1.1 }] as [String:Any] }.sorted { ($0["score"] as! Float)>($1["score"] as! Float) }
            }
            try emit(result);return
        }
        if let images = request.images {
            guard !images.isEmpty, request.texts == nil, request.documents == nil, request.input_ids == nil, request.task == nil,
                  let vision = request.vision_directory else { throw EmbeddingError.invalid("Image request needs images and vision_directory; omit texts/documents/task/input_ids") }
            try await encoder.enableVision(directory:URL(fileURLWithPath:vision))
            let load = Date().timeIntervalSince(start)
            let dimensions = request.dimensions ?? 768
            var vectors = [[Float]](), ids = [[Int]](), metadata = [[String:Any]](), elapsed = [Double]()
            for path in images {
                let t = Date()
                let prepared = try ImageProcessor.prepare(RGBImage.load(URL(fileURLWithPath:path)),maxSoftTokens:request.max_soft_tokens ?? 280)
                ids.append(try await encoder.imageTokenIDs(softTokenCount:prepared.softTokenCount))
                vectors.append(try await encoder.encodeImage(prepared,dimensions:dimensions))
                elapsed.append(Date().timeIntervalSince(t)); metadata.append(imageMetadata(prepared))
            }
            var result:[String:Any] = ["embeddings":vectors,"input_ids":ids,"images":metadata,"dimensions":dimensions,"precision":args.contains("--float32") ? "float32":"bfloat16","load_seconds":load,"encode_seconds":elapsed,"memory":await encoder.memory(),"text_weight_format":await encoder.weightFormat()]
            if let query = request.query {
                let q = try await encoder.encode([query],task:.search,dimensions:dimensions)[0]
                result["query_embedding"] = q
                result["ranking"] = images.enumerated().map { i,path in ["image":path,"score":zip(q,vectors[i]).reduce(Float(0)) { $0+$1.0*$1.1 }] as [String:Any] }.sorted { ($0["score"] as! Float) > ($1["score"] as! Float) }
            }
            try emit(result); return
        }
        let loadSeconds = Date().timeIntervalSince(start)
        let taskName = request.task ?? "raw"
        guard let task = EmbeddingTask(rawValue:taskName) else { throw EmbeddingError.invalid("Unknown task: \(taskName)") }
        let dimensions = request.dimensions ?? 768
        let repetitions = request.repetitions ?? 1
        guard (1...100).contains(repetitions) else { throw EmbeddingError.invalid("Repetitions must be 1...100") }
        var embeddings = [[Float]](), tokenIDs = [[Int]](), elapsed = [Double]()
        var texts = request.texts ?? []
        if let query = request.query, let documents = request.documents {
            guard request.texts == nil, request.input_ids == nil, task == .raw else {
                throw EmbeddingError.invalid("Search requests apply query/document prefixes automatically; omit task, texts and input_ids")
            }
            texts = [EmbeddingTask.search.format(query)] + documents.map { EmbeddingTask.document.format($0) }
        }
        for _ in 0..<repetitions {
            let t = Date()
            if let ids = request.input_ids, let mask = request.attention_mask {
                tokenIDs = ids
                embeddings = try await encoder.encodeTokens(ids:ids,mask:mask,dimensions:dimensions)
            } else {
                tokenIDs = try await encoder.tokenize(texts,task:task)
                embeddings = try await encoder.encode(texts,task:task,dimensions:dimensions)
            }
            elapsed.append(Date().timeIntervalSince(t))
        }
        var result: [String:Any] = ["embeddings":embeddings,"input_ids":tokenIDs,"load_seconds":loadSeconds,"encode_seconds":elapsed,"dimensions":dimensions,"precision":args.contains("--float32") ? "float32":"bfloat16","memory":await encoder.memory(),"text_weight_format":await encoder.weightFormat()]
        if let docs = request.documents, embeddings.count == docs.count+1 {
            result["ranking"] = docs.enumerated().map { index,document in
                ["document":document,"score":zip(embeddings[0],embeddings[index+1]).reduce(Float(0)) { $0+$1.0*$1.1 }] as [String:Any]
            }.sorted { ($0["score"] as! Float) > ($1["score"] as! Float) }
        }
        try emit(result)
    }
    static func imageMetadata(_ image: PreparedImage) -> [String:Any] {
        ["resized_size":[image.width,image.height],"soft_tokens":image.softTokenCount,"max_soft_tokens":image.maxSoftTokens,"resized_rgb_sha256":SHA256.hash(data:Data(image.resizedRGB)).map { String(format:"%02x",$0) }.joined()]
    }
    static func emit(_ result:[String:Any]) throws {
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
    static func audioMetadata(_ audio:PreparedAudio) -> [String:Any] {
        ["sample_count":audio.sampleCount,"frames":audio.frames,"valid_frames":audio.mask.reduce(0,+),"soft_tokens":audio.softTokenCount]
    }
}
