import Foundation

extension MioStore {
    /// Called with the store lock held, outside a SQLite transaction. The
    /// request's durable start is already recorded; all data/ACL reads happen
    /// later in perform(), after inference and fresh authorization.
    func prepareSearchEncoding(_ method:String,_ params:[String:JSONValue],_ context:AccessContext) throws -> Result<MioSemanticQuery,MioError>? {
        guard method == "search",params["as_of"] == nil,["all","notes","files"].contains(params.string("scope","all")),retrievalMode != .bm25,let encoder=semanticQueryEncoder else { return nil }
        let query=params.string("query").trimmingCharacters(in:.whitespacesAndNewlines)
        guard query.rangeOfCharacter(from:.alphanumerics) != nil else { return nil }
        let access=try scope(context)
        try authorizeMethod(method,params,access)
        if let spaces=params["space_ids"],!spaces.arrayValue.isEmpty,access.readable.isDisjoint(with:spaces.arrayValue.compactMap(\.stringValue)) { return nil }
        lock.unlock()
        defer { lock.lock() }
        do {
            try Task.checkCancellation()
            let value=try encoder(query)
            try Task.checkCancellation()
            return .success(value)
        } catch is CancellationError { throw CancellationError() }
        catch { return .failure(error as? MioError ?? MioError("model_failed",error.localizedDescription)) }
    }
}
