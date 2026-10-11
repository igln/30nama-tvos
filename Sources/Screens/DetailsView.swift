import SwiftUI

enum DetFocus: Hashable { case play, episodes, epsGate, tab(Int), ep(Int), x(String, Int), rvClose }

@MainActor
final class DetailsModel: ObservableObject {
    @Published var post: JSON?
    @Published var items: [JSON] = []
    @Published var resume: JSON?
    @Published var error: String?
    @Published var tm: JSON?
    @Published var recs: [JSON] = []
    @Published var epsOpen = false
    @Published var xs = false
    @Published var curS: Int?
    @Published var shownS: Int?
    @Published var swapping = false
    @Published var review: JSON?
    var epMem: [Int: Int] = [:]
    var lastFocus: DetFocus?
    var fromTile = false
    var startIdx = 0
    var dead = false
    weak var app: AppState?

    var isSeries: Bool { post?.isSeries ?? false }
    var seasons: [Int] {
        var out: [Int] = []
        for it in items { let s = it["info"]["season"].int ?? 1; if !out.contains(s) { out.append(s) } }
        return out
    }
    func indices(_ s: Int) -> [Int] { items.indices.filter { (items[$0]["info"]["season"].int ?? 1) == s } }

    func load(_ id: String) {
        guard let app else { return }
        error = nil
        Task {
            do {
                let p = try await API.shared.get("single", ["post_id": id])
                if dead { return }
                app.stage.show(p, immediate: true)
                let wantStream = Session.shared.isLoggedIn, free = p.options["free_stream"].truthy
                var st: JSON?
                if wantStream || free, let j = try? await API.shared.call("stream", ["post_id": p.postId, "free_stream": wantStream ? "0" : "1"]), j["success"].truthy { st = j["result"] }
                if dead { return }
                render(p, st)
            } catch {
                if !dead { self.error = error.localizedDescription }
            }
        }
    }

    private func render(_ p: JSON, _ st: JSON?) {
        var its = st?["hls"].array ?? []
        its.sort { a, b in
            let sa = a["info"]["season"].num, sb = b["info"]["season"].num
            return sa != sb ? sa < sb : a["info"]["episode"].num < b["info"]["episode"].num
        }
        items = its
        if let cw = st?["continue_watching"], cw["file_id"].truthy { resume = cw }
        startIdx = 0
        if let r = resume { for (i, it) in its.enumerated() where it["info"]["file_id"].str == r["file_id"].str { startIdx = i } }
        post = p
        if TMDB.shared.enabled {
            Task {
                guard let d = await TMDB.shared.details(p), !dead else { return }
                withAnimation(Th.out(400)) { tm = d }
                upgradeBackdrop(d)
                resolveRecs(d)
            }
        }
    }

    private func upgradeBackdrop(_ d: JSON) {
        guard var p = post, d["bd"].truthy, let app else { return }
        let tb = TMDB.shared.img(d["bd"].str, "w1280"), cv = p.coverUrl
        if cv.isEmpty { p["_bd"] = .string(tb); post = p; app.stage.show(p, immediate: true); return }
        Task {
            if let ci = await ImageLoader.shared.load(cv), !dead, ci.size.width * ci.scale < 1280 {
                p["_bd"] = .string(tb); p["_bdPref"] = .bool(true); post = p; app.stage.show(p, immediate: true)
            }
        }
    }
    private var recGot = Set<String>(), recQueue: [JSON] = []
    /// "More like this": only titles found on 30nama; the row appears once 3 resolve, capped at 12.
    private func resolveRecs(_ d: JSON) {
        let pid = post?.postId ?? ""
        for it in d["recs"].array.prefix(20) {
            Task { [weak self] in
                guard let self else { return }
                guard let p = await TMDB.shared.resolve(it, alive: { [weak self] in self.map { !$0.dead && $0.recs.count + $0.recQueue.count < 12 } ?? false }),
                      !dead, p.postId != pid, !recGot.contains(p.postId), recs.count + recQueue.count < 12 else { return }
                recGot.insert(p.postId)
                if recs.isEmpty && recQueue.count < 2 { recQueue.append(p); return }
                if recs.isEmpty { recs = recQueue + [p]; recQueue = [] } else { recs.append(p) }
            }
        }
    }

