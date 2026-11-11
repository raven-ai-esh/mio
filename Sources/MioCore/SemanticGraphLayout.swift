import Accelerate
import Foundation

public struct SemanticGraphPoint: Equatable, Sendable {
    public let revisionID: String
    public let position: SIMD3<Float>
}

public struct SemanticGraphLayout: Sendable {
    public private(set) var points: [String: SemanticGraphPoint] = [:]
    private var signatures: [String: String] = [:]
    private var fittedNoteIDs: Set<String> = []
    private var basis: SemanticGraphBasis?
    private var modelID: String?

    public init() {}

    public func containsDerivedData(for ids: Set<String>) -> Bool {
        !fittedNoteIDs.isDisjoint(with: ids) || ids.contains { points[$0] != nil }
    }

    // This projection is called directly by the native owner. It is not an
    // RPC operation and does not change the index or request inference.
    public func refreshed(from store: MioStore, modelID: String, revisions: [String: String]) throws -> Self {
        guard !revisions.isEmpty else { return Self() }
        let reuseBasis = self.modelID == modelID && basis != nil
            && fittedNoteIDs.allSatisfy { revisions[$0] != nil }
        let previousSignatures = reuseBasis ? signatures : [:]
        let input = try store.semanticGraphInput(modelID: modelID, revisions: revisions, cached: previousSignatures)
        let vectors = try input.fragments.compactMapValues { fragments in
            try Task.checkCancellation()
            return SemanticGraphBasis.centroid(fragments)
        }

        var next = reuseBasis ? self : Self()
        next.points = next.points.filter { id, _ in
            previousSignatures[id] == input.signatures[id] && input.signatures[id] != nil
        }
        next.signatures = input.signatures.filter { next.points[$0.key] != nil }
        if !reuseBasis, !vectors.isEmpty {
            next.basis = try SemanticGraphBasis.fit(vectors.keys.sorted().compactMap { vectors[$0] })
            next.fittedNoteIDs = Set(vectors.keys)
        }
        next.modelID = modelID

        if var basis = next.basis {
            // A small or degenerate first batch has fewer than three meaningful
            // directions. Extend its span as new vectors arrive, keeping each
            // previously assigned coordinate and the original origin.
            if reuseBasis && basis.axes.count < 3 {
                for id in vectors.keys.sorted() {
                    guard basis.axes.count < 3 else { break }
                    if let vector = vectors[id], basis.addDirection(for: vector) { next.fittedNoteIDs.insert(id) }
                }
            }
            next.basis = basis
            for (id, vector) in vectors {
                try Task.checkCancellation()
                guard let revisionID = revisions[id] else { continue }
                next.points[id] = SemanticGraphPoint(revisionID: revisionID, position: basis.project(vector))
                next.signatures[id] = input.signatures[id]
            }
        }
        return next
    }
}

extension MioStore {
    // Hold the store lock while reading the ready jobs and their vectors so
    // a concurrent publish, move or edit cannot mix two source revisions.
    fileprivate func semanticGraphInput(modelID: String, revisions: [String: String], cached: [String: String]) throws
        -> (signatures: [String: String], fragments: [String: [Data]]) {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        let ready = try db.rows("""
            SELECT jobs.note_id, jobs.signature, json_extract(notes.json, '$.revision_id') AS revision_id
            \(liveSourceJobJoin)
            JOIN entities notes ON notes.kind='note' AND notes.id=jobs.note_id
            WHERE jobs.state='ready' AND jobs.model_id=?
            ORDER BY jobs.note_id
            """, [modelID])
        var signatures: [String: String] = [:]
        var changed: [String] = []
        for row in ready {
            guard let id = row["note_id"], let revision = revisions[id], revision == row["revision_id"],
                  let signature = row["signature"] else { continue }
            signatures[id] = signature
            if cached[id] != signature { changed.append(id) }
        }

        var fragments: [String: [Data]] = [:]
        let byteCount = SemanticGraphBasis.dimensions * MemoryLayout<Float>.size
        for start in stride(from: 0, to: changed.count, by: 500) {
            try Task.checkCancellation()
            let ids = changed[start..<min(start + 500, changed.count)]
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try db.vectorRows("""
                SELECT note_id, embedding, json_extract(json, '$.indexed_note_revision')
                FROM source_fragments
                JOIN source_index_members members USING (note_id, space_id)
                WHERE current=1 AND model_id=? AND json_extract(json, '$.extractor')=?
                  AND typeof(embedding)='blob' AND length(embedding)=\(byteCount) AND note_id IN (\(marks))
                ORDER BY note_id, id
                """, [modelID, MioDocumentExtraction.version] + ids)
            for (id, bytes, revision) in rows where revisions[id] == revision {
                fragments[id, default: []].append(bytes)
            }
        }
        return (signatures, fragments)
    }
}

