import XCTest
@testable import MioCore

extension MioCoreTests {
    func testMoveRetainsIdentityVersionsLinksAndScopedSearch() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B")
        let target=try note(db,a,"C","original target"),n=try note(db,a,"Moving","quasar evidence [[C]]")
        _=try note(db,b,"C","different target")
        let edge=try XCTUnwrap(try call(db,"read",["id":n["id"]])["links"].arrayValue.first)
        let pa=try call(db,"profile.create",["space_id":a,"name":.string("A")]),pb=try call(db,"profile.create",["space_id":b,"name":.string("B")])
        let ca=AccessContext.agent(token:pa["token"].stringValue!),cb=AccessContext.agent(token:pb["token"].stringValue!)
        let job=try XCTUnwrap(db.nextSourceIndexJob(modelID:"lexical-native-v1"));_ = try db.publishSourceIndex(job:job,documents:db.sourceDocuments(job:job))
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let moved=try call(db,"read",["id":n["id"]],cb)
        XCTAssertEqual(moved["id"],n["id"]);XCTAssertEqual(moved["revision_id"],n["revision_id"]);XCTAssertEqual(moved["space_id"],b)
        XCTAssertThrowsError(try call(db,"read",["id":n["id"]],ca))
        XCTAssertEqual(try call(db,"read",["kind":.string("source"),"id":n["revision_id"]],cb)["space_id"],b)
        XCTAssertTrue(try call(db,"search",["query":.string("quasar"),"scope":.string("notes")],ca)["results"].arrayValue.isEmpty)
        XCTAssertFalse(try call(db,"search",["query":.string("quasar"),"scope":.string("notes")],cb)["results"].arrayValue.isEmpty)
        _=try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("quasar evidence [[C]] updated")],cb)
        XCTAssertEqual(try call(db,"note.history",["note_id":n["id"]],cb)["revisions"].arrayValue.count,2)
        let rawEdge=try XCTUnwrap(db.entity("link",edge["id"].stringValue!))
        XCTAssertFalse(rawEdge["deleted"].boolValue);XCTAssertEqual(rawEdge["to_note_id"],target["id"])
        _=try call(db,"connection.create",["from_space_id":b,"to_space_id":a,"access":.string("read")])
        XCTAssertEqual(try call(db,"read",["id":n["id"]],cb)["links"].arrayValue.first?["id"],edge["id"])
        let current=try call(db,"read",["id":n["id"]],cb)
        _=try call(db,"note.update",["note_id":n["id"],"expected_revision":current["revision_id"],"body":.string("quasar evidence updated")],cb)
        XCTAssertTrue(try XCTUnwrap(db.entity("link",edge["id"].stringValue!))["deleted"].boolValue)
    }
    func testBulkIsAtomicWithStaleSelectionAndDeleteCanRestore() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),n=try note(db,a),second=try note(db,a,"Second")
        XCTAssertThrowsError(try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"],.string("missing")]),"space_id":b]))
        XCTAssertEqual(try call(db,"read",["id":n["id"]])["space_id"],a)
        XCTAssertThrowsError(try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b,"expected_spaces":.object([n["id"].stringValue!:b])]))
        _=try call(db,"notes.bulk",["action":.string("status"),"status":.string("confirmed"),"note_ids":.array([n["id"],second["id"]])])
        XCTAssertEqual(try call(db,"read",["id":n["id"]])["status"],.string("confirmed"))
        let removed=try call(db,"notes.bulk",["action":.string("delete"),"note_ids":.array([n["id"],second["id"]])])
        XCTAssertEqual(removed["changed_count"].intValue,2)
        XCTAssertEqual(try call(db,"notes.bulk",["action":.string("delete"),"note_ids":.array([n["id"],second["id"]])])["changed_count"].intValue,0)
        _=try call(db,"note.restore",["note_id":n["id"],"revision_id":n["revision_id"]])
        XCTAssertEqual(try call(db,"read",["id":n["id"]])["body"],.string("source truth"))
    }
    func testMoveSurvivesArchiveAndLateOriginEditsWithoutGrantingOldSources() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),secret=try note(db,a,"Secret"),n=try call(db,"note.create",["space_id":a,"title":.string("Movable"),"body":.string("kept"),"source_ids":.array([secret["id"]])])
        let offline=try store();_=try call(offline,"replica.merge",["document":try call(db,"replica.export")])
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        _=try call(offline,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("late edit")])
        _=try call(db,"replica.merge",["document":try call(offline,"replica.export")])
        XCTAssertEqual(try call(db,"read",["id":n["id"]])["space_id"],b)
        let p=try call(db,"profile.create",["space_id":b,"name":.string("B")]),ctx=AccessContext.agent(token:p["token"].stringValue!)
        let current=try call(db,"read",["id":n["id"]],ctx)
        XCTAssertTrue(current["source_ids"].arrayValue.isEmpty)
        _=try call(db,"note.update",["note_id":n["id"],"expected_revision":current["revision_id"],"title":.string("edited in B")],ctx)
        XCTAssertThrowsError(try call(db,"read",["id":secret["id"]],ctx))
        let archive=try directory().appendingPathComponent("moving.mio");_=try call(db,"archive.export",["path":.string(archive.path)])
        let restored=try store();_=try call(restored,"archive.import",["path":.string(archive.path),"mode":.string("restore")])
        XCTAssertEqual(try call(restored,"read",["id":n["id"]])["space_id"],b)
        XCTAssertEqual(try call(restored,"note.history",["note_id":n["id"]])["revisions"].arrayValue.count,3)
    }
}

