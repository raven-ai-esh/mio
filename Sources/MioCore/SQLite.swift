import Foundation
import CSQLite

final class SQLite {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw MioError("database_open", "Cannot open Mio database") }
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=FULL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA secure_delete=ON")
    }
    deinit { sqlite3_close_v2(handle) }
    func exec(_ sql: String, _ bindings: [String] = []) throws { _ = try rows(sql, bindings) }
    func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (i, value) in bindings.enumerated() { guard sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) == SQLITE_OK else { throw failure() } }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, i))
                if let bytes = sqlite3_column_text(statement, i) { row[key] = String(cString: bytes) }
            }
            result.append(row)
        }
    }
    func failure() -> MioError { MioError("database_error", String(cString: sqlite3_errmsg(handle))) }
    func vectorRows(_ sql: String, _ bindings: [String]) throws -> [(String,Data,String)] {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil)==SQLITE_OK else { throw failure() }
        defer{sqlite3_finalize(statement)}
        for (i,value) in bindings.enumerated() { guard sqlite3_bind_text(statement,Int32(i+1),value,-1,transient)==SQLITE_OK else { throw failure() } }
        var result:[(String,Data,String)]=[]
        while true {
            let code=sqlite3_step(statement);if code==SQLITE_DONE { return result };guard code==SQLITE_ROW else { throw failure() }
            guard let json=sqlite3_column_text(statement,0),let model=sqlite3_column_text(statement,2) else { continue }
            let blob=sqlite3_column_blob(statement,1)
            let data=blob.map { Data(bytes:$0,count:Int(sqlite3_column_bytes(statement,1))) } ?? Data()
            result.append((String(cString:json),data,String(cString:model)))
        }
    }
    func bindVector(_ sql: String, _ bindings: [String], vector: [Float]) throws {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil)==SQLITE_OK else { throw failure() }
        defer{sqlite3_finalize(statement)}
        for (i,value) in bindings.enumerated() { guard sqlite3_bind_text(statement,Int32(i+1),value,-1,transient)==SQLITE_OK else { throw failure() } }
        let code=vector.withUnsafeBytes { sqlite3_bind_blob(statement,Int32(bindings.count+1),$0.baseAddress,Int32($0.count),transient) }
        guard code==SQLITE_OK,sqlite3_step(statement)==SQLITE_DONE else { throw failure() }
    }
    func transaction<T>(_ block: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try block(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
}