private struct SemanticGraphBasis: Sendable {
    static let dimensions = 768
    let mean: [Float]
    private(set) var axes: [[Float]]

    static func centroid(_ fragments: [Data]) -> [Float]? {
        var sum = [Float](repeating: 0, count: dimensions)
        var vector = sum
        for fragment in fragments where fragment.count == dimensions * MemoryLayout<Float>.size {
            _ = vector.withUnsafeMutableBytes { fragment.copyBytes(to: $0) }
            guard vector.allSatisfy(\.isFinite) else { continue }
            for i in sum.indices { sum[i] += vector[i] }
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-6 else { return nil }
        return sum.map { $0 / norm }
    }

    static func fit(_ vectors: [[Float]]) throws -> Self {
        let d = dimensions
        var mean = [Float](repeating: 0, count: d)
        for vector in vectors {
            for i in mean.indices { mean[i] += vector[i] }
        }
        let count = vectors.count
        for i in mean.indices { mean[i] /= Float(count) }
        if count == 1 { return Self(mean: mean, axes: []) }
        var samples = [Float](repeating: 0, count: count * d)
        for (row, vector) in vectors.enumerated() {
            if row.isMultiple(of: 64) { try Task.checkCancellation() }
            for i in mean.indices { samples[row * d + i] = vector[i] - mean[i] }
        }

        var covariance = [Float](repeating: 0, count: d * d)
        cblas_ssyrk(CblasColMajor, CblasLower, CblasNoTrans, Int32(d), Int32(count), 1,
                    samples, Int32(d), 0, &covariance, Int32(d))
        try Task.checkCancellation()
        // ssyev returns eigenvectors in column-major order, smallest first.
        var job = CChar(86), lower = CChar(76) // V, L
        var dimension = Int32(d), leading = Int32(d), info: Int32 = 0
        var values = [Float](repeating: 0, count: d)
        var query: Float = 0, workspaceSize: Int32 = -1
        ssyev_(&job, &lower, &dimension, &covariance, &leading, &values, &query, &workspaceSize, &info)
        guard info == 0, query.isFinite, query >= 1 else {
            throw MioError("semantic_graph_pca", "Could not prepare the semantic graph projection.")
        }
        workspaceSize = Int32(query.rounded(.up))
        var workspace = [Float](repeating: 0, count: Int(workspaceSize))
        ssyev_(&job, &lower, &dimension, &covariance, &leading, &values, &workspace, &workspaceSize, &info)
        guard info == 0 else {
            throw MioError("semantic_graph_pca", "Could not calculate the semantic graph projection.")
        }
        try Task.checkCancellation()
        let threshold = max(1e-8, values[d - 1] * 1e-6)
        let axes = (1...3).compactMap { index -> [Float]? in
            guard values[d - index] > threshold else { return nil }
            let start = (d - index) * d
            let axis = Array(covariance[start..<(start + d)])
            // Eigenvector signs are arbitrary. Orient each axis consistently.
            let anchor = axis.max(by: { abs($0) < abs($1) }) ?? 0
            return anchor < 0 ? axis.map { -$0 } : axis
        }
        return Self(mean: mean, axes: axes)
    }

    mutating func addDirection(for vector: [Float]) -> Bool {
        var residual = zip(vector, mean).map(-)
        for axis in axes {
            let component = zip(residual, axis).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            for i in residual.indices { residual[i] -= component * axis[i] }
        }
        let norm = sqrt(residual.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-4 else { return false }
        axes.append(residual.map { $0 / norm })
        return true
    }

    func project(_ vector: [Float]) -> SIMD3<Float> {
        var position = SIMD3<Float>.zero
        for (index, axis) in axes.enumerated() {
            var component: Float = 0
            for i in mean.indices { component += (vector[i] - mean[i]) * axis[i] }
            position[index] = component
        }
        return position
    }
}