extension MioCoreTests {
    func testLegacyAssetsArePinnedPerMoveAndReimportDoesNotDuplicateNote() throws {
        let db=try store(),a=try space(db,"Imports"),b=try space(db,"Personal"),vault=try directory()
        try FileManager.default.createDirectory(at:vault.appendingPathComponent("Files"),withIntermediateDirectories:true)
        let asset=vault.appendingPathComponent("Files/spec sheet.txt"),source=vault.appendingPathComponent("Imported.md")
        try Data("ORIGINAL_BYTES".utf8).write(to:asset)
        try Data("[Manual](Files/spec%20sheet.txt)".utf8).write(to:source)
        try Data("unrelated".utf8).write(to:vault.appendingPathComponent("unrelated.txt"))
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        let n=try XCTUnwrap(try call(db,"snapshot")["notes"].arrayValue.first)
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let moved=try call(db,"read",["id":n["id"]])
        XCTAssertEqual(moved["asset_ids"].arrayValue.count,1)
        let pin=try XCTUnwrap(db.entity("attachment",moved["asset_ids"].arrayValue[0].stringValue!))
        XCTAssertEqual(Data(base64Encoded:pin["bytes"].stringValue!),Data("ORIGINAL_BYTES".utf8))
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        XCTAssertEqual(try call(db,"snapshot")["counts"]["notes"].intValue,1)
        XCTAssertEqual(try call(db,"read",["id":n["id"]])["space_id"],b)
        // Later edits of the shared original asset cannot change the moved copy.
        try Data("LATER_ORIGIN_BYTES".utf8).write(to:asset)
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        let out=try directory(),export=try call(db,"markdown.export",["path":.string(out.path),"space_ids":.array([b])])
        XCTAssertEqual(export["attachments"].intValue,1)
        let exported=out.appendingPathComponent(b.stringValue!+"/Files/spec sheet.txt")
        XCTAssertEqual(try Data(contentsOf:exported),Data("ORIGINAL_BYTES".utf8))
        XCTAssertTrue(export["warnings"].arrayValue.isEmpty)
    }
    func testConcurrentMovesConvergeAndSchemaOneStillImports() throws {
        let a=try store(),origin=try space(a,"Origin"),left=try space(a,"Left"),right=try space(a,"Right"),n=try note(a,origin)
        var legacy=try call(a,"replica.export").objectValue;legacy["schema_version"] = .number(1)
        let b=try store();_=try call(b,"replica.merge",["document":.object(legacy)])
        _=try call(a,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":left])
        _=try call(b,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":right])
        let da=try call(a,"replica.export"),db=try call(b,"replica.export")
        _=try call(a,"replica.merge",["document":db]);_=try call(b,"replica.merge",["document":da])
        XCTAssertEqual(try call(a,"read",["id":n["id"]])["space_id"],try call(b,"read",["id":n["id"]])["space_id"])
        let again=try call(a,"replica.merge",["document":db]);XCTAssertEqual(again["imported_records"].intValue,0)
        XCTAssertEqual(try call(a,"diagnostics")["schema_version"].intValue,2)
    }
}

extension MioCoreTests {
    func testEditedBeforeMoveSchedulesNewIndexAndSchemaUpgradeKeepsOnlyCurrentJobs() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),n=try note(db,a,"Index","first evidence")
        let job=try XCTUnwrap(db.nextSourceIndexJob(modelID:"lexical-native-v1"));_=try db.publishSourceIndex(job:job,documents:db.sourceDocuments(job:job))
        _=try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("fresh evidence")])
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let next=try XCTUnwrap(db.nextSourceIndexJob(modelID:"lexical-native-v1"));XCTAssertEqual(next["note"]["body"],.string("fresh evidence"));XCTAssertEqual(next["note"]["space_id"],b)
        _=try db.publishSourceIndex(job:next,documents:db.sourceDocuments(job:next))
        let old=next["note"],model="lexical-native-v1"
        let signature=db.hash(try JSONValue.object(["note_id":old["id"],"revision_id":old["revision_id"],"file_ids":old["file_ids"],"extractor":.string(MioDocumentExtraction.version),"model":.string(model)]).encoded())
        try db.db.exec("UPDATE source_index_jobs SET signature=?",[signature])
        try db.upgradeSourceIndexLocationSignatures()
        XCTAssertNil(try db.nextSourceIndexJob(modelID:model)) // A matching schema1 job keeps its vectors.
        _=try call(db,"note.update",["note_id":n["id"],"expected_revision":next["note"]["revision_id"],"body":.string("newest evidence")])
        try db.db.exec("UPDATE source_index_jobs SET signature=?",[signature])
        try db.upgradeSourceIndexLocationSignatures()
        XCTAssertNotNil(try db.nextSourceIndexJob(modelID:model)) // A stale schema1 job is not promoted.
    }
    func testReimportedNewAssetFollowsAnotherMoveAndPinnedKindCannotDowngrade() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),c=try space(db,"C"),vault=try directory()
        try Data("old bytes".utf8).write(to:vault.appendingPathComponent("old.txt"))
        let page=vault.appendingPathComponent("Page.md");try Data("[Old](old.txt)".utf8).write(to:page)
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        let n=try XCTUnwrap(try call(db,"snapshot")["notes"].arrayValue.first)
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        try Data("new bytes".utf8).write(to:vault.appendingPathComponent("new.txt"));try Data("[Old](old.txt)\n[New](new.txt)".utf8).write(to:page)
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":c])
        let moved=try call(db,"read",["id":n["id"]]);XCTAssertEqual(moved["asset_ids"].arrayValue.count,2)
        let out=try directory();XCTAssertEqual(try call(db,"markdown.export",["path":.string(out.path),"space_ids":.array([c])])["attachments"].intValue,2)
        XCTAssertEqual(try Data(contentsOf:out.appendingPathComponent(c.stringValue!+"/new.txt")),Data("new bytes".utf8))
        let id=moved["asset_ids"].arrayValue[0].stringValue!,pin=try XCTUnwrap(db.entity("attachment",id));var payload=pin.objectValue
        payload["kind"] = .string("legacy");payload["bytes"] = .string(Data("forged".utf8).base64EncodedString());payload["sha256"] = .string(db.hash(Data("forged".utf8)))
        var record:[String:JSONValue] = ["id":.string(UUID().uuidString),"kind":.string("attachment"),"entity_id":.string(id),"timestamp":.string("2099-01-01T00:00:00Z"),"device_id":.string("test"),"data":.object(payload)]
        record["content_hash"] = .string(db.hash(try JSONValue.object(record).encoded()))
        XCTAssertThrowsError(try call(db,"replica.merge",["document":.object(["schema_version":.number(2),"format":.string("mio-records"),"records":.array([.object(record)])])]))
        XCTAssertEqual(try db.entity("attachment",id)?["bytes"],pin["bytes"])
    }
}

