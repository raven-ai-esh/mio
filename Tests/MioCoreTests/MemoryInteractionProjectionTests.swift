import XCTest
import Foundation
@testable import MioCore

final class MemoryInteractionProjectionTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }
    private func store() throws -> MioStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mio-projection-" + UUID().uuidString)
        directories.append(directory)
        return try MioStore(directory: directory)
    }
    private func actualReplica() throws -> JSONValue {
        let path = try XCTUnwrap(Bundle.module.url(forResource: "MCPCloudLifecycleReplica", withExtension: "json", subdirectory: "Fixtures"))
        let document = try JSONValue.decode(Data(contentsOf: path))
        XCTAssertEqual(document["records"].arrayValue.count, 16)
        XCTAssertEqual(document["records"].arrayValue.filter { $0["kind"] == .string("event") }.count, 12)
        return document
    }
    private func subset(_ document: JSONValue, _ records: [JSONValue]) -> JSONValue {
        var result = document.objectValue
        result["records"] = .array(records)
        result["profiles"] = .array([])
        result["audit"] = .array([])
        return .object(result)
    }
    private func merge(_ store: MioStore, _ document: JSONValue, _ records: [JSONValue]) throws {
        _ = try store.execute("replica.merge", params: ["document": subset(document, records)])
    }
    private func ordered(_ records: [JSONValue]) -> [JSONValue] {
        records.sorted {
            let left = $0["data"]["timestamp"].stringValue ?? $0["timestamp"].stringValue ?? ""
            let right = $1["data"]["timestamp"].stringValue ?? $1["timestamp"].stringValue ?? ""
            return left == right ? ($0["entity_id"].stringValue ?? "") < ($1["entity_id"].stringValue ?? "") : left < right
        }
    }
    private func changed(_ record: JSONValue, store: MioStore, edit: (inout [String: JSONValue]) -> Void) throws -> JSONValue {
        var value = record.objectValue, data = record["data"].objectValue
        value.removeValue(forKey: "content_hash")
        edit(&data)
        value["data"] = .object(data)
        value["content_hash"] = .string(store.hash(try JSONValue.object(value).encoded()))
        return .object(value)
    }
    func testConflictingEndCannotDropStartDependenciesOrExposeRawRoutes() throws {
        let document=try actualReplica(),records=document["records"].arrayValue
        let start=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("start") && $0["data"]["method"] == .string("note.create")})
        let originalEnd=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"]})
        for order in [false,true] {
            let receiver=try store(), home=start["data"]["space_id"]
            try merge(receiver,document,records.filter{$0["kind"] != .string("event")})
            let secret=try receiver.execute("space.create",params:["name":.string("Private START")])["id"]
            let privateStart=try changed(start,store:receiver){$0["required_space_ids"] = .array([home,secret]);$0["target_space_ids"] = .array([home,secret])}
            let badEnd=try changed(originalEnd,store:receiver){$0["request_fingerprint"] = .string(String(repeating:"b",count:64));$0["text"] = .string("conflicting_end_private_marker success")}
            try merge(receiver,document,order ? [privateStart,badEnd] : [badEnd,privateStart])
            let callID=start["data"]["interaction_id"].stringValue!, call=try XCTUnwrap(receiver.entity("interaction",callID))
            XCTAssertNotEqual(call["state"],.string("completed"));XCTAssertEqual(call["receipt"],.null);XCTAssertEqual(call["end_event_id"],.null)
            XCTAssertEqual(Set(call["required_space_ids"].arrayValue.compactMap(\.stringValue)),Set([home.stringValue!,secret.stringValue!]))
            let profile=try receiver.execute("profile.create",params:["space_id":home,"name":.string("Home-only")]), access=AccessContext.agent(token:profile["token"].stringValue!)
            let snapshot=try receiver.execute("snapshot",context:access)
            XCTAssertFalse(snapshot["interactions"].arrayValue.contains{$0["id"] == .string(callID)})
            XCTAssertEqual(snapshot["counts"]["events"].intValue,0);XCTAssertTrue(snapshot["events"].arrayValue.isEmpty)
            for kind in ["event","source"] { XCTAssertThrowsError(try receiver.execute("read",params:["kind":.string(kind),"id":badEnd["data"]["id"]],context:access)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") } }
            let session=try receiver.execute("read",params:["kind":.string("session"),"id":badEnd["data"]["session_id"]],context:access)
            XCTAssertEqual(session["event_count"].intValue,0);XCTAssertTrue(session["events"].arrayValue.isEmpty)
            XCTAssertTrue(try receiver.execute("search",params:["query":.string("conflicting_end_private_marker"),"scope":.string("history")],context:access)["results"].arrayValue.isEmpty)
            _=try receiver.execute("connection.create",params:["from_space_id":home,"to_space_id":secret,"access":.string("read")])
            XCTAssertThrowsError(try receiver.execute("read",params:["kind":.string("event"),"id":badEnd["data"]["id"]],context:access),"Contradictory execution stays untrusted even with all grants")
            XCTAssertEqual(try receiver.entity("event",badEnd["data"]["id"].stringValue!),badEnd["data"],"Keep the imported raw event for owner inspection")
        }
    }
    func testLateContradictionInvalidatesAlreadyCachedEventSourceAndSessionReplies() throws {
        let document=try actualReplica(),records=document["records"].arrayValue,receiver=try store()
        let start=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("start") && $0["data"]["method"] == .string("note.create")})
        let originalEnd=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"]}),home=start["data"]["space_id"]
        try merge(receiver,document,records.filter{$0["kind"] != .string("event")})
        let secret=try receiver.execute("space.create",params:["name":.string("Late private START")])["id"]
        let privateStart=try changed(start,store:receiver){$0["required_space_ids"] = .array([home,secret])}
        let badEnd=try changed(originalEnd,store:receiver){$0["request_fingerprint"] = .string(String(repeating:"b",count:64))}
        try merge(receiver,document,[badEnd])
        let profile=try receiver.execute("profile.create",params:["space_id":home,"name":.string("Cached reader")]),access=AccessContext.agent(token:profile["token"].stringValue!)
        var requests:[[String:JSONValue]]=[]
        for kind in ["event","source","session"] {
            let request:[String:JSONValue]=["kind":.string(kind),"id":kind == "session" ? badEnd["data"]["session_id"] : badEnd["data"]["id"],"_mio_interaction":.object(["transport_session_id":.string("cached-reader"),"request_id":.string("cached-"+kind)])]
            let reply=try receiver.execute("read",params:request,context:access)
            XCTAssertTrue(reply["receipt"] != .null || reply["events"].arrayValue.contains{$0["receipt"] != .null})
            XCTAssertNotNil(receiver.interactionReplies[reply["call_trace"]["interaction_id"].stringValue!]);requests.append(request)
        }
        try merge(receiver,document,[privateStart])
        for request in requests { XCTAssertThrowsError(try receiver.execute("read",params:request,context:access)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") } }
    }
    func testExecutionIdentityContradictionsFailClosedButObserverChangesRemainValid() throws {
        let document=try actualReplica(),records=document["records"].arrayValue
        let start=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("start")}), end=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"]})
        for key in ["actor","method","owner_pid","adapter_pid","owner_device_id","started_at","observing_pid"] {
            let receiver=try store()
            let altered=try changed(end,store:receiver) {
                switch key {
                case "owner_pid","adapter_pid","observing_pid": $0[key] = .number(987654)
                case "started_at": $0[key] = .string("2000-01-01T00:00:00.000Z")
                default: $0[key] = .string("different-"+key)
                }
            }
            try merge(receiver,document,records.filter{$0["kind"] != .string("event")}+[altered,start])
            let call=try XCTUnwrap(receiver.entity("interaction",start["data"]["interaction_id"].stringValue!))
            if key == "observing_pid" { XCTAssertEqual(call["state"],.string("completed"));XCTAssertEqual(call["receipt"],end["data"]["receipt"]) }
            else { XCTAssertEqual(call["state"],.string("invalid"),key);XCTAssertEqual(call["receipt"],.null,key);XCTAssertEqual(call["integrity_state"],.string("conflicting"),key) }
        }
    }
    func testGenericLegacyEventInteractionIDDoesNotAcquireMioCallAuthorization() throws {
        let receiver=try store(),home=try receiver.execute("space.create",params:["name":.string("Legacy compatibility")])["id"]
        let profile=try receiver.execute("profile.create",params:["space_id":home,"name":.string("Legacy reader")]),access=AccessContext.agent(token:profile["token"].stringValue!)
        let imported=try receiver.execute("history.import",params:["space_id":home,"source":.string("legacy-synthetic-fixture"),"external_id":.string("legacy-contract"),"events":.array([.object(["source_id":.string("legacy-observation"),"kind":.string("event"),"interaction_id":.string("external-span-id"),"text":.string("legacy_contract_visible")])])])
        let event=try XCTUnwrap(receiver.execute("read",params:["kind":.string("session"),"id":imported["id"]])["events"].arrayValue.first)
        for kind in ["event","source"] { XCTAssertEqual(try receiver.execute("read",params:["kind":.string(kind),"id":event["id"]],context:access)["text"],event["text"]) }
        XCTAssertEqual(try receiver.execute("search",params:["query":.string("legacy_contract_visible"),"scope":.string("history"),"include_legacy_history":.bool(true)],context:access)["results"].arrayValue.first?["id"],event["id"])
    }
    func testMalformedRawPhasesAreUnavailableToAgentsBeforeSearchLimitsAndCounts() throws {
        let document=try actualReplica(),records=document["records"].arrayValue
        let start=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("start") && $0["data"]["method"] == .string("note.create")})
        let end=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"]})
        let delivery=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("delivery") && $0["data"]["interaction_id"] == start["data"]["interaction_id"]})
        for phase in ["start","end","delivery"] {
            let receiver=try store(),original=phase == "start" ? start : phase == "end" ? end : delivery
            let marker="untrusted_phase_marker_"+phase
            let bad=try changed(original,store:receiver) {
                $0["text"] = .string(marker)
                if phase == "start" { $0["receipt"] = end["data"]["receipt"] }
                else if phase == "end" { $0["finished_at"] = .null }
                else { $0["receipt"] = .object(["status":.string("local_committed"),"operation_id":.string("invented-delivery-commit")]) }
            }
            let phases=[start,end,delivery].map{$0["id"] == original["id"] ? bad : $0}
            try merge(receiver,document,records.filter{$0["kind"] != .string("event")}+phases)
            let home=start["data"]["space_id"],profile=try receiver.execute("profile.create",params:["space_id":home,"name":.string("Raw phase reader")]),access=AccessContext.agent(token:profile["token"].stringValue!)
            let snapshot=try receiver.execute("snapshot",context:access)
            XCTAssertFalse(snapshot["events"].arrayValue.contains{$0["id"] == bad["data"]["id"]})
            for kind in ["event","source"] { XCTAssertThrowsError(try receiver.execute("read",params:["kind":.string(kind),"id":bad["data"]["id"]],context:access)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") } }
            let session=try receiver.execute("read",params:["kind":.string("session"),"id":bad["data"]["session_id"]],context:access)
            XCTAssertFalse(session["events"].arrayValue.contains{$0["id"] == bad["data"]["id"]})
            XCTAssertTrue(try receiver.execute("search",params:["query":.string(marker),"scope":.string("history")],context:access)["results"].arrayValue.isEmpty)
            XCTAssertEqual(try receiver.entity("event",bad["data"]["id"].stringValue!),bad["data"],"Owner raw record is retained")
            if phase == "end" {
                XCTAssertEqual(snapshot["counts"]["events"].intValue,1,"Only valid START is counted; delivery waits for accepted END")
                XCTAssertEqual(try receiver.execute("read",params:["kind":.string("event"),"id":start["data"]["id"]],context:access)["id"],start["data"]["id"])
                XCTAssertEqual(try receiver.entity("interaction",start["data"]["interaction_id"].stringValue!)?["state"],.string("in_progress"))
            }
        }
    }
    func testVersionFourReopenValidatesOldRawEndWithoutReplacingItOnOwnerDeath() throws {
        let document=try actualReplica(),records=document["records"].arrayValue,receiver=try store()
        let child=Process();child.executableURL=URL(fileURLWithPath:"/usr/bin/true");try child.run();let exitedPID=child.processIdentifier;child.waitUntilExit()
        let start=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("start") && $0["data"]["method"] == .string("note.create")})
        let end=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"]})
        func localIdentity(_ value:inout [String:JSONValue]) { value["owner_device_id"] = .string(receiver.deviceID);value["owner_pid"] = .number(Double(exitedPID));value["adapter_pid"] = .number(Double(exitedPID)) }
        let localStart=try changed(start,store:receiver){localIdentity(&$0)}
        let malformed=try changed(end,store:receiver){localIdentity(&$0);$0["finished_at"] = .null}
        try merge(receiver,document,records.filter{$0["kind"] != .string("event")}+[localStart,malformed])
        let callID=start["data"]["interaction_id"].stringValue!
        var old=try XCTUnwrap(receiver.entity("interaction",callID)).objectValue
        old.removeValue(forKey:"valid_event_ids");old.removeValue(forKey:"has_untrusted_execution_end")
        try receiver.put("interaction",.object(old));try receiver.db.exec("UPDATE metadata SET value='3' WHERE key='interaction_projection_version'")
        let raw=try receiver.replicaDocument()["records"],pending=try receiver.db.rows("SELECT record_id FROM outbox ORDER BY record_id")
        let reopened=try MioStore(directory:receiver.directory),call=try XCTUnwrap(reopened.entity("interaction",callID))
        XCTAssertEqual(call["valid_event_ids"],.array([start["data"]["id"]]));XCTAssertTrue(call["has_untrusted_execution_end"].boolValue)
        XCTAssertEqual(call["state"],.string("in_progress"));XCTAssertEqual(call["receipt"],.null)
        XCTAssertEqual(try reopened.replicaDocument()["records"],raw,"Do not fabricate a replacement END for the untrusted immutable record")
        XCTAssertEqual(try reopened.db.rows("SELECT record_id FROM outbox ORDER BY record_id"),pending)
        let profile=try reopened.execute("profile.create",params:["space_id":start["data"]["space_id"],"name":.string("Version4 reader")]),access=AccessContext.agent(token:profile["token"].stringValue!)
        XCTAssertThrowsError(try reopened.execute("read",params:["kind":.string("event"),"id":end["data"]["id"]],context:access)) { XCTAssertEqual(($0 as? MioError)?.code,"forbidden") }
    }
    func testProjectionMigrationRepairsContradictionAtomicallyWithoutChangingRawRecordsOrResurrectingPurge() throws {
        let document=try actualReplica(),records=document["records"].arrayValue,receiver=try store()
        let start=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("start")}), end=try XCTUnwrap(records.first{$0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"]})
        let altered=try changed(end,store:receiver){$0["request_fingerprint"] = .string(String(repeating:"b",count:64))}
        try merge(receiver,document,records.filter{$0["kind"] != .string("event")}+[altered,start])
        let callID=start["data"]["interaction_id"].stringValue!
        var broken=try XCTUnwrap(receiver.entity("interaction",callID)).objectValue
        broken["state"] = .string("completed");broken["receipt"] = end["data"]["receipt"];broken.removeValue(forKey:"integrity_state")
        try receiver.put("interaction",.object(broken));try receiver.db.exec("UPDATE metadata SET value='2' WHERE key='interaction_projection_version'")
        let raw=try receiver.replicaDocument()["records"],pending=try receiver.db.rows("SELECT record_id FROM outbox ORDER BY record_id"),sessions=try receiver.all("session")
        try receiver.db.exec("CREATE TRIGGER projection_abort BEFORE INSERT ON entities WHEN NEW.kind='interaction' BEGIN SELECT RAISE(ABORT,'projection migration failure'); END")
        XCTAssertThrowsError(try MioStore(directory:receiver.directory))
        XCTAssertEqual(try receiver.entity("interaction",callID),.object(broken));XCTAssertEqual(try receiver.db.rows("SELECT value FROM metadata WHERE key='interaction_projection_version'").first?["value"],"2")
        try receiver.db.exec("DROP TRIGGER projection_abort")
        let repaired=try MioStore(directory:receiver.directory)
        XCTAssertEqual(try repaired.entity("interaction",callID)?["state"],.string("invalid"));XCTAssertEqual(try repaired.entity("interaction",callID)?["receipt"],.null)
        XCTAssertEqual(try repaired.db.rows("SELECT value FROM metadata WHERE key='interaction_projection_version'").first?["value"],"4")
        XCTAssertEqual(try repaired.replicaDocument()["records"],raw);XCTAssertEqual(try repaired.db.rows("SELECT record_id FROM outbox ORDER BY record_id"),pending);XCTAssertEqual(try repaired.all("session"),sessions)
        _=try repaired.execute("history.purge",params:["session_id":start["data"]["session_id"]])
        try repaired.db.exec("UPDATE metadata SET value='2' WHERE key='interaction_projection_version'")
        let purged=try MioStore(directory:receiver.directory);try merge(purged,document,[altered,start])
        XCTAssertNil(try purged.entity("interaction",callID));XCTAssertNil(try purged.entity("event",start["data"]["id"].stringValue!))
    }
    private func assertActualProjection(_ store: MioStore, _ records: [JSONValue], file: StaticString = #filePath, line: UInt = #line) throws {
        let events = records.filter { $0["kind"] == .string("event") }.map { $0["data"] }
        for start in events where start["phase"] == .string("start") {
            let end = try XCTUnwrap(events.first { $0["interaction_id"] == start["interaction_id"] && $0["phase"] == .string("end") })
            let call = try XCTUnwrap(store.entity("interaction", start["interaction_id"].stringValue!))
            XCTAssertEqual(call["start_event_id"], start["id"], file: file, line: line)
            XCTAssertEqual(call["end_event_id"], end["id"], file: file, line: line)
            XCTAssertEqual(call["state"], .string("completed"), file: file, line: line)
            for key in ["finished_at", "duration_ms", "observed_duration_ms", "outcome", "result_refs", "result_count", "receipt", "operation_id", "replayed"] {
                XCTAssertEqual(call[key], end[key], key, file: file, line: line)
            }
            let deliveries = events.filter { $0["interaction_id"] == start["interaction_id"] && $0["phase"] == .string("delivery") }.sorted {
                let left = $0["observed_at"].stringValue!, right = $1["observed_at"].stringValue!
                return left == right ? $0["id"].stringValue! < $1["id"].stringValue! : left < right
            }
            XCTAssertEqual(call["delivery_event_ids"], .array(deliveries.map { $0["id"] }), file: file, line: line)
            XCTAssertEqual(call["last_delivery_at"], deliveries.last?["observed_at"], file: file, line: line)
            XCTAssertEqual(call["response_delivery"], .string("socket_written"), file: file, line: line)
            XCTAssertEqual(call["adapter_delivery"], .string("stdout_written"), file: file, line: line)
        }
    }
    func testActualCloudRecordsConvergeAfterDeliveryFirstAndEndBeforeStart() throws {
        let document = try actualReplica(), records = document["records"].arrayValue
        let normal = try store(), reordered = try store()
        let foundations = records.filter { $0["kind"] != .string("event") }
        let events = records.filter { $0["kind"] == .string("event") }
        try merge(normal, document, foundations)
        for event in ordered(events) { try merge(normal, document, [event]) }
        try assertActualProjection(normal, records)

        try merge(reordered, document, foundations)
        let deliveries = events.filter { $0["data"]["phase"] == .string("delivery") }
        for event in ordered(deliveries).reversed() { try merge(reordered, document, [event]) }
        XCTAssertTrue(try reordered.all("interaction").isEmpty, "Delivery cannot invent execution completion")
        XCTAssertEqual(try reordered.execute("sync.pending")["pending_dependencies"].intValue, 6)
        for event in events.filter({ $0["data"]["phase"] == .string("end") }) { try merge(reordered, document, [event]) }
        for call in try reordered.all("interaction") {
            XCTAssertEqual(call["state"], .string("completed"))
            XCTAssertEqual(call["start_event_id"], .null)
        }
        for event in events.filter({ $0["data"]["phase"] == .string("start") }).reversed() { try merge(reordered, document, [event]) }
        try assertActualProjection(reordered, records)
        XCTAssertEqual(try reordered.all("interaction"), try normal.all("interaction"))
        let expected = try reordered.all("interaction")
        for _ in 0..<2 { try merge(reordered, document, Array(records.reversed())) }
        XCTAssertEqual(try reordered.all("interaction"), expected, "Repeated delivery or replica merge must converge")
        XCTAssertEqual(try reordered.all("event").count, 12)
        XCTAssertEqual(try reordered.execute("sync.pending")["pending_dependencies"].intValue, 0)
    }
    func testActualCloudRecordsRepairOldDerivedProjectionOnReopenWithoutNewRecords() throws {
        let document = try actualReplica(), records = document["records"].arrayValue, source = try store()
        try merge(source, document, ordered(records))
        let originalRecords = try source.replicaDocument()["records"]
        let session = try XCTUnwrap(source.all("session").first)
        for call in try source.all("interaction") {
            var broken = call.objectValue
            broken.removeValue(forKey: "start_event_id")
            broken["delivery_event_ids"] = .array([])
            broken["last_delivery_at"] = .string("2000-01-01T00:00:00.000Z")
            try source.put("interaction", .object(broken))
        }
        try source.db.exec("DELETE FROM metadata WHERE key='interaction_projection_version'")
        let pending = try source.db.rows("SELECT record_id FROM outbox ORDER BY record_id")
        let reopened = try MioStore(directory: source.directory)
        try assertActualProjection(reopened, records)
        XCTAssertEqual(try reopened.replicaDocument()["records"], originalRecords)
        XCTAssertEqual(try reopened.db.rows("SELECT record_id FROM outbox ORDER BY record_id"), pending)
        XCTAssertEqual(try reopened.entity("session", session["id"].stringValue!), session)
    }
    func testLateStartCannotDowngradeEndDependenciesOrExposeReceiptAfterMountRevocation() throws {
        let document = try actualReplica(), records = document["records"].arrayValue, receiver = try store()
        let start = try XCTUnwrap(records.first { $0["data"]["phase"] == .string("start") && $0["data"]["method"] == .string("note.create") })
        let originalEnd = try XCTUnwrap(records.first { $0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"] })
        let home = start["data"]["space_id"]
        try merge(receiver, document, records.filter { $0["kind"] != .string("event") })
        let privateSpace = try receiver.execute("space.create", params: ["name": .string("Private END dependency")])["id"]
        let end = try changed(originalEnd, store: receiver) {
            $0["required_space_ids"] = .array([home, privateSpace])
            $0["target_space_ids"] = .array([home, privateSpace])
        }
        let profile = try receiver.execute("profile.create", params: ["space_id": home, "name": .string("Restricted reader")])
        let access = AccessContext.agent(token: profile["token"].stringValue!)
        let deliveries = records.filter { $0["data"]["phase"] == .string("delivery") && $0["data"]["interaction_id"] == start["data"]["interaction_id"] }
        try merge(receiver, document, deliveries)
        try merge(receiver, document, [end])
        try merge(receiver, document, [start])
        let callID = start["data"]["interaction_id"].stringValue!
        let call = try XCTUnwrap(receiver.entity("interaction", callID))
        XCTAssertEqual(call["receipt"], originalEnd["data"]["receipt"])
        XCTAssertEqual(Set(call["required_space_ids"].arrayValue.compactMap(\.stringValue)), Set([home.stringValue!, privateSpace.stringValue!]))
        XCTAssertEqual(Set(call["target_space_ids"].arrayValue.compactMap(\.stringValue)), Set([home.stringValue!, privateSpace.stringValue!]))
        XCTAssertFalse(try receiver.execute("snapshot", context: access)["interactions"].arrayValue.contains { $0["id"] == .string(callID) })
        let mount = try receiver.execute("connection.create", params: ["from_space_id": home, "to_space_id": privateSpace, "access": .string("read")])
        XCTAssertTrue(try receiver.execute("snapshot", context: access)["interactions"].arrayValue.contains { $0["id"] == .string(callID) })
        _ = try receiver.execute("connection.delete", params: ["connection_id": mount["id"]])
        try receiver.db.exec("DELETE FROM metadata WHERE key='interaction_projection_version'")
        let reopened = try MioStore(directory: receiver.directory)
        XCTAssertEqual(try reopened.entity("interaction", callID), call)
        XCTAssertFalse(try reopened.execute("snapshot", context: access)["interactions"].arrayValue.contains { $0["id"] == .string(callID) })
    }
    func testErrorAndInterruptedEndsRemainFinalAfterLateStartAndDelivery() throws {
        let document = try actualReplica(), records = document["records"].arrayValue
        let start = try XCTUnwrap(records.first { $0["data"]["phase"] == .string("start") })
        let end = try XCTUnwrap(records.first { $0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"] })
        let deliveries = records.filter { $0["data"]["phase"] == .string("delivery") && $0["data"]["interaction_id"] == start["data"]["interaction_id"] }
        for outcome in ["error", "revision_conflict", "interrupted"] {
            let receiver = try store()
            let changedEnd = try changed(end, store: receiver) {
                $0["outcome"] = .string(outcome)
                $0["error_code"] = .string(outcome == "interrupted" ? "owner_process_terminated" : outcome)
                $0["receipt"] = .null; $0["operation_id"] = .null; $0["result_refs"] = .array([])
                if outcome == "interrupted" { $0["finished_at"] = .null; $0["duration_ms"] = .null }
            }
            let changedDeliveries = try deliveries.map { record in try changed(record, store: receiver) {
                $0["outcome"] = .string(outcome); $0["receipt"] = .null; $0["operation_id"] = .null
            } }
            try merge(receiver, document, records.filter { $0["kind"] != .string("event") })
            try merge(receiver, document, changedDeliveries)
            try merge(receiver, document, [changedEnd])
            let before = try XCTUnwrap(receiver.entity("interaction", start["data"]["interaction_id"].stringValue!))
            try merge(receiver, document, [start])
            let after = try XCTUnwrap(receiver.entity("interaction", start["data"]["interaction_id"].stringValue!))
            XCTAssertEqual(after["start_event_id"], start["data"]["id"])
            XCTAssertEqual(after["state"], .string(outcome == "interrupted" ? "interrupted" : "failed"))
            for key in ["end_event_id", "outcome", "error_code", "finished_at", "duration_ms", "observed_duration_ms", "receipt", "operation_id", "result_refs", "response_delivery", "adapter_delivery", "delivery_event_ids", "last_delivery_at"] {
                XCTAssertEqual(after[key], before[key], key)
            }
            XCTAssertEqual(after["receipt"], .null)
        }
    }
    func testMalformedImportedPhaseOrEndCannotInventSuccessfulExecution() throws {
        let document = try actualReplica(), records = document["records"].arrayValue
        let start = try XCTUnwrap(records.first { $0["data"]["phase"] == .string("start") })
        let end = try XCTUnwrap(records.first { $0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == start["data"]["interaction_id"] })
        for change in ["phase", "outcome", "finished_at", "error_code", "required_space_ids"] {
            let receiver = try store()
            let malformed = try changed(end, store: receiver) {
                switch change {
                case "phase": $0["phase"] = .string("not_an_execution_end")
                case "outcome": $0["outcome"] = .string("unrecognized")
                case "finished_at": $0["finished_at"] = .null
                case "error_code": $0["error_code"] = .string("operation_failed")
                default: $0["required_space_ids"] = .string("malformed")
                }
            }
            try merge(receiver, document, records.filter { $0["kind"] != .string("event") })
            try merge(receiver, document, [malformed])
            XCTAssertNil(try receiver.entity("interaction", start["data"]["interaction_id"].stringValue!))
            try merge(receiver, document, [start])
            let call = try XCTUnwrap(receiver.entity("interaction", start["data"]["interaction_id"].stringValue!))
            XCTAssertEqual(call["state"], .string("in_progress"))
            XCTAssertEqual(call["end_event_id"], .null)
            XCTAssertEqual(call["receipt"], .null)
        }
    }
    func testMultipleDeliveryObservationsChooseLatestPerOriginWithStableTieOrder() throws {
        let document = try actualReplica(), records = document["records"].arrayValue, normal = try store(), reversed = try store()
        let delivery = try XCTUnwrap(records.first { $0["data"]["observation_type"] == .string("server_observed") })
        var additional: [JSONValue] = []
        for state in ["frame_too_large", "socket_write_failed"] {
            var value: [String: JSONValue] = try changed(delivery, store: normal) {
                let sourceID = $0["interaction_id"]!.stringValue! + ":delivery:server_observed:" + state
                $0["source_id"] = .string(sourceID)
                $0["id"] = .string("event-" + normal.hash(Data(($0["session_id"]!.stringValue! + "\u{0}initial\u{0}" + sourceID).utf8)))
                $0["delivery_state"] = .string(state)
                $0["observed_at"] = .string("2026-10-11T14:02:22.000Z")
                $0["timestamp"] = $0["observed_at"]
            }.objectValue
            value.removeValue(forKey: "content_hash")
            value["id"] = .string("additional-delivery-" + state)
            value["entity_id"] = value["data"]?["id"]
            value["content_hash"] = .string(normal.hash(try JSONValue.object(value).encoded()))
            additional.append(.object(value))
        }
        try merge(normal, document, records + additional)
        try merge(reversed, document, Array((records + additional).reversed()))
        let callID = delivery["data"]["interaction_id"].stringValue!, call = try XCTUnwrap(normal.entity("interaction", callID))
        XCTAssertEqual(try reversed.entity("interaction", callID), call)
        let winning = additional.max { $0["data"]["id"].stringValue! < $1["data"]["id"].stringValue! }!["data"]
        XCTAssertEqual(call["response_delivery"], winning["delivery_state"])
        XCTAssertEqual(call["adapter_delivery"], .string("stdout_written"))
        XCTAssertEqual(call["last_delivery_at"], winning["observed_at"])
        XCTAssertEqual(call["delivery_event_ids"].arrayValue.count, 4)
        XCTAssertEqual(call["state"], .string("completed"))
        let execution = try XCTUnwrap(records.first { $0["data"]["phase"] == .string("end") && $0["data"]["interaction_id"] == delivery["data"]["interaction_id"] })
        XCTAssertEqual(call["receipt"], execution["data"]["receipt"])
        try merge(reversed, document, records + additional)
        XCTAssertEqual(try reversed.entity("interaction", callID), call)
    }
    func testProjectionMigrationKeepsLiveInProgressOwnerAndPurgedSourcesErased() throws {
        let receiver = try store(), home = try receiver.execute("space.create", params: ["name": .string("Live memory")])["id"]
        let profile = try receiver.execute("profile.create", params: ["space_id": home, "name": .string("Live agent")])
        let access = AccessContext.agent(token: profile["token"].stringValue!)
        let metadata: JSONValue = .object(["transport_session_id": .string("live-projection-migration"), "request_id": .string("still-running")])
        let request = try receiver.execute("interaction.call.begin", params: ["method": .string("search"), "_mio_interaction": metadata], context: access)
        let callID = request["interaction_id"].stringValue!
        let before = try XCTUnwrap(receiver.entity("interaction", callID)), recordsBefore = try receiver.replicaDocument()["records"]
        try receiver.db.exec("DELETE FROM metadata WHERE key='interaction_projection_version'")
        let reopened = try MioStore(directory: receiver.directory)
        XCTAssertEqual(try reopened.entity("interaction", callID), before)
        XCTAssertEqual(try reopened.replicaDocument()["records"], recordsBefore)
        XCTAssertEqual(before["state"], .string("in_progress"))
        XCTAssertEqual(before["end_event_id"], .null)

        let document = try actualReplica(), source = try store()
        try merge(source, document, document["records"].arrayValue)
        let sessionID = try XCTUnwrap(source.all("session").first?["id"])
        _ = try source.execute("history.purge", params: ["session_id": sessionID])
        XCTAssertTrue(try source.all("interaction").isEmpty)
        try source.db.exec("DELETE FROM metadata WHERE key='interaction_projection_version'")
        let purged = try MioStore(directory: source.directory)
        try merge(purged, document, document["records"].arrayValue)
        XCTAssertTrue(try purged.all("interaction").isEmpty)
        XCTAssertTrue(try purged.all("event").isEmpty)
    }
}
