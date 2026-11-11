import XCTest
import simd
@testable import MioCore

final class SemanticGraphLayoutTests: XCTestCase {
    private let model = "semantic-graph-test"

    func testEditAndNewNoteUpdateOnlyTheirOwnPoints() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try store.execute("space.create", params: ["name": .string("Research")])["id"]
        let axes = ["ocean": vector(0), "current": vector(0, secondary: 0.08),
                    "wood": vector(1), "sky": vector(2), "garden": vector(3)]
        var revisions: [String: String] = [:]
        var noteIDs: [String: String] = [:]
        for topic in axes.keys.sorted() {
            let created = try createNote(store, in: space, title: topic, text: topic)
            let id = try XCTUnwrap(created["id"].stringValue)
            revisions[id] = try XCTUnwrap(created["revision_id"].stringValue)
            noteIDs[topic] = id
        }

        let initial = try SemanticGraphLayout().refreshed(from: store, modelID: model, revisions: revisions)
        XCTAssertTrue(initial.points.isEmpty)
        try index(store, vectors: axes)
        let before = try initial.refreshed(from: store, modelID: model, revisions: revisions)
        XCTAssertEqual(before.points.count, 5)
        let ocean = try XCTUnwrap(noteIDs["ocean"])
        let current = try XCTUnwrap(noteIDs["current"])
        let garden = try XCTUnwrap(noteIDs["garden"])
        let a = try XCTUnwrap(before.points[ocean]?.position)
        let b = try XCTUnwrap(before.points[current]?.position)
        let c = try XCTUnwrap(before.points[garden]?.position)
        XCTAssertLessThan(simd_distance(a, b), 0.15)
        XCTAssertGreaterThan(simd_distance(a, c), 1)

        let edited = try store.execute("note.update", params: [
            "note_id": .string(ocean), "expected_revision": .string(revisions[ocean]!),
            "body": .string("orchard")
        ])
        let added = try createNote(store, in: space, title: "Flowers", text: "orchard")
        let addedID = try XCTUnwrap(added["id"].stringValue)
        revisions[ocean] = try XCTUnwrap(edited["revision_id"].stringValue)
        revisions[addedID] = try XCTUnwrap(added["revision_id"].stringValue)
        let pending = try before.refreshed(from: store, modelID: model, revisions: revisions)
        XCTAssertNil(pending.points[ocean])
        XCTAssertNil(pending.points[addedID])
        XCTAssertEqual(pending.points, before.points.filter { $0.key != ocean })