    func playLabel() -> String {
        guard let r = resume else { return t("play") }
        _ = r
        let info0 = items.indices.contains(startIdx) ? items[startIdx]["info"] : .null
        return t("resume") + (isSeries ? " S" + (info0["season"].string ?? "1") + "·E" + (info0["episode"].string ?? "\(startIdx + 1)") : "")
    }
    func progress(_ it: JSON) -> Double {
        guard let r = resume, it["info"]["file_id"].str == r["file_id"].str, r["duration"].num > 0 else { return 0 }
        return r["time"].num / r["duration"].num
    }
}

struct DetailsView: View {
    let entryId: UUID
    let active: Bool
    let postId: String
    let autoplay: Bool
    @EnvironmentObject var app: AppState
    @StateObject private var m = DetailsModel()
    @FocusState private var focus: DetFocus?
    @State private var autoplayed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let e = m.error {
                ErrorView(message: e) { m.load(postId) }
            } else if let post = m.post {
                page(post)
            } else {
                skeleton
            }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .onAppear {
            m.app = app
            app.stage.details(true); app.stage.dim(0)
            if m.post == nil && m.error == nil { m.load(postId) }
            app.setBack(entryId) { back() }
        }
        .onDisappear { m.dead = !active && !app.stack.contains { $0.id == entryId } }
        .onChange(of: active) { _, a in
            if a {
                app.stage.details(true); app.stage.dim(m.xs ? 0.55 : 0)
                if let p = m.post { app.stage.show(p, immediate: true) }
                DispatchQueue.main.async { focus = m.lastFocus ?? .play }
            }
        }
        .onChange(of: app.playerOpen) { _, open in
            if !open && active { DispatchQueue.main.async { focus = m.lastFocus ?? .play } }
        }
        .onChange(of: focus) { _, f in
            guard let f else { return }
            if case .rvClose = f {} else { m.lastFocus = f }
        }
        .onChange(of: m.post?.postId) { _, _ in
            DispatchQueue.main.async { focus = .play }
            if autoplay && !autoplayed { autoplayed = true; doPlay(m.startIdx) }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkelBar(w: 640, h: 64)
            SkelBar(w: 420, h: 28).padding(.top, 20)
            SkelBar(w: 760, h: 28).padding(.top, 20)
        }
        .padding(.leading, Th.start).padding(.top, 240)
        .modifier(Pulse())
    }

    // MARK: actions
    private func doPlay(_ i: Int) {
        guard let post = m.post else { return }
        if m.items.isEmpty { app.toast(Session.shared.isLoggedIn ? t("noStream") : t("playLogin"), 3500); return }
        app.player.start(post: post, items: m.items, index: i, resume: m.resume)
    }
    private func openEps() {
        guard !m.epsOpen, m.isSeries, !m.items.isEmpty else { return }
        let s0 = m.items[m.startIdx]["info"]["season"].int ?? m.seasons.first ?? 1
        m.curS = s0; m.shownS = s0
        withAnimation(Th.emph(420)) { m.epsOpen = true }
        let tiles = m.indices(s0)
        let tgt = tiles.firstIndex(of: m.startIdx) ?? 0
        m.epMem[s0] = tgt
        DispatchQueue.main.async { focus = .ep(tiles.isEmpty ? 0 : tiles[tgt]) }
    }
    private func closeEps() {
        withAnimation(Th.out(240)) { m.epsOpen = false }
        DispatchQueue.main.async { focus = .episodes }
    }
    private func setX(_ on: Bool) {
        if on == m.xs { return }
        withAnimation(Th.emph(420)) { m.xs = on }
        app.stage.dim(on ? 0.55 : 0)
    }
    private func back() -> Bool {
        if m.review != nil { closeReview(); return true }
        if m.epsOpen { closeEps(); return true }
        if m.xs { focus = .play; setX(false); return true }
        return false
    }
    private func openReview(_ rv: JSON) {
        withAnimation(Th.out(240)) { m.review = rv }
        DispatchQueue.main.async { focus = .rvClose }
    }
    private func closeReview() {
        withAnimation(Th.out(240)) { m.review = nil }
        DispatchQueue.main.async { focus = m.lastFocus ?? .play }
    }

    // MARK: page
    @ViewBuilder
    private func page(_ post: JSON) -> some View {
        let hasX = xRows.count > 0
        ZStack(alignment: .topLeading) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        column(post, hasX: hasX).frame(height: 872, alignment: .topLeading).id("top")
                        if hasX { extras.transition(.opacity) }
                    }
                }
                .scrollClipDisabled()
                .frame(width: 1920, height: 1080)
                .onChange(of: focus) { _, f in
                    switch f {
                    case .x(let k, _)?:
                        let h = xRows.first { $0.key == k }?.h ?? 364
                        setX(true)
                        withAnimation(Th.emph(420)) { proxy.scrollTo("x." + k, anchor: UnitPoint(x: 0, y: 250 / (1080 - h))) }
                    case .play?, .episodes?:
                        setX(false)
                        withAnimation(Th.emph(420)) { proxy.scrollTo("top", anchor: .top) }
                    default: break
                    }
                }
            }
            .disabled(m.epsOpen || m.review != nil)

            if m.isSeries && !m.items.isEmpty { episodesSheet }
            if let rv = m.review { reviewSheet(rv) }
        }
    }

    private func column(_ post: JSON, hasX: Bool) -> some View {
        let po = post.options, tm = m.tm, eps = m.epsOpen
        let fade = eps ? 0.0 : 1.0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(typeLabel(post, withSeasons: true)).foregroundStyle(Th.accent)
                if po["persian_subtitle"].truthy { Text(t("persianSub")).foregroundStyle(Th.text2) }
                if let n = tm?["next"], n.truthy, m.isSeries { nextBadge(n).transition(.opacity) }
            }
            .font(.vz(Th.tCap, .medium)).frame(height: 32).opacity(fade)
            Group {
                if let lg = tm?["logo"].string, !lg.isEmpty {
                    RemoteImage(url: TMDB.shared.img(lg, "w500"), mode: .fit)
                        .frame(maxWidth: 640, minHeight: 136, maxHeight: 136, alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.45), radius: 9, y: 4)
                } else {
                    Text(post.localizedTitle).font(.vz(Th.tDisplay, .heavy)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
            if !post.otherTitle.isEmpty { Text(post.otherTitle).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2).lineLimit(1).padding(.top, 6) }
            if let tg = tm?["tagline"].string, !tg.isEmpty {
                Text(tg).font(.vz(Th.tBody)).foregroundStyle(Th.text2).lineLimit(1).frame(height: 36).padding(.top, 8).transition(.opacity)
            }
            MetaLine(post: post, nGenres: 3, tmdbRating: (tm?["votes"].num ?? 0) >= 5 && (tm?["rating"].num ?? 0) > 0 ? String(format: "%.1f", tm!["rating"].num) : nil)
                .padding(.top, 12)
            Text(post.localizedPlot).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2).lineLimit(4)
                .lineSpacing(Th.tBodyL * (app.lang == "fa" ? 0.7 : 0.5)).frame(maxWidth: 860, alignment: .leading)
                .padding(.top, 20).opacity(fade)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    TVButton(title: m.items.isEmpty ? t("play") : m.playLabel(), icon: .play, kind: .primary) { doPlay(m.startIdx) }
                        .focused($focus, equals: .play)
                    if m.isSeries && !m.items.isEmpty {
                        TVButton(title: t("episodes"), icon: .list) { openEps() }.focused($focus, equals: .episodes)
                    }
                }
                // Down from the buttons opens the episodes sheet when nothing sits below (no TMDB extras)
                if !hasX && m.isSeries && !m.items.isEmpty && !m.epsOpen {
                    FButton(onFocus: { openEps() }, action: {}) { _ in Color.clear.frame(width: 600, height: 12) }
                        .focused($focus, equals: .epsGate)
                }
            }
            .padding(.top, 36).opacity(fade)
            if let line = castLine(post) { Text(line).font(.vz(Th.tCap)).foregroundStyle(Th.text3).lineLimit(1).padding(.top, 28).opacity(fade) }
        }
        .frame(width: 880, alignment: .leading)
        .padding(.leading, Th.start).padding(.top, 150)
        .offset(y: eps ? -110 : 0)
        .opacity(m.xs ? 0 : 1)
        .animation(Th.emph(420), value: eps)
    }

    private func castLine(_ post: JSON) -> String? {
        if let d = m.tm {
            var bits: [String] = []
            if m.isSeries && d["status"].truthy { bits.append(statusText(d["status"].str)) }
            if !post.info["time"]["default"].truthy && d["runtime"].num > 0 { bits.append(durationText(d["runtime"].num)) }
            let nets = d["nets"].array.map { $0.str }
            if !nets.isEmpty { bits.append(nets.joined(separator: ", ")) }
            if !bits.isEmpty && !d["cast"].array.isEmpty { return bits.joined(separator: " · ") }
        }
        let cast = post["cast"].array
        if cast.isEmpty { return nil }
        return t("cast") + ": " + cast.prefix(6).map { $0["name"].str }.joined(separator: ", ")
    }
    private func statusText(_ s: String) -> String {
        guard app.lang == "fa" else { return s }
        let mp = ["Returning Series": "در حال پخش", "Ended": "پایان‌یافته", "Canceled": "لغو شده", "In Production": "در حال تولید", "Planned": "برنامه‌ریزی‌شده", "Pilot": "پایلوت"]
        return mp[s] ?? s
    }
    private func nextBadge(_ n: JSON) -> some View {
        let s = n["s"].int ?? 0, e = n["e"].int ?? 0
        let lbl = e == 1 ? t("newSeason") + (s > 1 ? " \(s)" : "") : t("nextEp") + " · \u{2066}S\(s)E\(e)\u{2069}"
        return Text(lbl + " · " + fmtDate(n["d"].str)).font(.vz(22, .bold)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Th.accent))
    }
    private func fmtDate(_ iso: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: iso + "T12:00:00") else { return iso }
        let o = DateFormatter(); o.locale = Locale(identifier: app.lang == "fa" ? "fa_IR" : "en_US"); o.setLocalizedDateFormatFromTemplate("MMM d")
        return o.string(from: d)
    }

    // MARK: episodes sheet (DESIGN §9.5)
    private var episodesSheet: some View {
        let open = m.epsOpen
        return ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Th.bg0, location: 0), .init(color: Th.bg0, location: 0.7), .init(color: Th.bg0.opacity(0), location: 1)], startPoint: .bottom, endPoint: .top)
            HStack(spacing: 12) {
                ForEach(m.seasons, id: \.self) { s in
                    PillButton(title: t("season") + " \(s)", cur: m.curS == s, onFocus: { tabFocus(s) }) {
                        let tiles = m.indices(m.curS ?? s)
                        if !tiles.isEmpty { focus = .ep(tiles[min(m.epMem[m.curS ?? s] ?? 0, tiles.count - 1)]) }
                    }
                    .focused($focus, equals: .tab(s))
                }
            }
            .padding(.leading, Th.start).padding(.top, 60)
            .focusSection()
            if let s = m.shownS {
                epTrack(s).padding(.top, 160).opacity(m.swapping ? 0 : 1)
            }
        }
        .frame(width: 1920, height: 600, alignment: .topLeading)
        .padding(.top, 480)
        .offset(y: open ? 0 : 600)
        .opacity(open ? 1 : 0)
        .disabled(!open)
    }
    private func tabFocus(_ s: Int) {
        if m.fromTile {
            m.fromTile = false
            if s != m.curS, let c = m.curS { DispatchQueue.main.async { focus = .tab(c) }; return }
        }
        guard s != m.curS else { return }
        m.curS = s
        withAnimation(Th.out(160)) { m.swapping = true }
        Task {
            await Task.sleep(ms: 160)
            guard m.curS == s else { return }
            m.shownS = s
            withAnimation(Th.out(220)) { m.swapping = false }
        }
    }
    private func epTrack(_ s: Int) -> some View {
        let tiles = m.indices(s)
        return ScrollViewReader { hp in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(tiles.enumerated()), id: \.element) { k, idx in
                        EpTile(item: m.items[idx], idx: idx, progress: m.progress(m.items[idx]), onFocus: {
                            m.epMem[s] = k; m.fromTile = true
                        }) { doPlay(idx) }
                        .focused($focus, equals: .ep(idx))
                        .id(idx)
                    }
                }
                .padding(.leading, Th.start).padding(.trailing, 96).padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .onChange(of: focus) { _, f in
                if case .ep(let i)? = f, tiles.contains(i) { withAnimation(Th.emph(320)) { hp.scrollTo(i, anchor: UnitPoint(x: Th.start / (1920 - 360), y: 0)) } }
                if case .tab? = f {} else if case .ep? = f {} else { m.fromTile = false }
            }
            .onAppear { if let i = tiles.first(where: { $0 == m.startIdx }) { hp.scrollTo(i, anchor: UnitPoint(x: Th.start / (1920 - 360), y: 0)) } }
        }
        .focusSection()
    }

    // MARK: TMDB extras
    private struct XRow { let key: String; let title: String; let h: CGFloat }
    private var xRows: [XRow] {
        guard let d = m.tm else { return [] }
        var r: [XRow] = []
        if !d["cast"].array.isEmpty { r.append(XRow(key: "cast", title: t("cast"), h: 364)) }
        if !d["crew"].array.isEmpty { r.append(XRow(key: "crew", title: t("crew"), h: 364)) }
        if !d["reviews"].array.isEmpty { r.append(XRow(key: "rev", title: t("reviews"), h: 388)) }
        if m.recs.count >= 3 { r.append(XRow(key: "rec", title: t("moreLikeThis"), h: 396)) }
        return r
    }
    private var extras: some View {
        let d = m.tm ?? .null
        return ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Th.bg0.opacity(0), location: 0), .init(color: Th.bg0.opacity(0.9), location: 110 / 3000), .init(color: Th.bg0, location: 200 / 3000)], startPoint: .top, endPoint: .bottom)
                .frame(width: 1920, height: 3000).offset(y: -90).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(xRows, id: \.key) { r in
                    let cur: Bool = { if case .x(let k, _)? = focus { return k == r.key }; return false }()
                    VStack(alignment: .leading, spacing: 16) {
                        Text(r.title).font(.vz(Th.tM, .bold)).foregroundStyle(cur ? Th.text1 : Th.text2).frame(height: 48).padding(.leading, Th.start)
                        xTrack(r, d)
                    }
                    .frame(height: r.h, alignment: .topLeading)
                    .id("x." + r.key)
                    .focusSection()
                }
                Color.clear.frame(height: 700)
            }
        }
    }
    private func xTrack(_ r: XRow, _ d: JSON) -> some View {
        let w: CGFloat = r.key == "rev" ? 520 : (r.key == "rec" ? 200 : 180)
        return ScrollViewReader { hp in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    switch r.key {
                    case "cast", "crew":
                        ForEach(Array(d[r.key].array.enumerated()), id: \.offset) { i, p in
                            FaceCard(person: p, role: r.key == "crew" ? t(p["j"].str) : p["c"].str) {}
                                .focused($focus, equals: .x(r.key, i)).id(i)
                        }
                    case "rev":
                        ForEach(Array(d["reviews"].array.enumerated()), id: \.offset) { i, rv in
                            ReviewCard(review: rv) { openReview(rv) }.focused($focus, equals: .x(r.key, i)).id(i)
                        }
                    default:
                        ForEach(Array(m.recs.enumerated()), id: \.offset) { i, p in
                            PosterCard(post: p) { app.go(.details(id: p.postId, autoplay: false)) }.focused($focus, equals: .x(r.key, i)).id(i)
                        }
                    }
                }
                .padding(.leading, Th.start).padding(.trailing, 96).padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .padding(.top, -12)
            .onChange(of: focus) { _, f in
                if case .x(let k, let i)? = f, k == r.key { withAnimation(Th.emph(320)) { hp.scrollTo(i, anchor: UnitPoint(x: Th.start / (1920 - w), y: 0)) } }
            }
        }
    }

    private func reviewSheet(_ rv: JSON) -> some View {
        ReviewSheet(review: rv, focus: $focus) { closeReview() }
    }
}

