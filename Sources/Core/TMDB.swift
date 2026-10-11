import Foundation
import CryptoKit

/// TMDB enrichment (optional; port of js/tmdb.js). Every entry point is a no-op unless `enabled`:
/// a v4 read-access token (Config/Secrets.xcconfig, or the `tmdbToken` user default), or `tmdbMock` = 1 (bundled fixtures).
/// Caches: in-memory LRU + on-disk entries with TTLs. Slimmed values are kept as JSON with the same keys as the Tizen app.
@MainActor
final class TMDB {
    static let shared = TMDB()
    private let API_ = "https://api.themoviedb.org/3", IMG = "https://image.tmdb.org/t/p/"
    enum TTL {
        static let HR: Double = 3600 * 1000
        static let details = 168 * HR, trend = 6 * HR, match = 168 * HR, miss = 24 * HR, res = 168 * HR }

    var token: String { (Store.raw("tmdbToken") ?? Config.tmdbToken).trimmingCharacters(in: .whitespacesAndNewlines) }
    var mock: Bool { Store.raw("tmdbMock") == "1" || UserDefaults.standard.integer(forKey: "tmdbMock") == 1 }
    var enabled: Bool { mock || !token.isEmpty }
    func img(_ path: String, _ size: String = "w500") -> String { path.isEmpty ? "" : IMG + size + path }

    // MARK: cache
    private struct Entry { let t: Double; let v: JSON }
    private var mem: [String: Entry] = [:], memKeys: [String] = []
    private let MEMMAX = 160
    private lazy var dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("n30.tc", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private func file(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h + ".json")
    }
    private func touch(_ k: String) { memKeys.removeAll { $0 == k }; memKeys.append(k) }
    private func memPut(_ k: String, _ e: Entry) { mem[k] = e; touch(k); while memKeys.count > MEMMAX { mem.removeValue(forKey: memKeys.removeFirst()) } }
    private func cget(_ key: String, _ ttl: (JSON) -> Double) -> Entry? {
        var e = mem[key]
        if e == nil, let d = try? Data(contentsOf: file(key)), let j = JSON.parse(d), let t = j["t"].double {
            e = Entry(t: t, v: j["v"]); memPut(key, e!)
        }
        guard let e else { return nil }
        if nowMs() - e.t > ttl(e.v) { return nil }
        touch(key); return e
    }
    private func cput(_ key: String, _ v: JSON) {
        let e = Entry(t: nowMs(), v: v); memPut(key, e)
        if let d = JSON.object(["t": .number(e.t), "v": v]).data() { try? d.write(to: file(key), options: .atomic) }
    }
    @discardableResult
    func clearCache() -> Int {
        mem = [:]; memKeys = []
        let fs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        fs.forEach { try? FileManager.default.removeItem(at: $0) }
        return fs.count
    }

    // MARK: http
    private func qs(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        return params.keys.sorted().map { k in
            (k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k) + "=" + (params[k]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }
    private func mockFile(_ path: String) -> String {
        func m(_ p: String) -> [String]? {
            guard let r = try? NSRegularExpression(pattern: p), let x = r.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else { return nil }
            return (0..<x.numberOfRanges).map { Range(x.range(at: $0), in: path).map { String(path[$0]) } ?? "" }
        }
        if m("^/trending/") != nil { return "trending" }
        if m("^/tv/on_the_air") != nil || m("^/discover/tv") != nil { return "on_the_air" }
        if m("^/movie/now_playing") != nil { return "now_playing" }
        if let g = m("^/search/(movie|tv)") { return "search_" + g[1] }
        if m("^/find/") != nil { return "find" }
        if m("^/(movie|tv)/\\d+/images") != nil { return "images" }
        if let g = m("^/(movie|tv)/\\d+") { return "details_" + g[1] }
        return "empty"
    }
    private func rq(_ path: String, _ params: [String: String]) async throws -> JSON {
        if mock {
            guard let u = Bundle.main.url(forResource: mockFile(path), withExtension: "json"), let d = try? Data(contentsOf: u), let j = JSON.parse(d) else { throw AppError("fixture") }
            return j
        }
        let q = qs(params)
        guard let url = URL(string: API_ + path + (q.isEmpty ? "" : "?" + q)) else { throw AppError("tmdb url") }
        var r = URLRequest(url: url)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, resp) = try await withTimeout(15000, "tmdb") { try await URLSession.shared.data(for: r) }
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw AppError("tmdb \(h.statusCode)") }
        guard let j = JSON.parse(d) else { throw AppError("tmdb json") }
        return j
    }
    private var inflight: [String: Task<JSON, Error>] = [:]
    /// The slimmed value is what is cached and returned.
    func get(_ path: String, _ params: [String: String], ttl: Double = TTL.details, slim: ((JSON) -> JSON)? = nil) async throws -> JSON {
        let key = path + "?" + qs(params)
        if let c = cget(key, { _ in ttl }) { return c.v }
        if let t = inflight[key] { return try await t.value }
        let t = Task<JSON, Error> { [weak self] in
            guard let self else { throw AppError("gone") }
            let j = try await self.rq(path, params)
            let v = slim?(j) ?? j
            self.cput(key, v)
            return v
        }
        inflight[key] = t
        defer { inflight[key] = nil }
        return try await t.value
    }