        try index(store, vectors: ["orchard": vector(3)])
        let after = try pending.refreshed(from: store, modelID: model, revisions: revisions)
        XCTAssertEqual(after.points.count, 6)
        XCTAssertEqual(after.points[ocean]?.revisionID, edited["revision_id"].stringValue)
        XCTAssertEqual(after.points[ocean]?.position, c)
        XCTAssertEqual(after.points[addedID]?.position, c)
        XCTAssertEqual(after.points.filter { $0.key != ocean && $0.key != addedID }, pending.points)
    }

    func testSparseMapAddsDirectionsWithoutMovingEarlierPoints() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try store.execute("space.create", params: ["name": .string("Sparse")])["id"]
        var revisions: [String: String] = [:]
        var layout = SemanticGraphLayout()
        for direction in 0..<4 {
            let text = "topic \\(direction)"
            let note = try createNote(store, in: space, title: text, text: text)
            let id = try XCTUnwrap(note["id"].stringValue)
            revisions[id] = try XCTUnwrap(note["revision_id"].stringValue)
            try index(store, vectors: [text: vector(direction)])
            let refreshed = try layout.refreshed(from: store, modelID: model, revisions: revisions)
            XCTAssertEqual(refreshed.points.count, direction + 1)
            XCTAssertEqual(refreshed.points.filter { $0.key != id }, layout.points)
            let newPoint = try XCTUnwrap(refreshed.points[id]?.position)
            if direction > 0 {
                XCTAssertTrue(layout.points.values.allSatisfy { simd_distance($0.position, newPoint) > 1 })
            }
            layout = refreshed
        }
    }

    func testFragmentCentroidAndRevisionModelAndSpaceEligibility() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try store.execute("space.create", params: ["name": .string("Local")])["id"]
        let other = try store.execute("space.create", params: ["name": .string("Retired")])["id"]
        let longBody = String(repeating: "Long synthetic passage. ", count: 150)
        let long = try createNote(store, in: space, title: "Long note", text: longBody)
        let short = try createNote(store, in: space, title: "Centroid", text: "Comparable topic")
        let retired = try createNote(store, in: other, title: "Retired", text: "Retired topic")
        let revisions = Dictionary(uniqueKeysWithValues: [long, short, retired].map {
            ($0["id"].stringValue!, $0["revision_id"].stringValue!)
        })
        let longID = try XCTUnwrap(long["id"].stringValue)
        let shortID = try XCTUnwrap(short["id"].stringValue)
        let retiredID = try XCTUnwrap(retired["id"].stringValue)
        let chunks = MioDocumentExtraction.textChunks(longBody).count
        XCTAssertGreaterThan(chunks, 1)
        while let job = try store.nextSourceIndexJob(modelID: model) {
            let documents = try store.sourceDocuments(job: job)
            let id = job["note"]["id"].stringValue
            let embeddings: [[Float]]
            if id == longID {
                XCTAssertEqual(documents.count, chunks)
                embeddings = documents.indices.map { vector($0 == 0 ? 0 : 1) }
            } else {
                embeddings = documents.map { _ in id == shortID ? vector(0, secondary: Float(chunks - 1)) : vector(2) }
            }
            XCTAssertTrue(try store.publishSourceIndex(job: job, documents: documents, embeddings: embeddings))
        }
        let result = try SemanticGraphLayout().refreshed(from: store, modelID: model, revisions: revisions)
        let a = try XCTUnwrap(result.points[longID]?.position)
        let b = try XCTUnwrap(result.points[shortID]?.position)
        XCTAssertLessThan(simd_distance(a, b), 1e-5)

        _ = try store.execute("space.delete", params: ["space_id": other])
        let after = try result.refreshed(from: store, modelID: model, revisions: revisions)
        XCTAssertNil(after.points[retiredID])
        XCTAssertNotNil(after.points[longID])
        let wrongRevision = try after.refreshed(from: store, modelID: model, revisions: [longID: "stale-revision"])
        XCTAssertTrue(wrongRevision.points.isEmpty)
        let wrongModel = try after.refreshed(from: store, modelID: "another-model", revisions: revisions)
        XCTAssertTrue(wrongModel.points.isEmpty)
        let empty = try after.refreshed(from: store, modelID: model, revisions: [:])
        XCTAssertTrue(empty.points.isEmpty)
    }

    private func makeStore() throws -> (MioStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mio-semantic-graph-" + UUID().uuidString)
        return (try MioStore(directory: directory), directory)
    }

    private func createNote(_ store: MioStore, in space: JSONValue, title: String, text: String) throws -> JSONValue {
        try store.execute("note.create", params: ["space_id": space, "title": .string(title), "body": .string(text)])
    }

    private func index(_ store: MioStore, vectors: [String: [Float]]) throws {
        while let job = try store.nextSourceIndexJob(modelID: model) {
            let documents = try store.sourceDocuments(job: job)
            let embeddings = try documents.map { try XCTUnwrap(vectors[$0["text"].stringValue ?? ""]) }
            XCTAssertTrue(try store.publishSourceIndex(job: job, documents: documents, embeddings: embeddings))
        }
    }

    private func vector(_ primary: Int, secondary: Float = 0) -> [Float] {
        var result = [Float](repeating: 0, count: 768)
        let norm = sqrt(1 + secondary * secondary)
        result[primary] = 1 / norm
        if secondary != 0 { result[1] = secondary / norm }
        return result
    }
}