/// Cast / crew face: 160 circle, name, role.
struct FaceCard: View {
    let person: JSON
    let role: String
    let action: () -> Void
    private var initials: String {
        let p = person["n"].str.split(separator: " ")
        return ((p.first?.first.map(String.init) ?? "") + (p.count > 1 ? p.last!.first.map(String.init) ?? "" : "")).uppercased()
    }
    var body: some View {
        FButton(action: action) { f in
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Th.surface2)
                    Text(initials).font(.vz(Th.tL, .bold)).foregroundStyle(Th.text3)
                    if person["p"].truthy { RemoteImage(url: TMDB.shared.img(person["p"].str, "w185")).clipShape(Circle()) }
                }
                .frame(width: 160, height: 160)
                .overlay(Circle().stroke(Th.focus, lineWidth: 4).padding(-5).opacity(f ? 1 : 0))
                Text(person["n"].str).font(.vz(Th.tCap, .semibold)).lineLimit(1).padding(.top, 16)
                Text(role).font(.vz(20)).foregroundStyle(Th.text3).lineLimit(1).padding(.top, 8)
            }
            .frame(width: 180, height: 262, alignment: .top)
            .scaleEffect(f ? 1.06 : 1)
            .animation(Th.out(180), value: f)
        }
    }
}

struct ReviewCard: View {
    let review: JSON
    let action: () -> Void
    var body: some View {
        FButton(action: action) { f in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(review["a"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "-").font(.vz(Th.tBody, .bold)).lineLimit(1).frame(maxWidth: 330, alignment: .leading)
                    Spacer()
                    if review["r"].num > 0 { RatingTag(r: review["r"], size: Th.tCap) }
                }
                Text(review["t"].str.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
                    .font(.vz(Th.tCap)).foregroundStyle(Th.text2).lineLimit(5).lineSpacing(Th.tCap * 0.55)
            }
            .padding(.vertical, 24).padding(.horizontal, 28)
            .frame(width: 520, height: 284, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Th.rTile).fill(Th.surface))
            .modifier(CardFocus(f: f, radius: Th.rTile, scale: 1.04, anchor: .center))
        }
    }
}

