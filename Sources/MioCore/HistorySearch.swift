import Foundation

extension MioStore {
    static func historyTimeSQL(_ json: String) -> String {
        let timestamp = "json_extract(\(json),'$.timestamp')"
        return "CASE WHEN \(timestamp) GLOB '????-??-??T??:??:??*' OR \(timestamp) GLOB '????-??-?? ??:??:??*' THEN CAST(round((julianday(\(timestamp))-2440587.5)*86400000) AS INTEGER) END"
    }

    private struct HistoryCursor: Codable {
        let time: Int64
        let id: String
        let snapshotEventID: String
    }

    func rangedHistorySearch(_ params: [String: JSONValue], _ scope: Scope) throws -> JSONValue {
        let from = try historyTime(params, "from"), to = try historyTime(params, "to")
        let asOf = try historyTime(params, "as_of")
        guard from != nil || to != nil else {
            throw MioError.invalidArgument("from", reason: "missing", message: "A history range requires from or to.")
        }
        if let from, let to, from >= to { throw MioError.invalidArgument("to", message: "to must be later than from.") }
        let cursor: HistoryCursor?
        if let field = params["cursor"] {
            guard let text = field.stringValue else {
                throw MioError.invalidArgument("cursor", reason: "wrong_type", message: "cursor must be a string.")
            }
            guard text.utf8.count <= 1024,
                  let bytes = Data(base64Encoded: text),
                  let decoded = try? JSONDecoder().decode(HistoryCursor.self, from: bytes),
                  !decoded.id.isEmpty, decoded.id.utf8.count <= 256,
                  !decoded.snapshotEventID.isEmpty, decoded.snapshotEventID.utf8.count <= 256 else {
                throw MioError.invalidArgument("cursor", message: "Invalid history cursor.")
            }
            cursor = decoded
        } else {
            cursor = nil
        }
        var spaces = scope.readable
        if let requested = params["space_ids"], !requested.arrayValue.isEmpty {
            spaces.formIntersection(requested.arrayValue.compactMap(\.stringValue))
        }
        let budget = min(100_000, max(1, params["max_chars"]?.intValue ?? 12_000))
        let limit = min(100, max(1, params["limit"]?.intValue ?? 20))
        var response: [String: JSONValue] = [
            "results": .array([]), "returned_chars": .number(0), "truncated": .bool(false),
            "next_cursor": .null, "from": params["from"] ?? .null, "to": params["to"] ?? .null,
            "as_of": params["as_of"] ?? .null, "order": .string("timestamp_asc"),
            "search_mode": .string("fts5_lexical"),
            "history_boundary": .string("Mio memory operation traces only")
        ]
        guard !spaces.isEmpty, let snapshot = try historySnapshot(cursor, scope) else { return .object(response) }

        let words = Array(params.string("query").components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(32))
        let time = Self.historyTimeSQL("e.json")
        let marks = Array(repeating: "?", count: spaces.count).joined(separator: ",")
        let readable = scope.readable.sorted()
        let (visibility, visibilityBindings) = eventVisibilitySQL(scope, json: "e.json")
        var sql = """
            SELECT e.json AS event, \(time) AS time_ms, json_extract(session.json,'$.completeness') AS completeness
            FROM entities e
            JOIN entities session ON session.kind='session' AND session.id=json_extract(e.json,'$.session_id')
            JOIN search_documents document ON document.kind='event' AND document.id=e.id
            """
        if !words.isEmpty { sql += " JOIN search_index ON search_index.rowid=document.fts_rowid" }
        sql += """
             WHERE e.kind='event' AND \(time) IS NOT NULL
               AND e.rowid \(scope.human ? "<=" : "<") CAST(? AS INTEGER)
               AND coalesce(json_type(e.json,'$.purged')='true',0)=0
               AND coalesce(json_type(session.json,'$.deleted')='true',0)=0
               AND (json_extract(e.json,'$.space_id') IN (\(marks))
                    OR EXISTS (SELECT 1 FROM json_each(e.json,'$.target_space_ids') t WHERE t.value IN (\(marks))))
               AND (\(visibility))
            """
        var bindings = [snapshot.rowID] + spaces.sorted() + spaces.sorted() + visibilityBindings
        if !scope.human {
            sql += " AND json_extract(e.json,'$.space_id') IN (" + Array(repeating: "?", count: readable.count).joined(separator: ",") + ")"
            bindings += readable
        }
        if !(params["include_legacy_history"]?.boolValue ?? false) {
            sql += " AND json_extract(session.json,'$.source')=?"
            bindings.append(Self.interactionSource)
        }
        if !words.isEmpty {
            sql += " AND search_index MATCH ?"
            bindings.append(words.map { "\"\($0)\"*" }.joined(separator: " AND "))
        }
        if let from {
            sql += " AND \(time)>=CAST(? AS INTEGER)"
            bindings.append(String(from))
        }
        if let to {
            sql += " AND \(time)<CAST(? AS INTEGER)"
            bindings.append(String(to))
        }
        if let asOf {
            sql += " AND \(time)<=CAST(? AS INTEGER)"
            bindings.append(String(asOf))
        }
        if let cursor {
            sql += " AND (\(time),e.id)>(CAST(? AS INTEGER),?)"
            bindings += [String(cursor.time), cursor.id]
        }
        sql += " ORDER BY \(time),e.id LIMIT ?"
        bindings.append(String(limit + 1))

        let rows = try db.rows(sql, bindings)
        var results: [JSONValue] = [], used = 0, last: HistoryCursor?
        for row in rows {
            guard results.count < limit, used < budget else { break }
            let event = try decode(row["event"]!)
            let snippet = String(excerpt(event["text"].stringValue ?? "", words: words, max: 1200).prefix(budget - used))
            var hit: [String: JSONValue] = [
                "kind": .string("event"), "id": event["id"], "title": event["tool_name"].stringValue.map(JSONValue.string)
                    ?? event["role"].stringValue.map(JSONValue.string) ?? .string("Event"),
                "snippet": .string(snippet), "timestamp": event["timestamp"],
                "status": event["outcome"].stringValue.map(JSONValue.string) ?? .string("unknown"),
                "completeness": .string(row["completeness"] ?? "partial")
            ]
            for key in ["space_id", "session_id", "source_id", "role", "tool_name", "outcome", "phase",
                        "interaction_id", "method", "replayed"] { hit[key] = event[key] }
            results.append(.object(hit))
            used += snippet.count
            last = HistoryCursor(time: Int64(row["time_ms"]!)!, id: event["id"].stringValue!, snapshotEventID: snapshot.id)
        }
        response["results"] = .array(results)
        response["returned_chars"] = .number(Double(used))
        if rows.count > results.count, let last {
            response["truncated"] = .bool(true)
            response["next_cursor"] = .string(try JSONEncoder().encode(last).base64EncodedString())
        }
        return .object(response)
    }