extension MioCoreTests {
    func testAttachmentReimportCannotOverrideConcurrentExplicitMove() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),c=try space(db,"C"),vault=try directory()
        let page=vault.appendingPathComponent("Page.md")
        try Data("[Old](old.txt)".utf8).write(to:page);try Data("old".utf8).write(to:vault.appendingPathComponent("old.txt"))
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        let n=try XCTUnwrap(try call(db,"snapshot")["notes"].arrayValue.first)
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let peer=try store();_=try call(peer,"replica.merge",["document":try call(db,"replica.export")])
        _=try call(peer,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":c])
        try Data("new attachment".utf8).write(to:vault.appendingPathComponent("new.txt"));try Data("[Old](old.txt)\n[New](new.txt)".utf8).write(to:page)
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        _=try call(db,"replica.merge",["document":try call(peer,"replica.export")]);_=try call(peer,"replica.merge",["document":try call(db,"replica.export")])
        for owner in [db,peer] {
            XCTAssertEqual(try call(owner,"read",["id":n["id"]])["space_id"],c)
            let out=try directory();_=try call(owner,"markdown.export",["path":.string(out.path),"space_ids":.array([c])])
            let paths=try XCTUnwrap(FileManager.default.enumerator(at:out,includingPropertiesForKeys:nil)).allObjects.compactMap{$0 as? URL}
            XCTAssertTrue(paths.contains{(try? Data(contentsOf:$0)) == Data("new attachment".utf8)})
        }
    }
    func testPinnedRelativeAssetPrecedenceSurvivesNamespaceCollision() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),vault=try directory(),other=try directory()
        func write(_ root: URL,_ name: String,_ text: String) throws { let path=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:path) }
        try write(vault,"Files/spec.txt","root");try write(vault,"Notes/Files/spec.txt","local");try write(vault,"Notes/Page.md","[Historic](../Files/spec.txt)")
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        try write(vault,"Notes/Page.md","[Current](Files/spec.txt)");_=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        let n=try XCTUnwrap(try call(db,"snapshot")["notes"].arrayValue.first)
        try write(other,"Other.md","[Other](Notes/Files/spec.txt)");try write(other,"Notes/Files/spec.txt","unrelated")
        _=try call(db,"markdown.import",["path":.string(other.path),"space_id":b])
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let out=try directory();_=try call(db,"markdown.export",["path":.string(out.path),"space_ids":.array([b])])
        let page=out.appendingPathComponent(b.stringValue!+"/Notes/Page-"+n["id"].stringValue!+".md"),body=try String(contentsOf:page,encoding:.utf8),text=body as NSString
        let pattern=try NSRegularExpression(pattern:"\\[Current\\]\\(([^)]+)\\)")
        let match=try XCTUnwrap(pattern.firstMatch(in:body,range:NSRange(location:0,length:text.length)))
        let path=try XCTUnwrap(text.substring(with:match.range(at:1)).removingPercentEncoding)
        XCTAssertEqual(try Data(contentsOf:page.deletingLastPathComponent().appendingPathComponent(path)),Data("local".utf8))
    }
}

