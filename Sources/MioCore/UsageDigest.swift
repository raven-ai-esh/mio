import Foundation

/// Owner-local telemetry for the scheduled review. Only aggregates cross the
/// process boundary to a harness. The SQLite connection cannot write memory.
public enum MioUsageDigest {
    public static func read(directory: URL, from: Date, until: Date) throws -> JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.string(from: from), end = formatter.string(from: until)
        let database = directory.appendingPathComponent(MioStore.databaseName)
        let rows: [[String: String]]
        if FileManager.default.fileExists(atPath: database.path) {
            let db = try SQLite(path: database.path, readOnly: true)
            rows = try db.rows("""
                SELECT json_extract(json,'$.session_id') AS session,
                       json_extract(json,'$.actor') AS profile,
                       json_extract(json,'$.method') AS method,
                       json_extract(json,'$.started_at') AS started,
                       json_extract(json,'$.finished_at') AS finished,
                       json_extract(json,'$.outcome') AS outcome,
                       json_extract(json,'$.error_code') AS error_code,
                       json_extract(json,'$.duration_ms') AS duration,
                       json_extract(json,'$.observed_duration_ms') AS observed_duration,
                       json_extract(json,'$.adapter_delivery') AS delivery,
                       json_extract(json,'$.last_delivery_at') AS delivered_at,
                       json_extract(json,'$.result_count') AS result_count,
                       json_extract(json,'$.result_refs') AS result_refs,
                       json_extract(json,'$.request.kind') AS read_kind,
                       json_extract(json,'$.request.id') AS read_id,
                       json_extract(json,'$.request.scope') AS search_scope,
                       json_extract(json,'$.request.query_hash') AS query_hash,
                       json_extract(json,'$.receipt.operation_id') AS receipt,
                       json_extract(json,'$.replayed') AS replayed
                FROM entities
                WHERE kind='interaction' AND json_extract(json,'$.integrity_state')='valid'
                  AND json_extract(json,'$.started_at')>=? AND json_extract(json,'$.started_at')<?
                ORDER BY started, id
                """, [start, end])
        } else {
            rows = []
        }