    private func historySnapshot(_ cursor: HistoryCursor?, _ scope: Scope) throws -> (id: String, rowID: String)? {
        // The first request's START bounds agent pagination before the page can
        // add its own journal entries. Keep the event ID as a local row anchor.
        let firstStartID = try activeInteractionID.flatMap { try entity("interaction", $0)?["start_event_id"].stringValue }
        if let id = cursor?.snapshotEventID ?? firstStartID {
            var sql = "SELECT rowid FROM entities WHERE kind='event' AND id=?"
            var bindings = [id]
            if !scope.human {
                sql += " AND json_extract(json,'$.actor')=? AND json_extract(json,'$.method')='search' AND json_extract(json,'$.phase')='start'"
                bindings.append(scope.actor)
            }
            guard let rowID = try db.rows(sql, bindings).first?["rowid"] else {
                throw MioError.invalidArgument("cursor", message: "History cursor has expired. Start with a fresh query.")
            }
            return (id, rowID)
        }
        guard scope.human else { throw MioError("operation_failed", "Unable to establish the history snapshot.") }
        guard let row = try db.rows("SELECT id,rowid FROM entities WHERE kind='event' ORDER BY rowid DESC LIMIT 1").first else { return nil }
        return (row["id"]!, row["rowid"]!)
    }

    private static let historyTimestampPattern = #"\A[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\z"#

    private func historyTime(_ params: [String: JSONValue], _ key: String) throws -> Int64? {
        guard let field = params[key] else { return nil }
        let message = "\(key) must be an ISO 8601 timestamp with Z or an offset such as +03:00."
        guard let text = field.stringValue else { throw MioError.invalidArgument(key, reason: "wrong_type", message: message) }
        guard text.utf8.count <= 64, text.range(of: Self.historyTimestampPattern, options: .regularExpression) != nil else {
            throw MioError.invalidArgument(key, message: message)
        }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        let day = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        let formatter = ISO8601DateFormatter()
        if text.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        guard day.isValidDate(in: Calendar(identifier: .iso8601)), let date = formatter.date(from: text) else {
            throw MioError.invalidArgument(key, message: message)
        }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