    // MARK: text matching
    nonisolated static func norm(_ s0: String) -> String {
        var s = s0.lowercased()
        s = s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }.map(String.init).joined()
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: "[^a-z0-9\\u0600-\\u06FF]+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
    nonisolated static func stripYear(_ s: String) -> String {
        let r = s.replacingOccurrences(of: "\\s*[\\(\\[]?\\b(19|20)\\d\\d[\\)\\]]?\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? s : r
    }
    nonisolated static func sim(_ a0: String, _ b0: String) -> Double {
        let a = norm(a0), b = norm(b0)
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let A = a.split(separator: " "), B = Set(b.split(separator: " "))
        let inter = A.filter { B.contains($0) }.count
        var d = 2 * Double(inter) / Double(A.count + b.split(separator: " ").count)
        if a.hasPrefix(b + " ") || b.hasPrefix(a + " ") { d = max(d, 0.82) }
        return d
    }
    private func yearOf(_ s: String) -> Int { s.count >= 4 ? Int(s.prefix(4)) ?? 0 : 0 }

    private func slimItem(_ r: JSON, _ dk: String?) -> JSON {
        let kind = r["media_type"].string ?? dk ?? (r["first_air_date"].exists ? "tv" : "movie")
        return .object([
            "id": r["id"], "kind": .string(kind == "tv" ? "tv" : "movie"),
            "title": .string(r["title"].string ?? r["name"].str), "orig": .string(r["original_title"].string ?? r["original_name"].str),
            "year": .number(Double(yearOf(r["release_date"].string ?? r["first_air_date"].str))),
            "bd": .string(r["backdrop_path"].str), "pst": .string(r["poster_path"].str),
            "pop": .number(r["popularity"].num), "vc": .number(r["vote_count"].num)
        ])
    }
    private func listSlim(_ dk: String?) -> (JSON) -> JSON {
        { j in .array(j["results"].array.filter { $0["media_type"].string != "person" && $0["id"].truthy }.map { self.slimItem($0, dk) }) }
    }

    // MARK: 30nama post -> TMDB id
    private func postYear(_ p: JSON) -> Int { p["info"]["year"].int ?? 0 }
    private func postImdb(_ p: JSON) -> String {
        for s in [p["score"]["imdb"]["link"].str, p["imdb_id"].str] {
            if let r = s.range(of: "tt\\d{6,10}", options: .regularExpression) { return String(s[r]) }
        }
        return ""
    }
    private func bestCand(_ cands: [JSON], _ titles: [String], _ year: Int, _ tv: Bool) -> JSON? {
        var best: JSON?, bs = 0.0
        for c in cands {
            var s = 0.0
            for t in titles { s = max(s, TMDB.sim(t, c["title"].str), c["orig"].str.isEmpty ? 0 : TMDB.sim(t, c["orig"].str)) }
            if s < 0.8 { continue }
            var sc = s
            let cy = c["year"].int ?? 0
            if year > 0 && cy > 0 {
                let d = abs(year - cy)
                if d == 0 { sc += 0.25 } else if d == 1 { sc += 0.1 } else if !tv || d > 3 { continue } else { sc -= 0.2 }
            }
            if sc > bs { bs = sc; best = c }
        }
        return best
    }
    /// `{id, kind}` or nil.
    func match(_ post: JSON) async -> JSON? {
        if post["_tm"].isObject { return post["_tm"] }
        let key = "m." + post.postId
        if let c = cget(key, { $0.truthy ? TTL.match : TTL.miss }) { return c.v.truthy ? c.v : nil }
        let tv = post.isSeries, year = postYear(post), imdb = postImdb(post)
        let raw = post["title"]["english"].str
        var titles = [TMDB.stripYear(raw)]
        if raw != titles[0] { titles.append(raw) }
        func ref(_ x: JSON) -> JSON { .object(["id": x["id"], "kind": x["kind"]]) }
        var m: JSON?
        if !imdb.isEmpty {
            if let r = try? await get("/find/" + imdb, ["external_source": "imdb_id", "language": "en-US"], slim: { j in
                .object(["movie": .array(j["movie_results"].array.map { self.slimItem($0, "movie") }), "tv": .array(j["tv_results"].array.map { self.slimItem($0, "tv") })])
            }) {
                let a = tv ? r["tv"] : r["movie"], b = tv ? r["movie"] : r["tv"]
                let x = a[0].exists ? a[0] : b[0]
                if x.exists { m = ref(x) }
            }
        }
        func search(_ withYear: Bool) async -> JSON? {
            var p = ["query": titles[0], "include_adult": "false", "language": "en-US"]
            if withYear && year > 0 { p[tv ? "first_air_date_year" : "year"] = String(year) }
            guard let list = try? await get("/search/" + (tv ? "tv" : "movie"), p, slim: listSlim(tv ? "tv" : "movie")) else { return nil }
            return bestCand(list.array, titles, year, tv).map(ref)
        }
        if m == nil { m = await search(true) }
        if m == nil && year > 0 { m = await search(false) }
        cput(key, m ?? .number(0))
        return m
    }

    // MARK: normalized details
    private func pickLogo(_ logos: JSON) -> String {
        var l = logos.array.filter { $0["iso_639_1"].string == "en" || !$0["iso_639_1"].truthy }
        l.sort { a, b in
            let ae = a["iso_639_1"].string == "en" ? 1 : 0, be = b["iso_639_1"].string == "en" ? 1 : 0
            if ae != be { return ae > be }
            if a["vote_average"].num != b["vote_average"].num { return a["vote_average"].num > b["vote_average"].num }
            return a["width"].num > b["width"].num
        }
        return l.first?["file_path"].str ?? ""
    }
    private func slimDetails(_ j: JSON, _ kind: String) -> JSON {
        let cr = j["credits"]
        var cast: [JSON] = [], crew: [JSON] = [], reviews: [JSON] = [], recs: [JSON] = [], nets: [String] = []
        for c in cr["cast"].array.prefix(16) { cast.append(.object(["n": c["name"], "c": .string(c["character"].str), "p": .string(c["profile_path"].str)])) }
        var seen = Set<String>()
        func addCrew(_ n: String, _ job: String, _ p: String) {
            if n.isEmpty || seen.contains(n + job) || crew.count >= 8 { return }
            seen.insert(n + job); crew.append(.object(["n": .string(n), "j": .string(job), "p": .string(p)]))
        }
        for c in j["created_by"].array { addCrew(c["name"].str, "Creator", c["profile_path"].str) }
        for c in cr["crew"].array where c["job"].string == "Director" { addCrew(c["name"].str, "Director", c["profile_path"].str) }
        var w = 0
        for c in cr["crew"].array where w < 2 && ["Screenplay", "Writer", "Story"].contains(c["job"].str) { w += 1; addCrew(c["name"].str, "Writer", c["profile_path"].str) }
        var ep = 0
        for c in cr["crew"].array where kind == "tv" && ep < 2 && c["job"].string == "Executive Producer" { ep += 1; addCrew(c["name"].str, "Executive Producer", c["profile_path"].str) }
        for c in cr["crew"].array where kind == "movie" && c["job"].string == "Original Music Composer" { addCrew(c["name"].str, "Composer", c["profile_path"].str) }
        for n in (kind == "tv" ? j["networks"] : j["production_companies"]).array {
            let s = n["name"].str
            if !s.isEmpty && !nets.contains(s) && nets.count < 2 { nets.append(s) }
        }
        for r in j["reviews"]["results"].array.prefix(8) {
            var txt = r["content"].str.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            if txt.count > 4000 { txt = String(txt.prefix(4000)) + "…" }
            if txt.count < 20 { continue }
            reviews.append(.object([
                "a": .string(r["author"].string.flatMap { $0.isEmpty ? nil : $0 } ?? r["author_details"]["username"].str),
                "r": .number(r["author_details"]["rating"].num), "t": .string(txt), "d": .string(String(r["created_at"].str.prefix(10)))
            ]))
        }
        for r in j["recommendations"]["results"].array where r["id"].truthy { recs.append(slimItem(r, kind)) }
        var next: JSON = .null
        let n = j["next_episode_to_air"]
        if n["air_date"].truthy { next = .object(["d": n["air_date"], "s": n["season_number"], "e": n["episode_number"]]) }
        let runtime: Double = kind == "movie" ? j["runtime"].num : (j["episode_run_time"][0].double ?? j["last_episode_to_air"]["runtime"].num)
        return .object([
            "id": j["id"], "kind": .string(kind), "title": .string(j["title"].string ?? j["name"].str), "tagline": .string(j["tagline"].str), "overview": .string(j["overview"].str),
            "rating": .number(j["vote_average"].num), "votes": .number(j["vote_count"].num), "status": .string(j["status"].str), "runtime": .number(runtime),
            "bd": .string(j["backdrop_path"].str), "logo": .string(pickLogo(j["images"]["logos"])),
            "imdb": .string(j["external_ids"]["imdb_id"].string ?? j["imdb_id"].str), "seasons": .number(j["number_of_seasons"].num),
            "cast": .array(cast), "crew": .array(crew), "reviews": .array(reviews), "recs": .array(recs), "nets": .array(nets.map { .string($0) }), "next": next
        ])
    }
    func details(_ post: JSON) async -> JSON? {
        guard let m = await match(post) else { return nil }
        let kind = m["kind"].str, path = "/" + kind + "/" + m["id"].str
        guard var d = try? await get(path, ["language": "en-US", "append_to_response": "credits,reviews,videos,images,recommendations,external_ids", "include_image_language": "en,null"],
                                     slim: { self.slimDetails($0, kind) }) else { return nil }
        if I18n.lang == "fa", let loc = try? await get(path, ["language": "fa-IR"], slim: { j in .object(["tagline": .string(j["tagline"].str), "overview": .string(j["overview"].str)]) }) {
            if loc["tagline"].truthy { d["tagline"] = loc["tagline"] }
            if loc["overview"].truthy { d["overview"] = loc["overview"] }
        }
        return d
    }
    /// Title-logo URL for {id, kind}; "" when none.
    func logoFor(_ tm: JSON) async -> String {
        guard let p = try? await get("/" + tm["kind"].str + "/" + tm["id"].str + "/images", ["include_image_language": "en,null"], slim: { .string(self.pickLogo($0["logos"])) }) else { return "" }
        return p.str.isEmpty ? "" : IMG + "w500" + p.str
    }

    // MARK: TMDB item -> 30nama post
    // 30nama sits behind Cloudflare rate limiting: keep concurrency low, space out starts, back off on errors.
    private var queue: [() async -> Void] = [], active = 0, lastStart = 0.0, pausedUntil = 0.0, pumping = false
    private let MAXC = 4, GAP = 150.0
    private func pump() {
        if pumping || active >= MAXC || queue.isEmpty { return }
        let now = nowMs(), wait = max(pausedUntil - now, lastStart + GAP - now, 0)
        if wait > 0 {
            pumping = true
            Task { await Task.sleep(ms: Int(wait)); self.pumping = false; self.pump() }
            return
        }
        let j = queue.removeFirst(); active += 1; lastStart = now
        Task { await j(); self.active -= 1; self.pump() }
        pump()
    }
    private func pool<T>(_ fn: @escaping () async -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.append { c.resume(returning: await fn()) }
            pump()
        }
    }
    private func retrying<T>(_ tries: Int, _ fn: @escaping () async throws -> T) async throws -> T {
        do { return try await fn() } catch {
            let msg = (error as? AppError)?.message ?? error.localizedDescription
            if tries > 0, msg.range(of: "bad json|timeout|429", options: .regularExpression) != nil {
                pausedUntil = nowMs() + 8000
                await Task.sleep(ms: 8000)
                return try await retrying(tries - 1, fn)
            }
            throw error
        }
    }
    private func slimPost(_ p: JSON) -> JSON {
        var o: [String: JSON] = [:]
        for k in ["id", "post_type", "options", "info", "title", "plot", "genre", "image", "score"] { o[k] = p[k] }
        return .object(o)
    }
    private func bestPost(_ posts: [JSON], _ it: JSON) -> JSON? {
        var best: JSON?, bs = 0.0
        let tv = it["kind"].string == "tv"
        for p in posts {
            if !p["id"].truthy || !p["title"].truthy { continue }
            if p.isSeries != tv { continue }
            if p.options["coming_soon"].truthy { continue }
            let raw = p["title"]["english"].str
            var s = 0.0
            for tt in [it["title"].str, it["orig"].str] where !tt.isEmpty { s = max(s, TMDB.sim(TMDB.stripYear(raw), tt), TMDB.sim(raw, tt)) }
            if s < 0.8 { continue }
            var sc = s
            let py = postYear(p), iy = it["year"].int ?? 0
            if iy > 0 && py > 0 {
                let d = abs(iy - py)
                if d == 0 { sc += 0.25 } else if d == 1 { sc += 0.1 } else { continue }
            }
            if p.options["stream"].truthy { sc += 0.1 }
            if sc > bs { bs = sc; best = p }
        }
        return best
    }
    private func resolveNet(_ it: JSON) async throws -> JSON? {
        var qs2 = [it["title"].str]
        let orig = it["orig"].str
        if !orig.isEmpty && TMDB.norm(orig) != TMDB.norm(it["title"].str) && orig.range(of: "[a-z]", options: [.regularExpression, .caseInsensitive]) != nil { qs2.append(orig) }
        for q in qs2 where !q.isEmpty {
            let r = try await API.shared.get("search", ["query": q, "streamonly": "0", "page": "1"])
            if let b = bestPost(r["posts"].array, it) { return b }
        }
        return nil
    }
    private var rin: [String: Task<JSON?, Never>] = [:]
    /// it: slim TMDB item; alive(): false -> skipped (returns nil, uncached).
    func resolve(_ it: JSON, alive: (() -> Bool)? = nil) async -> JSON? {
        let key = "r2." + it["kind"].str + it["id"].str
        if let c = cget(key, { $0.truthy ? TTL.res : TTL.miss }) { return c.v.truthy ? c.v : nil }
        if let t = rin[key] { return await t.value }
        let t = Task<JSON?, Never> { [weak self] in
            guard let self else { return nil }
            enum R { case skipped, post(JSON?), failed }
            let r: R = await self.pool {
                if let alive, !alive() { return .skipped }
                do { return .post(try await self.retrying(2) { try await self.resolveNet(it) }) } catch { return .failed }
            }
            self.rin[key] = nil
            switch r {
            case .skipped, .failed: return nil
            case .post(let p):
                let sp = p.map(self.slimPost)
                self.cput(key, sp ?? .number(0))
                return sp
            }
        }
        rin[key] = t
        return await t.value
    }

