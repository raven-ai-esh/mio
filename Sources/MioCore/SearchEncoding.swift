import Foundation

struct PreparedSearchEncoding {
    let result: Result<MioSemanticQuery, MioError>
    let milliseconds: Double
}

struct SearchTiming {
    private var start = DispatchTime.now().uptimeNanoseconds
    private var stages: [String: Double] = [:]

    mutating func mark(_ stage: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        stages[stage, default: 0] += Double(now - start) / 1_000_000
        start = now
    }

    var json: JSONValue { .object(stages.mapValues(JSONValue.number)) }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

extension MioStore {
    /// Called with the store lock held, outside a SQLite transaction. The
    /// request's durable start is already recorded; all data/ACL reads happen
    /// later in perform(), after inference and fresh authorization.
    func prepareSearchEncoding(_ method:String,_ params:[String:JSONValue],_ context:AccessContext) throws -> PreparedSearchEncoding? {
        guard method == "search", !["as_of", "from", "to", "cursor"].contains(where: { params[$0] != nil }),
              ["all", "notes", "files"].contains(params.string("scope", "all")),
              retrievalMode != .bm25, let encoder = semanticQueryEncoder else { return nil }
        let query=params.string("query").trimmingCharacters(in:.whitespacesAndNewlines)
        guard query.rangeOfCharacter(from:.alphanumerics) != nil else { return nil }
        let access=try scope(context)
        try authorizeMethod(method,params,access)
        if let spaces=params["space_ids"],!spaces.arrayValue.isEmpty,access.readable.isDisjoint(with:spaces.arrayValue.compactMap(\.stringValue)) { return nil }
        lock.unlock()
        defer { lock.lock() }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let value=try encoder(query)
            try Task.checkCancellation()
            return PreparedSearchEncoding(result: .success(value), milliseconds: SearchTiming.milliseconds(since: started))
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure = error as? MioError ?? MioError("model_failed", error.localizedDescription)
            return PreparedSearchEncoding(result: .failure(failure), milliseconds: SearchTiming.milliseconds(since: started))
        }
    }
}