        let calls = rows.compactMap { Call($0, before: until, formatter: formatter) }
        let searches = calls.filter { $0.method == "search" && $0.outcome == "success" }
        let noteWrites = calls.filter {
            ($0.method == "note.create" || $0.method == "note.update")
                && $0.outcome == "success" && $0.committed && !$0.replayed
        }
        return .object([
            "schema_version": .number(1),
            "window_start": .string(start),
            "window_end": .string(end),
            "calls": number(calls.count),
            "sessions": number(Set(calls.compactMap(\.session)).count),
            "profiles": number(Set(calls.compactMap(\.profile)).count),
            "outcomes": counts(calls.map(\.outcome)),
            "error_codes": counts(calls.compactMap(\.errorCode)),
            "adapter_delivery": counts(calls.map(\.delivery)),
            "by_method": .object(Dictionary(grouping: calls, by: \.method).mapValues(methodMetrics)),
            "searches_by_scope": counts(searches.map(\.scope)),
            "searches_without_results": number(searches.filter { $0.resultCount == 0 }.count),
            "searches_followed_by_read": number(searchesFollowedByRead(calls)),
            "repeated_search_terms_within_ten_minutes": number(repeatedSearches(searches)),
            "committed_note_versions": number(noteWrites.count),
            "committed_note_versions_with_source_refs": number(noteWrites.filter(\.hasSources).count),
            "replayed_calls": number(calls.filter(\.replayed).count)
        ])
    }

    private static func number(_ value: Int) -> JSONValue { .number(Double(value)) }

    private static func counts(_ values: [String]) -> JSONValue {
        .object(Dictionary(grouping: values, by: { $0 }).mapValues { number($0.count) })
    }

    private static func methodMetrics(_ calls: [Call]) -> JSONValue {
        let times = calls.compactMap(\.duration).sorted()
        func percentile(_ fraction: Double) -> JSONValue {
            guard !times.isEmpty else { return .null }
            return .number(times[Int(ceil(Double(times.count) * fraction)) - 1])
        }
        return .object([
            "calls": number(calls.count),
            "outcomes": counts(calls.map(\.outcome)),
            "timed": number(times.count),
            "p50_ms": percentile(0.5),
            "p95_ms": percentile(0.95),
            "max_ms": percentile(1),
            "total_ms": .number(times.reduce(0, +))
        ])
    }

    private static func searchesFollowedByRead(_ calls: [Call]) -> Int {
        var count = 0
        for session in Dictionary(grouping: calls.filter { $0.session != nil }, by: \.session).values {
            let searches = session.filter {
                $0.method == "search" && $0.scope != "history" && $0.outcome == "success" && !$0.refs.isEmpty
            }
            let reads = session.filter { $0.method == "read" && $0.readID != nil && $0.outcome == "success" }
            var matched = Set<Int>()
            for read in reads {
                if let index = searches.lastIndex(where: { search in
                    guard let finish = search.finished, let id = read.readID else { return false }
                    let delay = read.started.timeIntervalSince(finish)
                    return (0...600).contains(delay) && search.refs.contains(id)
                }) {
                    matched.insert(index)
                }
            }
            count += matched.count
        }
        return count
    }

    private static func repeatedSearches(_ searches: [Call]) -> Int {
        var count = 0
        for session in Dictionary(grouping: searches.filter { $0.session != nil }, by: \.session).values {
            var previous: [String: Date] = [:]
            for search in session {
                guard let hash = search.queryHash else { continue }
                let key = search.scope + ":" + hash
                if let last = previous[key], search.started.timeIntervalSince(last) <= 600 { count += 1 }
                previous[key] = search.started
            }
        }
        return count
    }

    private struct Call {
        let session: String?
        let profile: String?
        let method: String
        let started: Date
        let finished: Date?
        let outcome: String
        let duration: Double?
        let errorCode: String?
        let delivery: String
        let resultCount: Int
        let refs: Set<String>
        let readID: String?
        let scope: String
        let queryHash: String?
        let hasSources: Bool
        let committed: Bool
        let replayed: Bool

        init?(_ row: [String: String], before until: Date, formatter: ISO8601DateFormatter) {
            guard let start = row["started"].flatMap(formatter.date(from:)) else { return nil }
            started = start
            session = row["session"]
            profile = row["profile"]
            method = Self.knownMethods.contains(row["method"] ?? "") ? row["method"]! : "other"
            let end = row["finished"].flatMap(formatter.date(from:))
            let interruptedAt = row["observed_duration"].flatMap(Double.init).flatMap { ms in
                ms.isFinite && ms >= 0 ? start.addingTimeInterval(ms / 1000) : nil
            }
            let observedEnd = end ?? (row["outcome"] == "interrupted" ? interruptedAt : nil)
            let terminal = observedEnd.map { $0 < until } ?? false
            finished = terminal ? end : nil
            let state = row["outcome"] ?? ""
            outcome = terminal && ["success", "error", "revision_conflict", "interrupted"].contains(state)
                ? state : "in_progress"
            duration = terminal ? row["duration"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
            errorCode = terminal ? row["error_code"].map { Self.knownErrors.contains($0) ? $0 : "other" } : nil
            let reported = row["delivery"] ?? ""
            let deliveredAt = row["delivered_at"].flatMap(formatter.date(from:))
            delivery = terminal && (deliveredAt.map { $0 < until } ?? false)
                && ["stdout_written", "stdout_write_failed"].contains(reported) ? reported : "not_observed"
            resultCount = terminal ? row["result_count"].flatMap(Int.init) ?? 0 : 0
            let references = terminal ? row["result_refs"].flatMap { try? JSONValue.decode(Data($0.utf8)) }?.arrayValue ?? [] : []
            refs = Set(references.filter { $0["kind"].stringValue != "event" }.flatMap { reference in
                ["id", "note_id", "source_id"].compactMap { reference[$0].stringValue }
            })
            readID = ["note", "source"].contains(row["read_kind"] ?? "") ? row["read_id"] : nil
            let requestedScope = row["search_scope"] ?? "all"
            scope = ["all", "notes", "files", "history"].contains(requestedScope) ? requestedScope : "other"
            queryHash = row["query_hash"]
            hasSources = references.contains { !$0["source_ids"].arrayValue.isEmpty }
            committed = terminal && row["receipt"] != nil
            replayed = terminal && row["replayed"] == "1"
        }

        private static let knownMethods: Set<String> = ["search", "read", "note.create", "note.update",
            "note.delete", "note.restore", "note.resolve", "note.history", "link.create", "link.delete"]
        private static let knownErrors: Set<String> = ["invalid_params", "invalid_revision", "invalid_source", "forbidden",
            "unauthorized", "not_found", "revision_conflict", "idempotency_mismatch", "owner_process_terminated",
            "cancelled", "operation_failed", "session_closed", "database_error", "timeout", "source_purged"]
    }
}