    // MARK: home feeds
    final class Feed: ObservableObject {
        let name: String
        let t = nowMs()
        @Published var items: [(post: JSON, tm: JSON, i: Int)] = []
        @Published var done = false
        init(name: String) { self.name = name }
    }
    private func sources(_ name: String) -> [(path: String, params: [String: String], dk: String?)] {
        switch name {
        case "trend": return [("/trending/all/week", ["language": "en-US"], nil)]
        case "fresh":
            let d = Date(timeIntervalSinceNow: -30 * 86400)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            let ds = f.string(from: d)
            return (1...3).map { pg in ("/discover/tv", ["language": "en-US", "air_date.gte": ds, "sort_by": "popularity.desc", "vote_count.gte": "200", "without_genres": "10767,10763,10764,10766", "page": String(pg)], "tv") }
        default: return [("/movie/now_playing", ["language": "en-US", "region": "US"], "movie"), ("/trending/movie/day", ["language": "en-US"], "movie")]
        }
    }
    private let CAP = ["trend": 16, "fresh": 14, "pop": 14]
    private var feeds: [String: Feed] = [:]
    private func makeFeed(_ name: String) -> Feed {
        let f = Feed(name: name), cap = CAP[name] ?? 14
        Task {
            var lists: [JSON] = []
            for s in sources(name) { lists.append((try? await get(s.path, s.params, ttl: TTL.trend, slim: listSlim(s.dk))) ?? .array([])) }
            var seen = Set<String>(), cands: [JSON] = []
            for l in lists { for it in l.array {
                let k = it["kind"].str + it["id"].str
                if !seen.contains(k) && it["title"].truthy && it["pst"].truthy { seen.insert(k); cands.append(it) }
            } }
            // fresh series: most popular (well-known) first, obscure titles dropped
            if name == "fresh" {
                cands = cands.filter { $0["vc"].num >= 200 }
                cands.sort { ($0["pop"].num + sqrt($0["vc"].num) / 5) > ($1["pop"].num + sqrt($1["vc"].num) / 5) }
            }
            if cands.isEmpty { f.done = true; return }
            await withTaskGroup(of: Void.self) { g in
                for (i, it) in cands.enumerated() {
                    g.addTask { @MainActor in
                        guard var post = await self.resolve(it, alive: { f.items.count < cap }) else { return }
                        if f.items.count < cap {
                            post["_tm"] = .object(["id": it["id"], "kind": it["kind"]])
                            post["_bd"] = .string(it["bd"].truthy ? self.IMG + "w1280" + it["bd"].str : "")
                            f.items.append((post, it, i))
                        }
                    }
                }
            }
            f.done = true
        }
        return f
    }
    func feed(_ name: String) -> Feed {
        if let f = feeds[name], nowMs() - f.t < 10 * 60 * 1000, !(f.done && f.items.isEmpty) { return f }
        let f = makeFeed(name); feeds[name] = f; return f
    }
    func startHome() { _ = feed("trend"); _ = feed("fresh"); _ = feed("pop") }

