import Foundation

/// Global constants (port of js/config.js).
enum Config {
    static let discoveryUrls = [
        "https://pub-ac69cf865ce145f8b4c1ed87dc2a9fb7.r2.dev/sdk-endpoint.json",
        "https://30update.s3.ir-thr-at1.arvanstorage.ir/sdk-endpoint.json"
    ]
    static let fallbackHosts: [(location: String, host: String)] = [
        ("WORLD", "https://world.hana-api.com/api/v2"),
        ("IR", "https://ir.kazem-api.com/api/v2")
    ]
    // WEBTV key verified live (platform "WebTV"); ANDROIDTV key kept as fallback.
    static let apiKeys = ["83hRzBabjDnuv9SmV2GFaftpxjhZSHXYe7UnBuX5DdANdpzPvXu46jvKZHPb97As", "VdapnkLG9EHsSmF8yeKcb4253RAuN6YX"]
    static let version = "1.0.0"
    /// TMDB v4 "API Read Access Token" (Bearer), baked in from Config/Secrets.xcconfig (TMDB_TOKEN). Empty = TMDB off.
    static var tmdbToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "TMDBToken") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let qrBase = "https://30nama.com/auth/"
    static let qrPollMs = 5000
    static let qrTimeoutMs = 60000
    static let heartbeatMs = 10000
    /// The Tizen dev proxy uses a Smart TV user agent; Cloudflare in front of the API is happiest with it.
    static let userAgent = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) 85.0.4183.93/6.5 TV Safari/537.36"
}

/// localStorage equivalent: values are JSON-encoded under an `n30.` prefix in UserDefaults.
enum Store {
    private static let d = UserDefaults.standard
    private static func k(_ key: String) -> String { "n30." + key }

    static func json(_ key: String) -> JSON? {
        guard let s = d.string(forKey: k(key)), let data = s.data(using: .utf8) else { return nil }
        return JSON.parse(data)
    }
    static func setJSON(_ key: String, _ v: JSON) {
        if let data = v.data(), let s = String(data: data, encoding: .utf8) { d.set(s, forKey: k(key)) }
    }
    static func del(_ key: String) { d.removeObject(forKey: k(key)) }

    static func string(_ key: String, _ def: String) -> String { json(key)?.string ?? def }
    static func bool(_ key: String, _ def: Bool) -> Bool {
        guard let j = json(key) else { return def }
        if case .bool(let b) = j { return b }
        return def
    }
    static func int(_ key: String, _ def: Int) -> Int { json(key)?.int ?? def }
    static func set(_ key: String, _ v: String) { setJSON(key, .string(v)) }
    static func set(_ key: String, _ v: Bool) { setJSON(key, .bool(v)) }
    static func set(_ key: String, _ v: Int) { setJSON(key, .number(Double(v))) }

    /// Raw (un-prefixed) string, like `localStorage.getItem('tmdbToken')`; also readable from launch arguments.
    static func raw(_ key: String) -> String? { d.string(forKey: key) }
}

func fmtTime(_ s0: Double) -> String {
    let s = max(0, Int(s0.isFinite ? s0 : 0))
    let h = s / 3600, m = s % 3600 / 60, x = s % 60
    func p(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
    return (h > 0 ? "\(h):\(p(m))" : "\(m)") + ":" + p(x)
}

func clockNow() -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
    let h = c.hour ?? 0, m = c.minute ?? 0
    return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
}

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

extension Task where Success == Never, Failure == Never {
    static func sleep(ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000) }
}

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Races `op` against a timeout.
func withTimeout<T>(_ ms: Int, _ label: String = "", _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask { await Task.sleep(ms: ms); throw AppError("timeout " + label) }
        defer { g.cancelAll() }
        guard let v = try await g.next() else { throw AppError("timeout " + label) }
        return v
    }
}
