import Foundation

/// API layer: endpoint discovery, RPC calls, session (port of js/api.js).
@MainActor
final class API {
    static let shared = API()
    private(set) var host: String?
    private(set) var key = Config.apiKeys[0]
    private(set) var keyIndex = 0

    /// Called when a call reports "login required" while we hold a session.
    var onSessionInvalid: (() -> Void)?

    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": Config.userAgent]
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        return URLSession(configuration: c)
    }()

    nonisolated private func enc(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        return params.compactMap { k, v in
            guard let ek = k.addingPercentEncoding(withAllowedCharacters: allowed),
                  let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return ek + "=" + ev
        }.joined(separator: "&")
    }

    nonisolated func raw(_ host: String, _ key: String, _ name: String, _ params: [String: String], token: String, lang: String) async throws -> JSON {
        guard let url = URL(string: host + "/action/" + name) else { throw AppError("bad url") }
        var rq = URLRequest(url: url)
        rq.httpMethod = "POST"
        rq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        rq.setValue(key, forHTTPHeaderField: "c-api-key")
        rq.setValue(token, forHTTPHeaderField: "c-token")
        rq.setValue(Config.version, forHTTPHeaderField: "c-version-number")
        rq.setValue(lang, forHTTPHeaderField: "c-language")
        rq.httpBody = enc(params).data(using: .utf8)
        rq.timeoutInterval = 20
        let s = session
        let (data, _) = try await withTimeout(20000, name) { try await s.data(for: rq) }
        guard let j = JSON.parse(data) else { throw AppError("bad json from " + name) }
        return j
    }

    // Try a discovery URL; first success wins, otherwise the hardcoded hosts.
    private func discover() async -> [String] {
        let s = session
        let list: [String]? = await withTaskGroup(of: [String]?.self) { g in
            for u in Config.discoveryUrls {
                g.addTask {
                    guard let url = URL(string: u + "?t=\(Int(nowMs()))") else { return nil }
                    guard let (d, _) = try? await withTimeout(6000, "discovery", { try await s.data(from: url) }),
                          let j = JSON.parse(d) else { return nil }
                    let hosts = j.array.compactMap { $0["host"].string }
                    return hosts.isEmpty ? nil : hosts
                }
            }
            for await r in g { if let r { g.cancelAll(); return r } }
            return nil
        }
        return list ?? Config.fallbackHosts.map { $0.host }
    }

    /// Probe `test` on all hosts with each key; choose the first that answers successfully.
    func initialize() async throws {
        let list = await discover()
        var seen = Set<String>(), hosts: [String] = []
        for h in list + Config.fallbackHosts.map({ $0.host }) where !seen.contains(h) { seen.insert(h); hosts.append(h) }
        if let cached = Store.json("host")?.string, !seen.contains(cached) { hosts.insert(cached, at: 0) }
        let lang = I18n.lang
        for (ki, k) in Config.apiKeys.enumerated() {
            let found: String? = await withTaskGroup(of: String?.self) { g in
                for h in hosts {
                    g.addTask { [weak self] in
                        guard let self, let j = try? await withTimeout(8000, "test", { try await self.raw(h, k, "test", [:], token: "", lang: lang) }) else { return nil }
                        return j["success"].truthy ? h : nil
                    }
                }
                for await r in g { if let r { g.cancelAll(); return r } }
                return nil
            }
            if let h = found {
                host = h; key = k; keyIndex = ki; Store.set("host", h)
                return
            }
        }
        throw AppError("no endpoint reachable")
    }

    /// Generic action. Returns the envelope; throws on network errors.
    func call(_ name: String, _ params: [String: String] = [:]) async throws -> JSON {
        guard let host else { throw AppError("no endpoint") }
        let j = try await raw(host, key, name, params, token: Session.shared.token ?? "", lang: I18n.lang)
        if !j["success"].truthy, j["msg"].str.range(of: "login required", options: .caseInsensitive) != nil, Session.shared.isLoggedIn {
            onSessionInvalid?()
        }
        return j
    }

    /// Returns `result` or throws with the server message.
    func get(_ name: String, _ params: [String: String] = [:]) async throws -> JSON {
        let j = try await call(name, params)
        if !j["success"].truthy { throw AppError(j["msg"].string ?? "error") }
        return j["result"]
    }
}

/// Session (`{token, user}` persisted under n30.session).
@MainActor
final class Session {
    static let shared = Session()
    private(set) var data: JSON? = Store.json("session")

    var token: String? { data?["token"].string.flatMap { $0.isEmpty ? nil : $0 } }
    var user: JSON { data?["user"] ?? .null }
    var isLoggedIn: Bool { token != nil }

    func set(user u: JSON) {
        let s: JSON = .object(["token": u["user_session"], "user": u])
        data = s; Store.setJSON("session", s)
    }
    func mergeUser(_ extra: JSON) {
        guard var s = data else { return }
        var u = s["user"]
        if case .object(var o) = u, let e = extra.object { for (k, v) in e { o[k] = v }; u = .object(o) } else { u = extra }
        s["user"] = u; data = s; Store.setJSON("session", s)
    }
    func clear() { data = nil; Store.del("session") }
}

// MARK: - helpers over post objects

extension JSON {
    var postId: String { self["id"].str }
    var options: JSON { self["options"] }
    var info: JSON { self["info"] }
    var isSeries: Bool { options["is_series"].truthy }

    var localizedTitle: String {
        let t = self["title"]
        if I18n.lang == "fa", let l = t["local"].string, !l.isEmpty { return l }
        return t["english"].string.flatMap { $0.isEmpty ? nil : $0 } ?? t["local"].str
    }
    var localizedPlot: String {
        let t = self["plot"]
        if I18n.lang == "fa", let l = t["local"].string, !l.isEmpty { return l }
        return t["english"].string.flatMap { $0.isEmpty ? nil : $0 } ?? t["local"].str
    }
    /// The other-language title, when it differs.
    var otherTitle: String {
        let t = self["title"], o = I18n.lang == "fa" ? t["english"].str : t["local"].str
        return !o.isEmpty && o != localizedTitle ? o : ""
    }
    var posterUrl: String {
        let po = self["image"]["poster"]
        return po["webp"]["large"].string ?? po["webp"]["medium"].string ?? po["jpg"]["large"].string ?? po["jpg"]["medium"].string ?? ""
    }
    var coverUrl: String {
        let c = self["image"]["cover"]
        return c["webp"].string ?? c["jpg"].string ?? ""
    }
}

/// `r.posts || r.items || r.list || r` and unwrap `{post: …}` entries.
func extractPosts(_ r: JSON) -> [JSON] {
    let raw = rawList(r)
    return raw.map { $0["post"].isObject ? $0["post"] : $0 }.filter { $0["id"].truthy }
}
func rawList(_ r: JSON) -> [JSON] {
    if r["posts"].isArray { return r["posts"].array }
    if r["items"].isArray { return r["items"].array }
    if r["list"].isArray { return r["list"].array }
    return r.array
}
