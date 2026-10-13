import Foundation

enum MioLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", russian = "ru"
    var id: String { rawValue }
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        return Bundle.preferredLocalizations(from: ["en","ru"], forPreferences: preferredLanguages).first ?? "en"
    }
    var locale: Locale { Locale(identifier: resolved() == "ru" ? "ru_RU" : "en_US") }
}

struct MioLocalizer {
    var language: MioLanguage
    static func errorKey(for error: Error) -> String {
        if error is DecodingError { return "Не удалось прочитать данные: файл повреждён или имеет неверный формат." }
        return error.localizedDescription
    }
    private static var resources: Bundle {
        if let url = Bundle.main.url(forResource: "Mio_Mio", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return .module
    }
    func text(_ key: String, _ arguments: [String] = []) -> String {
        let path = Self.resources.path(forResource: language.resolved(), ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? Self.resources
        let translated = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? translated : String(format: translated, locale: language.locale, arguments: arguments.map { $0 as CVarArg })
    }
}

// Notices keep their key and arguments, so changing the language also updates
// an existing status without rewriting memory or clearing a pending message.
struct MioLocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var key: String
    var arguments: [String] = []
    private var suffixes: [MioLocalizedMessage] = []
    var isEmpty: Bool { key.isEmpty }
    init(stringLiteral value: String) { key = value }
    init(stringInterpolation value: StringInterpolation) { key = value.key; arguments = value.arguments }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
        mutating func appendLiteral(_ value: String) { key += value }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
    }
    static func += (left: inout Self, right: Self) { left.suffixes.append(right) }
    func rendered(using localizer: MioLocalizer) -> String { localizer.text(key, arguments) + suffixes.map { $0.rendered(using: localizer) }.joined() }
}
