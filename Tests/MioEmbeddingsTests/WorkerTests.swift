import XCTest
import Foundation
import MioCore
import MioEmbeddings

final class WorkerTests: XCTestCase {
    private var directory:URL!
    override func setUpWithError() throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent("mio-worker-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func helper(_ body:String) throws -> URL {
        let url=directory.appendingPathComponent("helper")
        try ("#!/usr/bin/python3\n"+body).write(to:url,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url
    }
    func testRepeatedPipeRepliesPreserveDataSliceOffsets() throws {
        let path=try helper("""
        import json,sys
        print(json.dumps({'state':'ready','model':'embeddinggemma2-q8-v1','dimensions':768}),flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            print(json.dumps({'id':r['id'],'vectors':[[1]+[0]*767]}),flush=True)
        """)
        let worker=MioEmbeddingWorker(executable:path,modelDirectory:directory,timeout:2);defer{worker.stop()}
        for _ in 0..<5 { let q=try worker.query("fixture");XCTAssertEqual(q.values.count,768);XCTAssertEqual(q.values[0],1) }
    }
    func testTimeoutIsAnExplicitErrorAndFreshProcessCanRecover() throws {
        let path=try helper("""
        import json,sys,time
        print(json.dumps({'state':'ready','model':'embeddinggemma2-q8-v1','dimensions':768}),flush=True)
        for line in sys.stdin:time.sleep(10)
        """)
        let worker=MioEmbeddingWorker(executable:path,modelDirectory:directory,timeout:0.3);defer{worker.stop()}
        XCTAssertThrowsError(try worker.query("fixture")){XCTAssertEqual(($0 as? MioError)?.code,"embedding_timeout")}
        _=try helper("""
        import json,sys
        print(json.dumps({'state':'ready','model':'embeddinggemma2-q8-v1','dimensions':768}),flush=True)
        for line in sys.stdin:
            r=json.loads(line);print(json.dumps({'id':r['id'],'vectors':[[1]+[0]*767]}),flush=True)
        """)
        XCTAssertEqual(try worker.query("retry").values[0],1)
    }
    func testManifestChecksSizeAndBytesBeforeAcceptingAModel() throws {
        let manifest=try MioModelManifest.bundled()
        XCTAssertEqual(manifest.files.count,11);XCTAssertEqual(manifest.dimensions,768)
        let file=try XCTUnwrap(manifest.files.first)
        let target=directory.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("wrong".utf8).write(to:target)
        XCTAssertFalse(try manifest.valid(file,in:directory));XCTAssertThrowsError(try manifest.verify(in:directory))
    }
}
