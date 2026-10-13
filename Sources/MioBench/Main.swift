import Foundation
import CryptoKit
import Darwin
import MioCore
import MioBridge

func hash(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
func benchTick() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func peakRSS() -> Int { var usage = rusage(); getrusage(RUSAGE_SELF,&usage); return Int(usage.ru_maxrss) }
func save(_ value: JSONValue, _ path: URL) throws { try value.encoded().write(to:path,options:.atomic) }
func read(_ path: URL) throws -> JSONValue { try JSONValue.decode(Data(contentsOf:path)) }
func flag(_ name: String, default fallback: String = "") -> String { guard let i = CommandLine.arguments.firstIndex(of:name), i+1 < CommandLine.arguments.count else { return fallback }; return CommandLine.arguments[i+1] }
func lineFile(_ path: URL, count: Int, make: (Int)->JSONValue) throws {
    _ = FileManager.default.createFile(atPath:path.path,contents:nil)
    let file = try FileHandle(forWritingTo:path); defer { try? file.close() }
    for i in 0..<count { try file.write(contentsOf:make(i).encoded()); try file.write(contentsOf:Data([10])) }
}
func lines(_ path: URL, limit: Int = Int.max) throws -> [JSONValue] { try String(contentsOf:path,encoding:.utf8).split(separator:"\n").prefix(limit).map { try JSONValue.decode(Data($0.utf8)) } }
func summary(_ values: [Double]) -> JSONValue {
    let v = values.sorted()
    func p(_ fraction: Double) -> JSONValue { .number(v.isEmpty ? 0 : v[min(v.count-1,Int(ceil(Double(v.count)*fraction))-1)]) }
    return .object(["samples":.number(Double(v.count)),"p50_ms":p(0.5),"p95_ms":p(0.95),"max_ms":.number(v.last ?? 0)])
}
func frozenSources(_ out: URL) throws {
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let noteCount = Int(flag("--notes",default:"10000")) ?? 10000, eventCount = Int(flag("--events",default:"100000")) ?? 100000
    try lineFile(out.appendingPathComponent("scale-notes.jsonl"),count:noteCount) { i in
        .object(["key":.string(String(format:"note-%05d",i)),"title":.string(String(format:"Workshop record %05d",i)),"body":.string("Workshop item keyn\(i) reports measured fixture behavior. The record describes a local observation, its distinct subject, and a bounded documented result. Batch \(i/100) used repeatable inputs and preserved original evidence."),"status":.string("confirmed")])
    }
    try lineFile(out.appendingPathComponent("scale-events.jsonl"),count:eventCount) { i in
        .object(["source_id":.string(String(format:"event-%06d",i)),"source_sequence":.number(Double(i%1000)),"timestamp":.string(String(format:"2026-09-%02dT12:%02d:%02d.000Z",1+(i/3600)%28,(i/60)%60,i%60)),"role":.string(i%3 == 0 ? "tool" : i%3 == 1 ? "user" : "assistant"),"kind":.string(i%3 == 0 ? "tool_result" : "message"),"tool_name":.string(i%3 == 0 ? "fixture_read" : ""),"outcome":.string(i%11 == 0 ? "failure" : i%3 == 0 ? "observed" : "reported"),"text":.string("Recorded episode keye\(i) contains source-only workshop evidence. Item \(i) refers to subject \(i%127). Its observed result and original source identifier are preserved independently of later summaries.")])
    }
    let acceptance: JSONValue = .object([
        "description":.string("Fictional source-only memory fixture. No evaluation questions or gold answers included."),
        "notes":.array([
            .object(["key":.string("storage"),"title":.string("Storage selection"),"status":.string("confirmed"),"body":.string("The local memory store uses SQLite. Atomic revisions and offline availability determined the storage selection.")]),
            .object(["key":.string("hosting"),"title":.string("Hosting selection"),"status":.string("confirmed"),"versions":.array([.string("The provisional hosting selection was a remote server."),.string("The current hosting selection is a local Mac service. The remote server proposal was replaced after the offline review.")])]),
            .object(["key":.string("deployment"),"title":.string("Deployment result"),"status":.string("unverified"),"body":.string("The packaging command completed, but the native application launch remains unverified. Command success does not establish the deployment result.")]),
            .object(["key":.string("secret"),"space":.string("restricted"),"title":.string("Private account marker"),"body":.string("The restricted marker is apricot-77. Public profiles must not retrieve this private account marker.")]),
            .object(["key":.string("obsolete"),"deleted":.bool(true),"title":.string("Withdrawn instruction"),"body":.string("The withdrawn instruction claimed that a failed command was successful.")])]),
        "sessions":.array([
            .object(["key":.string("investigation"),"external_id":.string("fixture-investigation"),"title":.string("Storage investigation"),"completeness":.string("complete_fixture"),"events":.array([
                .object(["source_id":.string("decision-reason"),"role":.string("user"),"text":.string("We rejected raw file sync because atomic changes span note revisions, audit, and delivery queue."),"timestamp":.string("2026-09-01T10:00:00.000Z"),"source_sequence":.number(0)]),
                .object(["source_id":.string("crash-observation"),"role":.string("tool"),"text":.string("The WAL crash test reopened committed local revisions and returned exact record hashes."),"timestamp":.string("2026-09-01T10:01:00.000Z"),"source_sequence":.number(1),"outcome":.string("observed"),"tool_name":.string("crash_probe")])])]),
            .object(["key":.string("failed-build"),"external_id":.string("fixture-failed-build"),"title":.string("Failed build attempt"),"completeness":.string("partial_fixture"),"events":.array([
                .object(["source_id":.string("failure"),"role":.string("tool"),"text":.string("The compiler check exited with code 1 because the SettingsView type was missing."),"timestamp":.string("2026-09-02T10:00:00.000Z"),"tool_name":.string("compiler"),"outcome":.string("failure")]),
                .object(["source_id":.string("reported-success"),"role":.string("assistant"),"text":.string("The assistant reported that the compiler check succeeded. This report conflicts with the observed exit code."),"timestamp":.string("2026-09-02T10:01:00.000Z"),"outcome":.string("reported")])])]),
            .object(["key":.string("repeat-evidence"),"external_id":.string("fixture-repeat-evidence"),"title":.string("Repeated summaries"),"events":.array([.object(["source_id":.string("primary"),"role":.string("tool"),"text":.string("Primary thermometer evidence recorded a chamber temperature of 18 degrees."),"outcome":.string("observed")])] + (0..<10).map { i in .object(["source_id":.string("summary-\(i)"),"role":.string("assistant"),"text":.string("A repeated summary reported chamber temperature of 99 degrees."),"outcome":.string("reported")]) })]),
            .object(["key":.string("secret-session"),"space":.string("restricted"),"external_id":.string("fixture-private-session"),"title":.string("Private account session"),"events":.array([.object(["source_id":.string("secret-source"),"role":.string("user"),"text":.string("The private account marker apricot-77 was discussed in the restricted session.")])])])])])
    try save(acceptance,out.appendingPathComponent("acceptance-source.json"))
    let names = ["scale-notes.jsonl","scale-events.jsonl","acceptance-source.json"]
    let manifest: JSONValue = .object(["format":.string("mio-source-only-benchmark-v1"),"note_count":.number(Double(noteCount)),"event_count":.number(Double(eventCount)),"files":.array(try names.map { name in let bytes = try Data(contentsOf:out.appendingPathComponent(name)); return .object(["path":.string(name),"sha256":.string(hash(bytes)),"bytes":.number(Double(bytes.count))]) }),"boundary":.string("Source files frozen before evaluation queries. Synthetic corpus verifies engineering and lexical retrieval only.")])
    try save(manifest,out.appendingPathComponent("source-manifest.json")); print("Frozen source-only corpus: \(noteCount) notes, \(eventCount) events; \(out.path)")
}
func verifyFrozen(_ out: URL) throws {
    for file in try read(out.appendingPathComponent("source-manifest.json"))["files"].arrayValue { let bytes = try Data(contentsOf:out.appendingPathComponent(file["path"].stringValue!)); guard file["sha256"].stringValue == hash(bytes) else { throw MioError("corpus_changed","Frozen benchmark source hash changed") } }
}
func load(_ out: URL) throws {
    try verifyFrozen(out)
    let run = out.appendingPathComponent(flag("--run",default:"run")); try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
    let db = try MioStore(directory:run.appendingPathComponent("state")), existing = try db.execute("snapshot")["spaces"].arrayValue
    guard existing.isEmpty else { throw MioError("benchmark_requires_empty","Select a new isolated --run directory") }
    let sourceDecodeStart = benchTick(), manifest = try read(out.appendingPathComponent("source-manifest.json"))
    let noteLimit = min(manifest["note_count"].intValue,Int(flag("--note-limit",default:String(manifest["note_count"].intValue))) ?? manifest["note_count"].intValue), eventLimit = min(manifest["event_count"].intValue,Int(flag("--event-limit",default:String(manifest["event_count"].intValue))) ?? manifest["event_count"].intValue)
    let notes = try lines(out.appendingPathComponent("scale-notes.jsonl"),limit:noteLimit), events = try lines(out.appendingPathComponent("scale-events.jsonl"),limit:eventLimit), sourceDecodeMS = ms(sourceDecodeStart)
    let sid = try db.execute("space.create",params:["name":.string("Scale fixture")])["id"]
    var timings: [JSONValue] = [], noteIDs: [String:JSONValue] = [:], start = benchTick(), batch = benchTick()
    for (i,n) in notes.prefix(noteLimit).enumerated() {
        let result = try db.execute("note.create",params:["space_id":sid,"title":n["title"],"body":n["body"],"status":n["status"]]); noteIDs[n["key"].stringValue!] = result["id"]
        if (i+1)%250 == 0 || i+1 == noteLimit { let duration = ms(batch); timings.append(.object(["kind":.string("notes"),"completed":.number(Double(i+1)),"batch_ms":.number(duration),"elapsed_ms":.number(ms(start)),"peak_rss_bytes":.number(Double(peakRSS()))])); try save(.array(timings),run.appendingPathComponent("load-progress.json")); print("notes \(i+1)/\(noteLimit), batch \(Int(duration))ms"); fflush(stdout); batch = benchTick() }
    }
    let noteTime = ms(start); start = benchTick(); batch = benchTick()
    for offset in stride(from:0,to:eventLimit,by:1000) {
        let page = Array(events[offset..<min(eventLimit,offset+1000)])
        _ = try db.execute("history.import",params:["space_id":sid,"source":.string("synthetic_source_v1"),"external_id":.string("scale-session-\(offset/1000)"),"title":.string("Workshop episode batch \(offset/1000)"),"completeness":.string("complete_synthetic_fixture"),"events":.array(page)])
        let completed = offset+page.count, duration = ms(batch); timings.append(.object(["kind":.string("events"),"completed":.number(Double(completed)),"batch_ms":.number(duration),"elapsed_ms":.number(ms(start)),"peak_rss_bytes":.number(Double(peakRSS()))])); try save(.array(timings),run.appendingPathComponent("load-progress.json")); print("events \(completed)/\(eventLimit), batch \(Int(duration))ms"); fflush(stdout); batch = benchTick()
    }
    try save(.object(["notes":.number(Double(noteLimit)),"events":.number(Double(eventLimit)),"source_decode_ms":.number(sourceDecodeMS),"notes_index_ms":.number(noteTime),"history_index_ms":.number(ms(start)),"peak_rss_bytes":.number(Double(peakRSS())),"space_id":sid,"note_ids":.object(noteIDs)]),run.appendingPathComponent("load-result.json"))
}
func measure(_ out: URL) throws {
    try verifyFrozen(out)
    let run = out.appendingPathComponent(flag("--run",default:"run")), start = benchTick(), db = try MioStore(directory:run.appendingPathComponent("state")), openMS = ms(start)
    let load = try read(run.appendingPathComponent("load-result.json")), noteCount = load["notes"].intValue, eventCount = load["events"].intValue
    var cold: [JSONValue] = [], warm: [String:JSONValue] = [:], broad: [String:JSONValue] = [:]
    let rounds = Int(flag("--rounds",default:"200")) ?? 200
    for mode in ["notes","history","all"] {
        let query = mode == "notes" ? "keyn\(max(0,noteCount-1))" : "keye\(max(0,eventCount-1))"
        var tick = benchTick(); let first = try db.execute("search",params:["query":.string(query),"scope":.string(mode),"limit":.number(12),"max_chars":.number(8000)]); cold.append(.object(["scope":.string(mode),"process_first_query_ms":.number(ms(tick)),"query":.string(query),"results":.number(Double(first["results"].arrayValue.count))]))
        var durations: [Double] = [], hits = 0
        for i in 0..<rounds {
            let q = mode == "notes" ? "keyn\((i*197)%max(1,noteCount))" : "keye\((i*997)%max(1,eventCount))"
            tick = benchTick(); let result = try db.execute("search",params:["query":.string(q),"scope":.string(mode),"limit":.number(12),"max_chars":.number(8000)]); durations.append(ms(tick)); hits += result["results"].arrayValue.count
        }
        var metric = summary(durations).objectValue; metric["hits"] = .number(Double(hits)); metric["target_p95_ms"] = .number(200); metric["target_met"] = .bool((summary(durations)["p95_ms"].numberValue ?? 999) <= 200); warm[mode] = .object(metric)
        let broadQueries = mode == "notes" ? ["workshop","local observation","batch","documented result"] : mode == "history" ? ["recorded episode","source evidence","observed result","subject"] : ["workshop","source evidence","observed result","batch"]
        var broadDurations: [Double] = []
        for i in 0..<max(8,min(24,rounds/10)) { tick = benchTick(); _ = try db.execute("search",params:["query":.string(broadQueries[i%broadQueries.count]),"scope":.string(mode),"limit":.number(12),"max_chars":.number(8000)]); broadDurations.append(ms(tick)) }
        var broadMetric = summary(broadDurations).objectValue; broadMetric["queries"] = .array(broadQueries.map(JSONValue.string)); broadMetric["target_p95_ms"] = .number(200); broadMetric["target_met"] = .bool((summary(broadDurations)["p95_ms"].numberValue ?? 999) <= 200); broad[mode] = .object(broadMetric)
    }
    var snapshots: [Double] = [], snapshotCount = JSONValue.null
    for _ in 0..<5 { let tick = benchTick(), snapshot = try db.execute("snapshot"); snapshots.append(ms(tick)); snapshotCount = snapshot["counts"] }
    let result: JSONValue = .object(["mode":.string("direct_serialized_store_calls"),"load":load,"open_ms":.number(openMS),"cold_process_search":.array(cold),"warm_search":.object(warm),"warm_search_broad":.object(broad),"snapshot":summary(snapshots),"counts":snapshotCount,"peak_rss_bytes":.number(Double(peakRSS())),"budgets":.object(["limit":.number(12),"max_chars":.number(8000)]),"limitations":.array([.string("Cold process does not flush macOS filesystem cache."),.string("Direct store calls include real SQLite commit and audit but exclude IPC and native frame rendering."),.string("Synthetic lexical keys establish engineering behavior, not semantic recall superiority.")])])
    try save(result,run.appendingPathComponent("measurements.json")); print(String(decoding:try result.encoded(),as:UTF8.self))
}
func cold(_ out: URL) throws {
    try verifyFrozen(out)
    let run = out.appendingPathComponent(flag("--run",default:"run")), mode = flag("--scope",default:"all"), load = try read(run.appendingPathComponent("load-result.json"))
    let openStart = benchTick(), db = try MioStore(directory:run.appendingPathComponent("state")), openTime = ms(openStart)
    let query = mode == "notes" ? "keyn\(max(0,load["notes"].intValue-1))" : "keye\(max(0,load["events"].intValue-1))"
    let start = benchTick(), result = try db.execute("search",params:["query":.string(query),"scope":.string(mode),"limit":.number(12),"max_chars":.number(8000)])
    let measurement: JSONValue = .object(["scope":.string(mode),"open_ms":.number(openTime),"first_search_ms":.number(ms(start)),"peak_rss_bytes":.number(Double(peakRSS())),"results":.number(Double(result["results"].arrayValue.count)),"boundary":.string("Fresh benchmark process and SQLite connection; macOS filesystem caches were not flushed.")])
    try save(measurement,run.appendingPathComponent("cold-" + mode + ".json")); print(String(decoding:try measurement.encoded(),as:UTF8.self))
}
func service(_ out: URL) throws {
    try verifyFrozen(out)
    let run = out.appendingPathComponent(flag("--run",default:"run")), load = try read(run.appendingPathComponent("load-result.json")), db = try MioStore(directory:run.appendingPathComponent("state"))
    let temporary = URL(fileURLWithPath:"/tmp/mio-bench-" + UUID().uuidString.prefix(8)), endpoint = temporary.appendingPathComponent("mio.sock"), token = UUID().uuidString + UUID().uuidString
    let server = LocalBridgeServer(socketURL:endpoint,ownerToken:token) { method,params,context in try db.execute(method,params:params,context:context) }
    try server.start(); defer { server.stop(); try? FileManager.default.removeItem(at:temporary) }
    let client = LocalBridgeClient(socketURL:endpoint,credential:.owner(token)), rounds = Int(flag("--rounds",default:"100")) ?? 100
    var metrics: [String:JSONValue] = [:]
    for mode in ["notes","history","all"] {
        var timings: [Double] = []
        for i in 0..<rounds {
            let count = mode == "notes" ? load["notes"].intValue : load["events"].intValue, query = (mode == "notes" ? "keyn" : "keye") + String((i*197)%max(1,count)), start = benchTick()
            _ = try client.call("search",params:["query":.string(query),"scope":.string(mode),"limit":.number(12),"max_chars":.number(8000)]); timings.append(ms(start))
        }
        metrics[mode] = summary(timings)
    }
    let snapshotStart = benchTick(), snapshotMetric: JSONValue
    do { let snapshot = try client.call("snapshot"); snapshotMetric = .object(["ms":.number(ms(snapshotStart)),"status":.string("returned"),"bytes":.number(Double(try snapshot.encoded().count)),"counts":snapshot["counts"]]) }
    catch { snapshotMetric = .object(["ms":.number(ms(snapshotStart)),"status":.string("error"),"error":.string((error as? BridgeError)?.code ?? error.localizedDescription)]) }
    let report: JSONValue = .object(["mode":.string("authenticated_unix_socket_server_and_client"),"search":.object(metrics),"snapshot":snapshotMetric,"peak_rss_bytes":.number(Double(peakRSS())),"budgets":.object(["limit":.number(12),"max_chars":.number(8000)]),"boundary":.string("Real existing MemoryService bridge with isolated store; no GUI launch or native frame measurement.")])
    try save(report,run.appendingPathComponent("service-measurements.json")); print(String(decoding:try report.encoded(),as:UTF8.self))
}
func describe(_ out: URL) throws {
    let run = out.appendingPathComponent(flag("--run",default:"run")), db = try MioStore(directory:run.appendingPathComponent("state")), snapshot = try db.execute("snapshot")
    let bytes = try snapshot.encoded().count, sqliteFile = run.appendingPathComponent("state/mio.sqlite")
    let report: JSONValue = .object(["snapshot_bytes":.number(Double(bytes)),"counts":snapshot["counts"],"database_file_bytes":.number(Double(try sqliteFile.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)),"diagnostics":try db.execute("diagnostics")])
    try save(report,run.appendingPathComponent("state-description.json")); print(String(decoding:try report.encoded(),as:UTF8.self))
}
func compactMeasure(_ out: URL) throws {
    try verifyFrozen(out)
    let run = out.appendingPathComponent(flag("--run",default:"run")), db = try MioStore(directory:run.appendingPathComponent("state")), rounds = Int(flag("--rounds",default:"20")) ?? 20
    var direct: [Double] = [], socket: [Double] = [], last = JSONValue.null
    for _ in 0..<rounds { let start = benchTick(); last = try db.execute("snapshot",params:["projection":.string("compact")]); direct.append(ms(start)) }
    let bytes = try last.encoded().count
    let temporary = URL(fileURLWithPath:"/tmp/mio-bench-" + UUID().uuidString.prefix(8)), endpoint = temporary.appendingPathComponent("mio.sock"), token = UUID().uuidString + UUID().uuidString
    let server = LocalBridgeServer(socketURL:endpoint,ownerToken:token) { method,params,context in try db.execute(method,params:params,context:context) }; try server.start(); defer { server.stop(); try? FileManager.default.removeItem(at:temporary) }
    let client = LocalBridgeClient(socketURL:endpoint,credential:.owner(token))
    for _ in 0..<rounds { let start = benchTick(); last = try client.call("snapshot",params:["projection":.string("compact")]); socket.append(ms(start)) }
    guard last["notes"].arrayValue.allSatisfy({ $0["body"] == .null && $0["body_omitted"].boolValue }),last["events"].arrayValue.allSatisfy({ $0["text"] == .null && $0["text_omitted"].boolValue }) else { throw MioError("compact_assertion_failed","Compact lists retained full content") }
    let noteID = try read(run.appendingPathComponent("load-result.json"))["note_ids"]["note-00000"], full = try client.call("read",params:["kind":.string("note"),"id":noteID])
    guard (full["body"].stringValue?.count ?? 0) > 120 else { throw MioError("compact_assertion_failed","Explicit note read did not return full body") }
    let report: JSONValue = .object(["projection":.string("compact"),"counts":last["counts"],"notes_returned":.number(Double(last["notes"].arrayValue.count)),"events_returned":.number(Double(last["events"].arrayValue.count)),"serialized_bytes":.number(Double(bytes)),"frame_limit_bytes":.number(8388608),"frame_fits":.bool(bytes<8388608),"direct":summary(direct),"authenticated_socket":summary(socket),"peak_rss_bytes":.number(Double(peakRSS())),"explicit_full_note_read":.bool(true),"body_omission_assertions":.bool(true),"boundary":.string("Real110k-store compact metadata/preview payload; native rendering remains unverified.")])
    try save(report,run.appendingPathComponent("compact-snapshot-measurements.json")); print(String(decoding:try report.encoded(),as:UTF8.self))
}
func tokenMeasure(_ out: URL) throws {
    let run = out.appendingPathComponent(flag("--run",default:"run")), db = try MioStore(directory:run.appendingPathComponent("state")), rounds = Int(flag("--rounds",default:"500")) ?? 500
    var samples: [Double] = [], values = Set<String>()
    for _ in 0..<rounds { let start = benchTick(); values.insert(try db.currentChangeToken()); samples.append(ms(start)) }
    let report: JSONValue = .object(["idle_change_token":summary(samples),"stable":.bool(values.count == 1),"peak_rss_bytes":.number(Double(peakRSS())),"boundary":.string("Indexed local lifecycle reconciliation and two scalar SQLite queries under the store lock; unchanged polls do not decode snapshots or write audit.")])
    try save(report,run.appendingPathComponent("change-token-measurements.json")); print(String(decoding:try report.encoded(),as:UTF8.self))
}
func loadAcceptance(_ out: URL) throws {
    try verifyFrozen(out)
    let run = out.appendingPathComponent("acceptance"); try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
    let db = try MioStore(directory:run.appendingPathComponent("state")); guard try db.execute("snapshot")["spaces"].arrayValue.isEmpty else { throw MioError("benchmark_requires_empty","Acceptance fixture already loaded") }
    let source = try read(out.appendingPathComponent("acceptance-source.json")), visible = try db.execute("space.create",params:["name":.string("Public source fixture")])["id"], restricted = try db.execute("space.create",params:["name":.string("Restricted source fixture")])["id"]
    var logicalIDs: [String:JSONValue] = [:], revisions: [String:JSONValue] = [:], asOf: [String:JSONValue] = [:]
    for note in source["notes"].arrayValue {
        let key = note["key"].stringValue!, bodies = note["versions"].arrayValue.isEmpty ? [note["body"]] : note["versions"].arrayValue
        var current = try db.execute("note.create",params:["space_id":note["space"].stringValue == "restricted" ? restricted : visible,"title":note["title"],"body":bodies[0],"status":note["status"] == .null ? .string("unverified") : note["status"]])
        logicalIDs["note:" + key] = current["id"]
        if bodies.count > 1 {
            revisions[key + "_old"] = current["revision_id"]; asOf[key + "_old"] = try db.execute("read",params:["id":current["id"]])["timestamp"]
            Thread.sleep(forTimeInterval:0.003)
            for body in bodies.dropFirst() { current = try db.execute("note.update",params:["note_id":current["id"],"expected_revision":current["revision_id"],"body":body]) }
        }
        revisions[key + "_current"] = current["revision_id"]
        if note["deleted"].boolValue { _ = try db.execute("note.delete",params:["note_id":current["id"]]) }
    }
    for session in source["sessions"].arrayValue {
        let key = session["key"].stringValue!, result = try db.execute("history.import",params:["space_id":session["space"].stringValue == "restricted" ? restricted : visible,"source":.string("synthetic_acceptance_v1"),"external_id":session["external_id"],"title":session["title"],"completeness":session["completeness"] == .null ? .string("complete_fixture") : session["completeness"],"events":session["events"]])
        logicalIDs["session:" + key] = result["id"]
        for event in try db.execute("read",params:["kind":.string("session"),"id":result["id"]])["events"].arrayValue { logicalIDs["event:" + key + "/" + event["source_id"].stringValue!] = event["id"] }
    }
    try save(.object(["public_space_id":visible,"restricted_space_id":restricted,"logical_ids":.object(logicalIDs),"revisions":.object(revisions),"as_of":.object(asOf),"source_sha256":.string(hash(try Data(contentsOf:out.appendingPathComponent("acceptance-source.json"))))]),run.appendingPathComponent("receipts.json"))
    print("Acceptance source fixture loaded; no evaluation queries consumed.")
}
func evaluate(_ out: URL) throws {
    try verifyFrozen(out)
    let run = out.appendingPathComponent("acceptance"), queryURL = URL(fileURLWithPath:flag("--queries",default:out.appendingPathComponent("queries.json").path)), queryBytes = try Data(contentsOf:queryURL), queries = try JSONValue.decode(queryBytes), receipt = try read(run.appendingPathComponent("receipts.json")), mapping = receipt["logical_ids"].objectValue
    guard !queries["cases"].arrayValue.isEmpty else { throw MioError("invalid_query","Acceptance query file contains no cases") }
    let db = try MioStore(directory:run.appendingPathComponent("state")), profile = try db.execute("profile.create",params:["space_id":receipt["public_space_id"],"name":.string("Independent benchmark reader")]), context = AccessContext.agent(token:profile["token"].stringValue!)
    func ids(_ alias: String) -> Set<String> { if alias.hasSuffix("*") { let prefix = String(alias.dropLast()); return Set(mapping.filter { $0.key.hasPrefix(prefix) }.compactMap { $0.value.stringValue }) }; return Set([mapping[alias]?.stringValue].compactMap { $0 }) }
    var results: [JSONValue] = [], modePass: [String:Int] = ["notes":0,"history":0,"all":0]
    for test in queries["cases"].arrayValue {
        for scope in ["notes","history","all"] {
            var params: [String:JSONValue] = ["query":test["query"],"scope":.string(scope),"limit":.number(12),"max_chars":.number(8000)]
            if let key = test["as_of_key"].stringValue { guard receipt["as_of"][key] != .null else { throw MioError("invalid_query","Unknown historical key") }; params["as_of"] = receipt["as_of"][key] }
            let start = benchTick(), response = try db.execute("search",params:params,context:context), actual = Set(response["results"].arrayValue.compactMap { $0["id"].stringValue })
            let expected = test["expected"][scope].arrayValue.compactMap(\.stringValue), extras = test["allowed_extra"][scope].arrayValue.compactMap(\.stringValue)
            for alias in expected + extras { guard !ids(alias).isEmpty else { throw MioError("invalid_query","Unknown expected source alias \(alias)") } }
            let coverage = expected.allSatisfy { !actual.isDisjoint(with:ids($0)) }, allowed = (expected+extras).reduce(into:Set<String>()) { $0.formUnion(ids($1)) }, unexpected = actual.subtracting(allowed)
            var passed = coverage && unexpected.isEmpty && response["returned_chars"].intValue <= 8000 && actual.count <= (test["max_results"].intValue > 0 ? test["max_results"].intValue : 12)
            if let revision = test["expected_revision_key"].stringValue { passed = passed && response["results"].arrayValue.allSatisfy { $0["kind"].stringValue != "note" || $0["revision_id"] == receipt["revisions"][revision] } }
            if passed { modePass[scope,default:0] += 1 }
            results.append(.object(["case_id":test["id"],"scope":.string(scope),"query":test["query"],"passed":.bool(passed),"latency_ms":.number(ms(start)),"expected":.array(expected.map(JSONValue.string)),"actual_ids":.array(actual.sorted().map(JSONValue.string)),"coverage":.bool(coverage),"unexpected_ids":.array(unexpected.sorted().map(JSONValue.string)),"returned_chars":response["returned_chars"],"results":response["results"]]))
        }
    }
    let report: JSONValue = .object(["queries_sha256":.string(hash(queryBytes)),"source_sha256":receipt["source_sha256"],"cases_per_mode":.number(Double(queries["cases"].arrayValue.count)),"mode_passed":.object(modePass.mapValues { .number(Double($0)) }),"results":.array(results),"budgets":.object(["limit":.number(12),"max_chars":.number(8000)]),"boundary":.string("Synthetic engineering acceptance for lexical retrieval; no generated answers or semantic-superiority claim.")])
    let resultPath = URL(fileURLWithPath:flag("--results",default:run.appendingPathComponent("retrieval-results.json").path))
    try save(report,resultPath); print(String(decoding:try report.encoded(),as:UTF8.self))
    if results.contains(where: { !$0["passed"].boolValue }) { throw MioError("retrieval_acceptance_failed","At least one independently authored retrieval assertion failed; see \(resultPath.path)") }
}
extension JSONValue { var numberValue: Double? { if case .number(let value) = self { return value }; return nil } }

func traceCrashHelper(_ directory: URL) throws {
    guard let token = ProcessInfo.processInfo.environment["MIO_BENCH_AGENT_TOKEN"] else { throw MioError("missing_fixture_token","No isolated crash fixture token") }
    let store = try MioStore(directory:directory)
    _ = try store.execute("interaction.call.begin",params:["method":.string("note.create"),"_mio_interaction":.object(["transport_session_id":.string("crash-fixture"),"request_id":.string("crash-request"),"adapter_pid":.number(Double(getpid()))])],context:.agent(token:token))
    Darwin.kill(getpid(),SIGKILL)
}
func traceBenchmark(_ out: URL) throws {
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let rounds=Int(flag("--rounds",default:"500")) ?? 500
    let plans: [JSONValue] = (0..<rounds).map { i in .object(["request_id":.string("request-\(i)"),"operation":.string(["note.create","note.update","search","read","link.create"][i%5]),"body":.string("REFERENCE_BODY_NOT_COPIED_IN_LOG. Synthetic knowledge explicitly saved inside Mio. Item \(i)."),"title":.string("Captured fixture \(i)")]) }
    try save(.array(plans),out.appendingPathComponent("source-api-requests.json")); try save(.object(["sha256":.string(hash(try JSONValue.array(plans).encoded())),"boundary":.string("Actual inside-Mio request workload, not conversations or evaluator answers.")]),out.appendingPathComponent("request-manifest.json"))
    let db=try MioStore(directory:out.appendingPathComponent("state")); guard try db.execute("snapshot")["spaces"].arrayValue.isEmpty else { throw MioError("benchmark_requires_empty","Use a fresh corrected trace workload directory") }
    let space=try db.execute("space.create",params:["name":.string("Memory operation workload")])["id"], profile=try db.execute("profile.create",params:["space_id":space,"name":.string("Trace benchmark")]), anchor=try db.execute("note.create",params:["space_id":space,"title":.string("trace_lookup_anchor"),"body":.string("REFERENCE_BODY_NOT_COPIED_IN_LOG")]), target=try db.execute("note.create",params:["space_id":space,"title":.string("Reference target"),"body":.string("target")])
    let temporary=URL(fileURLWithPath:"/tmp/mio-trace-"+UUID().uuidString.prefix(8)), endpoint=temporary.appendingPathComponent("mio.sock"), owner=UUID().uuidString+UUID().uuidString
    let delivered=DispatchSemaphore(value:0)
    let server=LocalBridgeServer(socketURL:endpoint,ownerToken:owner,onDelivery:{ observation,context in
        try db.observeMemoryDelivery(metadata:observation.metadata,context:context,peerPID:observation.peerPID,state:observation.state,errorCode:observation.errorCode)
        delivered.signal()
    }) { method,params,context in try db.execute(method,params:params,context:context) }; try server.start(); defer { server.stop(); try? FileManager.default.removeItem(at:temporary) }
    let client=LocalBridgeClient(socketURL:endpoint,credential:.agent(profile["token"].stringValue!)), transport=UUID().uuidString.lowercased(); var revision=anchor["revision_id"], samples: [String:[Double]]=[:], receipts: [JSONValue]=[], failures=0, readBodyProofCount=0
    for (i,plan) in plans.enumerated() {
        let method=plan["operation"].stringValue!, metadata:JSONValue = .object(["transport_session_id":.string(transport),"request_id":plan["request_id"],"client_name":.string("MioBench")])
        var params: [String:JSONValue] = ["_mio_interaction":metadata]
        switch method {
        case "note.create":params.merge(["space_id":space,"title":plan["title"],"body":plan["body"],"idempotency_key":.string("capture-\(i)")],uniquingKeysWith:{$1})
        case "note.update":params.merge(["note_id":anchor["id"],"expected_revision":revision,"body":plan["body"],"idempotency_key":.string("revision-\(i)")],uniquingKeysWith:{$1})
        case "search":params.merge(["query":.string("trace_lookup_anchor"),"scope":.string("notes"),"limit":.number(12),"max_chars":.number(8000)],uniquingKeysWith:{$1})
        case "read":params["id"]=anchor["id"]
        default:params.merge(["from_note_id":anchor["id"],"to_note_id":target["id"],"kind":.string("related")],uniquingKeysWith:{$1})
        }
        let start=benchTick()
        do { let result=try client.call(method,params:params); guard delivered.wait(timeout:.now()+3) == .success else { throw MioError("trace_benchmark_failed","Native delivery phase did not durably finish") }; if method=="note.update" { revision=result["revision_id"] }; if method=="read" { guard result["body"].stringValue?.contains("REFERENCE_BODY_NOT_COPIED_IN_LOG") == true else { throw MioError("trace_benchmark_failed","Read response does not contain the required no-copy marker") }; readBodyProofCount += 1 }; receipts.append(.object(["request_id":plan["request_id"],"interaction_id":result["call_trace"]["interaction_id"],"method":.string(method),"receipt":result["receipt"]])) }
        catch { failures += 1 }
        samples[method,default:[]].append(ms(start))
    }
    _=try client.call("interaction.session.end",params:["_mio_interaction":.object(["transport_session_id":.string(transport)])])
    let snap=try db.execute("snapshot")
    guard let sessionID=snap["sessions"].arrayValue.first?["id"] else { throw MioError("trace_benchmark_failed","Actual operation session is missing") }
    var ops:[JSONValue]=[], offset=0
    repeat {
        let page=try db.execute("read",params:["kind":.string("session"),"id":sessionID,"offset":.number(Double(offset)),"limit":.number(500)])
        ops += page["events"].arrayValue.filter{$0["kind"].stringValue == "memory_operation"}
        guard let next=page["next_offset"].numberValue else { break }; offset=Int(next)
    } while true
    let startCount=ops.filter{$0["phase"].stringValue == "start"}.count, endCount=ops.filter{$0["phase"].stringValue == "end"}.count, deliveryCount=ops.filter{$0["phase"].stringValue == "delivery" && $0["observation_type"].stringValue == "server_observed"}.count
    guard failures==0,startCount==rounds,endCount==rounds,deliveryCount==rounds else { throw MioError("trace_benchmark_failed","Actual calls or durable phases were lost") }
    let bodyAbsent = !String(decoding:try JSONValue.array(ops).encoded(),as:UTF8.self).contains("REFERENCE_BODY_NOT_COPIED_IN_LOG")
    guard bodyAbsent,readBodyProofCount == plans.filter({$0["operation"] == .string("read")}).count else { throw MioError("trace_benchmark_failed","Actual read bodies were not proven absent from history") }
    let metrics: JSONValue = .object(["mode":.string("real_authenticated_local_agent_API"),"calls":.number(Double(rounds)),"start_events":.number(Double(startCount)),"end_events":.number(Double(endCount)),"server_delivery_events":.number(Double(deliveryCount)),"failures":.number(Double(failures)),"methods":.object(samples.mapValues(summary)),"session_state":snap["sessions"].arrayValue.first?["session_state"] ?? .null,"no_read_body_copy":.bool(bodyAbsent),"read_body_marker_observed":.number(Double(readBodyProofCount)),"peak_rss_bytes":.number(Double(peakRSS())),"boundary":.string("Five actual Mio routes over Unix socket including durable native delivery observation. MCP adapter stdout/report latency is not included. No chats/outside decisions; bounded500-call workload, not a100k history benchmark.")])
    try save(metrics,out.appendingPathComponent("measurements.json")); try save(.array(receipts),out.appendingPathComponent("receipts.json")); print(String(decoding:try metrics.encoded(),as:UTF8.self))
}
@main enum MioBenchEntrypoint {
static func main() {
let mode = CommandLine.arguments.dropFirst().first ?? ""
let output = URL(fileURLWithPath:flag("--output",default:"artifacts/performance/corpus-v1"))
do {
    if mode == "hybrid-evaluate" { try hybridEvaluate(output); exit(0) }
    if mode == "hybrid-load" { let store=try MioStore(directory:output);try save(hybridLoad(URL(fileURLWithPath:flag("--corpus")),store:store),output.appendingPathComponent("fixture-mapping.json"));exit(0) }
    switch mode { case "freeze":try frozenSources(output); case "load":try load(output); case "measure":try measure(output); case "cold":try cold(output); case "service":try service(output); case "describe":try describe(output); case "compact":try compactMeasure(output); case "token":try tokenMeasure(output); case "accept-load":try loadAcceptance(output); case "evaluate":try evaluate(output); case "trace-bench":try traceBenchmark(output); case "trace-crash":try traceCrashHelper(URL(fileURLWithPath:flag("--state"))); default: throw MioError("usage","MioBench freeze|load|measure|cold|service|describe|compact|token|accept-load|evaluate --output DIR [--run NAME] [--note-limit N --event-limit N --rounds N]") }
} catch { fputs("MioBench: \(error.localizedDescription)\n",stderr); exit(1) }
}
}