struct RatingTag: View {
    let r: JSON
    let size: CGFloat
    var body: some View {
        Text("★ " + r.str).font(.vz(size, .bold).monospacedDigit()).foregroundStyle(Th.text1)
            .padding(.vertical, 2).padding(.horizontal, 12).background(RoundedRectangle(cornerRadius: 8).fill(Th.accent))
    }
}

/// Full review reader; ▲ ▼ scroll the text, OK/Back close.
struct ReviewSheet: View {
    let review: JSON
    var focus: FocusState<DetFocus?>.Binding
    let close: () -> Void
    @State private var off: CGFloat = 0
    @State private var textH: CGFloat = 0
    var body: some View {
        ZStack {
            Th.bg0.opacity(0.9)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 24) {
                    Text(review["a"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "-").font(.vz(Th.tL, .bold)).lineLimit(1).frame(maxWidth: 700, alignment: .leading)
                    if review["r"].num > 0 { RatingTag(r: review["r"], size: Th.tBody) }
                    Spacer()
                    if review["d"].truthy { Text(review["d"].str).font(.vz(Th.tCap)).foregroundStyle(Th.text3) }
                }
                .padding(.bottom, 24)
                ZStack(alignment: .topLeading) {
                    Text(review["t"].str).font(.vz(Th.tBody)).foregroundStyle(Th.text2).lineSpacing(Th.tBody * 0.65)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { g in Color.clear.onAppear { textH = g.size.height } })
                        .offset(y: -off)
                        .animation(Th.out(320), value: off)
                }
                .frame(maxWidth: .infinity, maxHeight: 480, alignment: .topLeading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                HStack(spacing: 28) {
                    TVButton(title: t("close"), kind: .primary, action: close)
                        .focused(focus, equals: .rvClose)
                        .onMoveCommand { d in
                            let mx = max(0, textH - 480)
                            if d == .down { off = min(mx, off + 200) } else if d == .up { off = max(0, off - 200) }
                        }
                    Text(t("scrollHint")).font(.vz(Th.tCap)).foregroundStyle(Th.text3)
                }
                .padding(.top, 28)
            }
            .padding(.top, 48).padding(.horizontal, 56).padding(.bottom, 40)
            .frame(width: 1180)
            .background(RoundedRectangle(cornerRadius: Th.rSheet).fill(Th.surface))
        }
        .frame(width: 1920, height: 1080)
        .transition(.opacity)
    }
}
