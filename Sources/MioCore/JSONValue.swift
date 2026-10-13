import Foundation
import CoreFoundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(any: Any) throws {
        switch any {
        case is NSNull: self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else if value.doubleValue.isFinite { self = .number(value.doubleValue) }
            else { throw MioError("invalid_json", "Non-finite JSON number") }
        case let value as String: self = .string(value)
        case let value as [String: Any]: self = .object(try value.mapValues { try JSONValue(any: $0) })
        case let value as [Any]: self = .array(try value.map { try JSONValue(any: $0) })
        default: throw MioError("invalid_json", "Unsupported JSON value")
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
    public func encoded() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(self) }
    public subscript(_ key: String) -> JSONValue { objectValue[key] ?? .null }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    public var arrayValue: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var boolValue: Bool { if case .bool(let v) = self { return v }; return false }
    public var intValue: Int { if case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }; return 0 }
}
public enum AccessContext: Sendable { case human; case agent(token: String) }
public struct MioError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue
    public init(_ code: String, _ message: String, details: JSONValue = .null) { self.code = code; self.message = message; self.details = details }
    public var errorDescription: String? { message }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String, _ fallback: String = "") -> String { self[key]?.stringValue ?? fallback }
    func required(_ key: String) throws -> String {
        guard let v = self[key]?.stringValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MioError("invalid_params", "Missing \(key)") }; return v
    }
}