    /// Up to `n` trending posts that have a TMDB backdrop (fewer on timeout); never throws.
    func heroes(_ n: Int, _ ms: Int) async -> [JSON] {
        let f = feed("trend"), start = nowMs()
        func withBd() -> [(post: JSON, tm: JSON, i: Int)] { f.items.filter { $0.post["_bd"].truthy } }
        while !f.done && withBd().count < n && nowMs() - start < Double(ms) { await Task.sleep(ms: 100) }
        var ps: [JSON] = withBd().sorted { $0.i < $1.i }.prefix(n).map { x in
            var p = x.post; p["_bdPref"] = .bool(true); p["_hero"] = .bool(true); return p
        }
        // logos, capped at 900ms
        let tms = ps.map { $0["_tm"] }
        let logos: [Int: String] = await withTaskGroup(of: (Int, String).self) { g in
            for (i, tm) in tms.enumerated() { g.addTask { @MainActor in (i, await self.logoFor(tm)) } }
            g.addTask { await Task.sleep(ms: 900); return (-1, "") }
            var out: [Int: String] = [:]
            for await (i, u) in g { if i < 0 { g.cancelAll(); break }; out[i] = u; if out.count == tms.count { g.cancelAll(); break } }
            return out
        }
        for (i, u) in logos where !u.isEmpty { ps[i]["_logo"] = .string(u) }
        return ps
    }
}
