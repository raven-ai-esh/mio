import Foundation
import MioCore

struct SessionPickerContext: Sendable, Equatable {
    var locale:Locale
    var timeZone:TimeZone
    var calendar:Calendar
    var fallbackName:String
}

/// Session ordering is derived when metadata changes, never while rendering a
/// row or its sidebar count. Date keys preserve offsets and fractional seconds.
struct SessionListProjection: Sendable {
    private var input: [JSONValue] = []
    private var dates: [String:Date] = [:]
    private var invalidDates=Set<String>()
    private(set) var opened: [JSONValue] = []
    private(set) var active: [JSONValue] = []
    private(set) var pickerLabels=[String:String]()
    private var labelRows:[JSONValue]=[],labelProfiles:[JSONValue]=[]
    private var labelContext:SessionPickerContext?
    private var labelEntries=[String:(raw:String,name:String,date:String,label:String)]()
    func hasSameRows(as other:Self) -> Bool { input == other.input }

    mutating func preparePickerLabels(profiles:[JSONValue],context:SessionPickerContext,force:Bool = false) {
        guard force || labelRows != input || labelProfiles != profiles || labelContext != context else { return }
        let names=Dictionary(profiles.map{($0.id,$0["name"].text)},uniquingKeysWith:{_,last in last})
        var next=[String:(raw:String,name:String,date:String,label:String)]()
        var style=Date.FormatStyle(date:.abbreviated,time:.shortened).locale(context.locale)
        style.calendar=context.calendar;style.timeZone=context.timeZone
        for session in opened {
            let id=session.id,raw=session["opened_at"].text,name=names[session["actor"].text] ?? context.fallbackName
            let dateText:String
            if !force,labelContext == context,let old=labelEntries[id],old.raw == raw { dateText=old.date }
            else if let date=dates[raw],!invalidDates.contains(raw) { dateText=date.formatted(style) }
            else { dateText=raw.isEmpty ? "—":String(raw.prefix(16)).replacingOccurrences(of:"T",with:" ") }
            let label:String
            if let old=labelEntries[id],old.name == name,old.date == dateText { label=old.label }
            else { label=name+" · "+dateText }
            next[id]=(raw,name,dateText,label)
        }
        pickerLabels=next.mapValues(\.label);labelEntries=next
        labelRows=input;labelProfiles=profiles;labelContext=context
    }

    mutating func update(_ rows: [JSONValue]) {
        guard rows != input else { return }
        input = rows
        let iso=ISO8601DateFormatter(),fractional=ISO8601DateFormatter()
        fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var used=Set<String>()
        func date(_ value:JSONValue) -> Date {
            let raw=value.stringValue ?? ""
            used.insert(raw)
            if let cached=dates[raw] { return cached }
            let result=(raw.contains(".") ? fractional.date(from:raw):iso.date(from:raw)) ?? iso.date(from:raw) ?? fractional.date(from:raw)
            if result == nil { invalidDates.insert(raw) }
            dates[raw]=result ?? .distantPast
            return result ?? .distantPast
        }
        let keyed=rows.filter { !$0["deleted"].boolValue && !$0["purged"].boolValue && $0["source"].stringValue == "memory_operations_v1" }.map { ($0,date($0["opened_at"]),date($0["updated_at"])) }
        opened=keyed.sorted { $0.1 == $1.1 ? ($0.0["id"].stringValue ?? "") < ($1.0["id"].stringValue ?? ""):$0.1 > $1.1 }.map(\.0)
        active=keyed.sorted { $0.2 == $1.2 ? ($0.0["id"].stringValue ?? "") < ($1.0["id"].stringValue ?? ""):$0.2 > $1.2 }.map(\.0)
        dates=dates.filter { used.contains($0.key) }
        invalidDates.formIntersection(used)
    }
}
