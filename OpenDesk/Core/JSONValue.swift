import Foundation

/// Loosely typed JSON, for APIs whose shape depends on user data (NocoDB rows, Grafana panels).
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var int: Int? { double.map { Int($0) } }

    var bool: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" || s == "1"
        default: return false
        }
    }

    var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    var object: [String: JSONValue] {
        if case .object(let o) = self { return o }
        return [:]
    }

    var isNull: Bool {
        if case .null = self { return true }
        if case .string(let s) = self { return s.isEmpty }
        return false
    }

    /// Human-readable rendering for list rows.
    var display: String {
        switch self {
        case .string(let s): return s
        case .number: return string ?? ""
        case .bool(let b): return b ? "Yes" : "No"
        case .array(let a): return a.map(\.display).joined(separator: ", ")
        case .object(let o):
            for k in ["title", "name", "Title", "Name", "display_name", "username"] { if let v = o[k]?.string { return v } }
            return o.values.compactMap(\.string).first ?? ""
        case .null: return ""
        }
    }

    /// Compact JSON for prompts.
    var compactJSON: String {
        guard let d = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}