extension MioCoreTests {
    func testStaleMovedRevisionRetainsOpaqueSourcesWithoutAllowingNewForeignOnes() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),source=try note(db,a,"Foreign")
        let n=try call(db,"note.create",["space_id":a,"title":.string("Movable"),"body":.string("Original"),"source_ids":.array([source["id"]])])
        _=try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"source_ids":.array([])])
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let p=try call(db,"profile.create",["space_id":b,"name":.string("B")]),ctx=AccessContext.agent(token:p["token"].stringValue!)
        XCTAssertThrowsError(try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"body":.string("Preserved stale draft")],ctx)) { XCTAssertEqual(($0 as? MioError)?.code,"revision_conflict") }
        let history=try call(db,"note.history",["note_id":n["id"]],ctx)["revisions"].arrayValue
        XCTAssertEqual(history.count,3);XCTAssertTrue(history.allSatisfy{$0["source_ids"].arrayValue.isEmpty})
        let current=try call(db,"read",["id":n["id"]],ctx)
        XCTAssertThrowsError(try call(db,"note.update",["note_id":n["id"],"expected_revision":current["revision_id"],"source_ids":.array([source["id"],.string("forbidden-new-source")])],ctx))
    }
}

extension MioCoreTests {
    func testPurgeErasesOwnedPinnedAssetsAndLateReplicasCannotRestoreBytes() throws {
        let db=try store(),a=try space(db,"A"),b=try space(db,"B"),vault=try directory()
        let page=vault.appendingPathComponent("Page.md");try Data("[Private](private.txt)".utf8).write(to:page);try Data("SYNTHETIC_PRIVATE_BYTES".utf8).write(to:vault.appendingPathComponent("private.txt"))
        _=try call(db,"markdown.import",["path":.string(vault.path),"space_id":a])
        let n=try XCTUnwrap(try call(db,"snapshot")["notes"].arrayValue.first),session=try history(db,a)
        let event=try XCTUnwrap(try call(db,"read",["kind":.string("session"),"id":session["session_id"]])["events"].arrayValue.first)
        _=try call(db,"note.update",["note_id":n["id"],"expected_revision":n["revision_id"],"source_ids":.array([event["id"]])])
        _=try call(db,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let before=try call(db,"replica.export"),moved=try call(db,"read",["id":n["id"]]),pinID=try XCTUnwrap(moved["asset_ids"].arrayValue.first?.stringValue)
        _=try call(db,"history.purge",["session_id":session["session_id"]])
        XCTAssertEqual(try db.entity("attachment",pinID)?["bytes"],.string(""))
        let tombstones=try call(db,"replica.export")["records"].arrayValue.filter{["note.redact","session.purge"].contains($0["kind"].stringValue ?? "")}
        let late=try store();_=try call(late,"replica.merge",["document":.object(["schema_version":.number(2),"format":.string("mio-records"),"records":.array(tombstones)])]);_=try call(late,"replica.merge",["document":before])
        XCTAssertEqual(try late.entity("attachment",pinID)?["bytes"],.string(""))
        for owner in [db,late] {
            let out=try directory();_=try call(owner,"markdown.export",["path":.string(out.path),"space_ids":.array([b])])
            let paths=try XCTUnwrap(FileManager.default.enumerator(at:out,includingPropertiesForKeys:nil)).allObjects.compactMap{$0 as? URL}
            XCTAssertFalse(paths.contains{(try? Data(contentsOf:$0)) == Data("SYNTHETIC_PRIVATE_BYTES".utf8)})
        }
    }
}

extension MioCoreTests {
    func testConflictResolutionAndLaterEditUseChosenAttachmentBranch() throws {
        let left=try store(),a=try space(left,"A"),b=try space(left,"B"),vault=try directory(),page=vault.appendingPathComponent("Page.md")
        try Data("Initial".utf8).write(to:page);_=try call(left,"markdown.import",["path":.string(vault.path),"space_id":a])
        let n=try XCTUnwrap(try call(left,"snapshot")["notes"].arrayValue.first)
        _=try call(left,"notes.bulk",["action":.string("move"),"note_ids":.array([n["id"]]),"space_id":b])
        let right=try store();_=try call(right,"replica.merge",["document":try call(left,"replica.export")])
        try Data("LEFT_BYTES".utf8).write(to:vault.appendingPathComponent("left.txt"));try Data("[Left](left.txt)".utf8).write(to:page)
        _=try call(left,"markdown.import",["path":.string(vault.path),"space_id":a]);let chosen=try call(left,"read",["id":n["id"]])["revision_id"]
        try Data("RIGHT_BYTES".utf8).write(to:vault.appendingPathComponent("right.txt"));try Data("[Right](right.txt)".utf8).write(to:page)
        _=try call(right,"markdown.import",["path":.string(vault.path),"space_id":a])
        _=try call(left,"replica.merge",["document":try call(right,"replica.export")])
        let resolved=try call(left,"note.resolve",["note_id":n["id"],"revision_id":chosen])
        _=try call(left,"note.update",["note_id":n["id"],"expected_revision":resolved["revision_id"],"title":.string("Later edit")])
        let out=try directory();_=try call(left,"markdown.export",["path":.string(out.path),"space_ids":.array([b])])
        let paths=try XCTUnwrap(FileManager.default.enumerator(at:out,includingPropertiesForKeys:nil)).allObjects.compactMap{$0 as? URL}
        XCTAssertTrue(paths.contains{(try? Data(contentsOf:$0)) == Data("LEFT_BYTES".utf8)})
        XCTAssertFalse(paths.contains{(try? Data(contentsOf:$0)) == Data("RIGHT_BYTES".utf8)})
        XCTAssertEqual(try call(left,"read",["id":n["id"]])["body"],.string("[Left](left.txt)"))
    }
}
