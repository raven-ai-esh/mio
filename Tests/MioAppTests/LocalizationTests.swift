import XCTest
import Foundation
import MioCore
@testable import Mio

final class LocalizationTests: XCTestCase {
    func testSystemResolutionAndExplicitOverrides() {
        XCTAssertEqual(MioLanguage.system.resolved(preferredLanguages:["ru-RU","en-US"]),"ru")
        XCTAssertEqual(MioLanguage.system.resolved(preferredLanguages:["en-GB","ru"]),"en")
        XCTAssertEqual(MioLanguage.system.resolved(preferredLanguages:["fr"]),"en")
        XCTAssertEqual(MioLanguage.english.resolved(preferredLanguages:["ru"]),"en")
        XCTAssertEqual(MioLanguage.russian.resolved(preferredLanguages:["en"]),"ru")
    }
    func testCatalogAndFormattedMessages() {
        let en = MioLocalizer(language:.english), ru = MioLocalizer(language:.russian)
        XCTAssertEqual(en.text("Заметки"),"Notes"); XCTAssertEqual(ru.text("Заметки"),"Заметки")
        XCTAssertEqual(en.text("%@ выделено · %@ приглушено",["3","5"]),"3 highlighted · 5 dimmed")
        XCTAssertEqual(ru.text("%@ выделено · %@ приглушено",["3","5"]),"3 выделено · 5 приглушено")
        XCTAssertEqual(en.text("Interface language"),"Interface language"); XCTAssertEqual(ru.text("Interface language"),"Язык интерфейса")
        let unknown = "USER_NOTE_Название [[Keep this exact]]"; XCTAssertEqual(en.text(unknown),unknown)
        var notice: MioLocalizedMessage = "Импорт завершён"; notice += ": \(2) предупреждений"
        XCTAssertEqual(notice.rendered(using:en),"Import completed: 2 warnings")
        XCTAssertEqual(notice.rendered(using:ru),"Импорт завершён: 2 предупреждений")
        let installed: MioLocalizedMessage = "Подключение \("sample-profile") установлено. Оно появится в новых сессиях Codex."
        XCTAssertEqual(installed.rendered(using:en),"Connection sample-profile installed. It will appear in new Codex sessions.")
    }
    func testLegacyPreferencesAndLanguageRoundTripPreserveDraftAndScope() throws {
        let original = """
        {"selectedSpace":"space-keep","selectedNote":"note-keep","cloudFolder":"folder-keep","drafts":{"note-keep":{"title":"Исходное название","body":"UNSAVED [[Exact]]","revision":"revision-keep","status":"hypothesis"}}}
        """
        var preferences = try JSONDecoder().decode(MioPreferences.self,from:Data(original.utf8))
        XCTAssertEqual(preferences.interfaceLanguage,"system")
        let draft = preferences.drafts["note-keep"]
        for language in ["en","ru","system"] {
            preferences.interfaceLanguage = language
            let restored = try JSONDecoder().decode(MioPreferences.self,from:JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.interfaceLanguage,language); XCTAssertEqual(restored.selectedSpace,"space-keep"); XCTAssertEqual(restored.selectedNote,"note-keep"); XCTAssertEqual(restored.cloudFolder,"folder-keep")
            XCTAssertEqual(restored.drafts["note-keep"]?.title,draft?.title); XCTAssertEqual(restored.drafts["note-keep"]?.body,draft?.body); XCTAssertEqual(restored.drafts["note-keep"]?.revision,draft?.revision)
        }
        let malformed = try JSONDecoder().decode(MioPreferences.self,from:Data("{\"interfaceLanguage\":42,\"selectedSpace\":\"space-keep\"}".utf8))
        XCTAssertEqual(malformed.interfaceLanguage,"system"); XCTAssertEqual(malformed.selectedSpace,"space-keep")
    }
    func testDatesFollowInterfaceLocaleWithoutChangingStoredTimestamp() {
        let value = MioCore.JSONValue.string("2026-10-13T09:30:00Z")
        let en = MioFormat.date(value,locale:Locale(identifier:"en_US")), ru = MioFormat.date(value,locale:Locale(identifier:"ru_RU"))
        XCTAssertTrue(en.contains("Oct")); XCTAssertTrue(ru.contains("окт")); XCTAssertEqual(value.stringValue,"2026-10-13T09:30:00Z")
    }
    func testMalformedArchiveErrorUsesInterfaceLanguageAndPreservesMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MioStore(directory: directory)
        let space = try store.execute("space.create", params: ["name": .string("Keep exact")])
        let note = try store.execute("note.create", params: ["space_id": space["id"], "title": .string("Keep exact"), "body": .string("UNCHANGED [[Original]]")])
        let malformed = directory.appendingPathComponent("invalid.mioarchive")
        try Data("{".utf8).write(to: malformed)
        do {
            _ = try store.execute("archive.import", params: ["path": .string(malformed.path), "mode": .string("merge")])
            XCTFail("Malformed archive must fail")
        } catch {
            let key = MioLocalizer.errorKey(for: error)
            XCTAssertEqual(MioLocalizer(language: .english).text(key), "Couldn't read the data. The file is damaged or has an invalid format.")
            XCTAssertEqual(MioLocalizer(language: .russian).text(key), "Не удалось прочитать данные: файл повреждён или имеет неверный формат.")
        }
        XCTAssertEqual(try store.execute("read", params: ["kind": .string("note"), "id": note["id"]])["body"], .string("UNCHANGED [[Original]]"))
    }
}
