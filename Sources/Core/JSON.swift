import Foundation

/// Loosely typed JSON value. The 30nama API returns shapes that vary between endpoints and
/// account states, so (like the Tizen app) everything is read defensively with JS-like semantics.
enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(any v: Any?) {
        switch v {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSON(any: $0) })
        default: self = .null
        }
    }

    static func parse(_ data: Data) -> JSON? {
        guard let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: o)
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    func data() -> Data? { try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]) }

    subscript(key: String) -> JSON {
        get { if case .object(let o) = self { return o[key] ?? .null }; return .null }
        set {
            if case .object(var o) = self { o[key] = newValue; self = .object(o) }
            else if case .null = self { self = .object([key: newValue]) }
        }
    }
    subscript(i: Int) -> JSON {
        if case .array(let a) = self, i >= 0, i < a.count { return a[i] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true }; return false }
    var exists: Bool { !isNull }

    /// JavaScript truthiness.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// String form (numbers rendered like JS `String(n)`), nil for null/containers.
    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return JSON.fmt(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var str: String { string ?? "" }

    /// Number form (`Number(x)` in JS), nil when not convertible.
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var num: Double { double ?? 0 }
    var int: Int? { double.map { Int($0) } }

    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var isArray: Bool { if case .array = self { return true }; return false }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    var isObject: Bool { object != nil }

    static func fmt(_ n: Double) -> String {
        if n.rounded() == n && abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    /// First non-null among keys.
    func first(_ keys: String...) -> JSON {
        for k in keys { let v = self[k]; if v.truthy { return v } }
        return .null
    }
}
