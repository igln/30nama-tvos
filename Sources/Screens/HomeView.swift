import SwiftUI
import Combine

/// One home row.
struct HomeRow: Identifiable {
    let key: String
    let title: String
    let kind: CardKind      // .land | .top | .poster
    var posts: [JSON]
    var raw: [JSON] = []    // continue-watching raw entries
    var id: String { key }
}

enum HomeFocus: Hashable { case play, details, chevPrev, chevNext, card(String, Int), signIn }

@MainActor
final class HomeModel: ObservableObject {
    @Published var loaded = false
    @Published var error: String?
    @Published var heroes: [JSON] = []
    @Published var base: [HomeRow] = []
    @Published var tmRows: [String: HomeRow] = [:]
    @Published var cwIds = Set<String>()
    @Published var browse = false
    @Published var heroIdx = 0
    @Published var curRow: String?
    /// billboard request (post, eyebrow); BillboardView animates the swap
    @Published var bb: (post: JSON, eb: String, key: String)?
    var mem: [String: Int] = [:]
    var lastFocus: HomeFocus?
    var lastAct = nowMs(), heroNav = 0.0
    var curPost: JSON?, curEb = "", curImm = false, shownKey = ""
    private var followTask: Task<Void, Never>?, heroTask: Task<Void, Never>?
    private var subs = Set<AnyCancellable>()
    let settleId = UUID()
    weak var app: AppState?

    var rows: [HomeRow] {
        var out: [HomeRow] = []
        if let cw = base.first(where: { $0.key == "cw" }) { out.append(cw) }
        for k in ["tm_trend", "tm_fresh", "tm_pop"] { if let r = tmRows[k] { out.append(r) } }
        out += base.filter { $0.key != "cw" }
        return out
    }

    func load() {
        guard let app else { return }
        error = nil
        Task {
            let tmOn = TMDB.shared.enabled
            if tmOn { TMDB.shared.startHome() }
            async let homeP = app.getHome()
            async let cwP: JSON? = Session.shared.isLoggedIn ? (try? await API.shared.get("continue_watching")) : nil
            async let tmH: [JSON] = tmOn ? TMDB.shared.heroes(6, 3200) : []
            do {
                let h = try await homeP, cw = await cwP, th = await tmH
                build(h, cw, th)
            } catch {
                app.splashReady()
                self.error = error.localizedDescription
            }
        }
    }

    private func build(_ h: JSON, _ cwRaw: JSON?, _ tmHeroes: [JSON]) {
        heroes = Array(h["hero_header"]["posts"].array.prefix(8))
        if tmHeroes.count >= 3 { heroes = tmHeroes }
        var rows: [HomeRow] = []
        if let cwRaw {
            let cwPosts = extractPosts(cwRaw)
            cwIds = Set(cwPosts.map { $0.postId })
            if !cwPosts.isEmpty { rows.append(HomeRow(key: "cw", title: t("continueWatching"), kind: .land, posts: cwPosts, raw: rawList(cwRaw))) }
        }
        for k in ["new_releases", "suggested", "top_10", "movies", "series", "anime"] {
            let ps = h[k]["posts"].array
            if !ps.isEmpty { rows.append(HomeRow(key: k, title: t(k), kind: k == "top_10" ? .top : .poster, posts: k == "top_10" ? Array(ps.prefix(10)) : ps)) }
        }
        base = rows
        loaded = true
        if heroes.isEmpty { app?.splashReady() } else { setHero(0, first: true) }
        tmSetup()
    }

    // MARK: TMDB rows (inserted after continue watching, trend < fresh < pop)
    private func tmSetup() {
        guard TMDB.shared.enabled else { return }
        for (name, title) in [("trend", "trendingWeek"), ("fresh", "newSeries"), ("pop", "popularMovies")] {
            let f = TMDB.shared.feed(name)
            f.$items.receive(on: RunLoop.main).sink { [weak self] items in
                guard let self else { return }
                let sorted = items.sorted { $0.i < $1.i }
                if var r = self.tmRows["tm_" + name] {
                    var seen = Set(r.posts.map { $0.postId })
                    for it in sorted where !seen.contains(it.post.postId) { seen.insert(it.post.postId); r.posts.append(it.post) }
                    self.tmRows["tm_" + name] = r
                } else if sorted.count >= 5 {
                    self.tmRows["tm_" + name] = HomeRow(key: "tm_" + name, title: t(title), kind: .poster, posts: sorted.map { $0.post })
                }
            }.store(in: &subs)
        }
    }

    // MARK: billboard + stage follow
    func eyebrow(_ p: JSON, _ key: String, _ rank: Int) -> String {
        if key == "hero" { return (p["_hero"].truthy ? t("trendingNow") : t("featured")) + " · " + typeLabel(p, withSeasons: true) }
        if key == "top_10" { return t("top10") + " · #\(rank)" }
        if key == "cw" { return t("continueWatching") }
        return typeLabel(p, withSeasons: true)
    }
    func follow() {
        followTask?.cancel()
        if curPost == nil || FocusPace.shared.fast { return }
        followTask = Task { await Task.sleep(ms: 60); if !Task.isCancelled { self.apply(false) } }
    }
    func apply(_ first: Bool) {
        guard let p = curPost, let app else { return }
        let key = p.postId + "|" + curEb
        if key != shownKey { shownKey = key; bb = (p, curEb, key) }
        app.stage.show(p, immediate: curImm || first, done: first ? { _ in app.splashReady() } : nil)
        curImm = false
    }

    // MARK: hero mode
    func setHero(_ i: Int, first: Bool = false) {
        guard i < heroes.count else { return }
        withAnimation(Th.out(320)) { heroIdx = i }
        if browse { return }
        let p = heroes[i]
        curPost = p; curEb = eyebrow(p, "hero", 0); curImm = true; followTask?.cancel(); apply(first)
    }
    /// Manual slide change: dots/buttons update at once, billboard + backdrop settle after a short debounce.
    func heroStep(_ d: Int) {
        guard heroes.count > 1 else { return }
        let i = (heroIdx + d + heroes.count) % heroes.count
        heroNav = nowMs(); lastAct = heroNav
        withAnimation(Th.out(320)) { heroIdx = i }
        let p = heroes[i]
        curPost = p; curEb = eyebrow(p, "hero", 0); curImm = true; followTask?.cancel(); heroTask?.cancel()
        heroTask = Task { await Task.sleep(ms: 200); if !Task.isCancelled && !self.browse { self.apply(false) } }
    }
    func autoAdvance(blocked: Bool) {
        guard let app, !browse, heroes.count > 1, !app.calm, !app.playerOpen, !app.railOpen, app.modal == nil, !blocked else { return }
        if nowMs() - lastAct < 9000 || nowMs() - heroNav < 12000 { return }
        lastAct = nowMs(); setHero((heroIdx + 1) % heroes.count)
    }
    func exitBrowse() {
        withAnimation(Th.out(160)) { browse = false }
        curRow = nil
        guard heroIdx < heroes.count else { return }
        let p = heroes[heroIdx]
        curPost = p; curEb = eyebrow(p, "hero", 0); curImm = true; lastAct = nowMs()
        followTask?.cancel(); apply(false)
    }

    // MARK: browse mode
    func onCardFocus(_ row: HomeRow, _ i: Int) {
        lastAct = nowMs()
        if !browse { withAnimation(Th.out(160)) { browse = true } }
        mem[row.key] = i
        curRow = row.key
        let p = row.posts[i]
        curPost = p; curEb = eyebrow(p, row.key, i + 1)
        follow()
    }

    func cwNorm(_ x0: JSON) -> (prog: Double, label: String) {
        let c = x0["continue_watching"].truthy ? x0["continue_watching"] : x0
        let tt = c["time"].double ?? c["position"].num, d = c["duration"].num
        let season = c["season"].truthy ? c["season"] : c["info"]["season"], ep = c["episode"].truthy ? c["episode"] : c["info"]["episode"]
        var parts: [String] = []
        if season.truthy && ep.truthy { parts.append("S" + season.str + " · E" + ep.str) }
        if d > 0 && tt > 0 { parts.append("\(max(1, Int(((d - tt) / 60).rounded()))) " + t("minLeft")) }
        return (d > 0 ? min(1, tt / d) : 0, parts.joined(separator: " · "))
    }
}

struct HomeView: View {
    let entryId: UUID
    let active: Bool
    @EnvironmentObject var app: AppState
    @StateObject private var m = HomeModel()
    @FocusState private var focus: HomeFocus?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // rows viewport: y 600…1080; the focused row's header sits at the 640 focus line
    private let VY: CGFloat = 600, VH: CGFloat = 480, ROWH: CGFloat = 396, HEROH: CGFloat = 260

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let e = m.error {
                ErrorView(message: e) { m.load() }
            } else if !m.loaded {
                skeleton
            } else {
                content
            }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .onAppear {
            m.app = app
            let model = m
            FocusPace.shared.onSettle(model.settleId) { [weak model] in model?.follow() }
            if !m.loaded && m.error == nil { m.load() }
        }
        .onDisappear { FocusPace.shared.offSettle(m.settleId); app.stage.cancel() }
        .onChange(of: active) { _, a in
            if a {
                app.stage.dim(0)
                if let p = m.curPost { app.stage.show(p, immediate: true) }
                restoreFocus()
            }
        }
        .onChange(of: app.playerOpen) { _, open in if !open && active { restoreFocus() } }
        .onChange(of: focus) { _, f in if let f { m.lastFocus = f; m.lastAct = nowMs() } }
        .onReceive(tick) { _ in if active { m.autoAdvance(blocked: focus == .chevPrev || focus == .chevNext) } }
        .onAppear { app.setBack(entryId) { false } }
    }

    private func restoreFocus() {
        DispatchQueue.main.async { focus = m.lastFocus ?? (m.heroes.isEmpty ? firstCard : .play) }
    }
    private var firstCard: HomeFocus? { m.rows.first.map { .card($0.key, 0) } }

    // MARK: skeleton
    private var skeleton: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                SkelBar(w: 600, h: 64)
                SkelBar(w: 420, h: 28).padding(.top, 20)
                SkelBar(w: 760, h: 28).padding(.top, 20)
                SkelBar(w: 760, h: 28).padding(.top, 12)
            }
            .padding(.leading, Th.start).padding(.top, 300)
            HStack(spacing: 24) { ForEach(0..<7) { _ in RoundedRectangle(cornerRadius: Th.rCard).fill(Th.surface2).frame(width: 200, height: 300) } }
                .padding(.leading, Th.start).padding(.top, 640)
        }
        .modifier(Pulse())
    }

    // MARK: loaded
    private var content: some View {
        let rows = m.rows
        return ZStack(alignment: .topLeading) {
            ClockView().frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 96).padding(.top, 54)
            BillboardView(bb: m.bb)
                .frame(width: 860, height: 470, alignment: .bottomLeading)
                .padding(.leading, Th.start).padding(.top, 120)

            if m.heroes.count > 1 { chevrons }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        heroUI.frame(height: HEROH, alignment: .topLeading).id("hero")
                        ForEach(rows) { r in rowView(r).frame(height: ROWH, alignment: .topLeading).id("row." + r.key) }
                        if !Session.shared.isLoggedIn { guestNote.id("guest") }
                        Color.clear.frame(height: 120)
                    }
                }
                .scrollClipDisabled(false)
                .frame(width: 1920, height: VH)
                .padding(.top, VY)
                .onChange(of: m.browse) { _, b in if !b { withAnimation(Th.emph(420)) { proxy.scrollTo("hero", anchor: .top) } } }
                .onChange(of: m.curRow) { _, r in
                    guard let r else { return }
                    // header at y=640: anchor a solves a·(VH − ROWH) = 40
                    withAnimation(Th.emph(420)) { proxy.scrollTo("row." + r, anchor: UnitPoint(x: 0, y: 40 / (VH - ROWH))) }
                }
                .onChange(of: rows.map(\.key)) { _, _ in
                    if let r = m.curRow { proxy.scrollTo("row." + r, anchor: UnitPoint(x: 0, y: 40 / (VH - ROWH))) }
                }
            }
        }
        .onAppear { restoreFocus() }
    }

    private var chevrons: some View {
        ZStack(alignment: .topLeading) {
            chev(prev: true).focused($focus, equals: .chevPrev).padding(.leading, 122).padding(.top, 350)
            chev(prev: false).focused($focus, equals: .chevNext).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 40).padding(.top, 350)
        }
        .opacity(m.browse ? 0 : 1)
        .disabled(m.browse)
    }
    private func chev(prev: Bool) -> some View {
        FButton(onFocus: { if m.browse { m.exitBrowse() }; m.heroNav = nowMs(); m.lastAct = m.heroNav },
                action: { m.heroStep(prev ? -1 : 1) }) { f in
            Image(systemName: prev ? "chevron.backward" : "chevron.forward").font(.system(size: 26, weight: .heavy))
                .foregroundStyle(f ? Th.focusInk : .white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(f ? Th.focus : Color.black.opacity(0.35)))
                .opacity(f ? 1 : 0.55).scaleEffect(f ? 1.12 : 1)
                .animation(Th.out(180), value: f)
        }
    }

    private var heroUI: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 16) {
                let p = m.heroes.indices.contains(m.heroIdx) ? m.heroes[m.heroIdx] : JSON.null
                TVButton(title: m.cwIds.contains(p.postId) ? t("resume") : t("play"), icon: .play, kind: .primary,
                         onFocus: heroFocus, action: { goDetails(p, play: true) })
                    .focused($focus, equals: .play)
                TVButton(title: t("details"), icon: .info, onFocus: heroFocus, action: { goDetails(p, play: false) })
                    .focused($focus, equals: .details)
            }
            HStack(spacing: 20) {
                ForEach(m.heroes.indices, id: \.self) { k in
                    Circle().fill(k == m.heroIdx ? Th.accent : Color.white.opacity(0.35)).frame(width: 12, height: 12)
                        .scaleEffect(k == m.heroIdx ? 1.5 : 1)
                }
            }
        }
        .padding(.top, 20).padding(.leading, Th.start)
        .opacity(m.heroes.isEmpty ? 0 : (m.browse ? 0 : 1))
        .disabled(m.heroes.isEmpty)
    }
    private func heroFocus() {
        if m.browse { m.exitBrowse() } else if m.heroIdx < m.heroes.count { m.curPost = m.heroes[m.heroIdx] }
    }

    private func rowView(_ r: HomeRow) -> some View {
        let isCur = m.browse && m.curRow == r.key
        let idx = m.rows.firstIndex { $0.key == r.key } ?? 0, curIdx = m.rows.firstIndex { $0.key == m.curRow } ?? -1
        let past = m.browse && idx < curIdx
        let w: CGFloat = r.kind == .land ? 400 : 200
        return VStack(alignment: .leading, spacing: 16) {
            Text(r.title).font(.vz(Th.tM, .bold)).foregroundStyle(isCur ? Th.text1 : Th.text2).frame(height: 48).padding(.leading, Th.start)
            ScrollViewReader { hp in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(Array(r.posts.enumerated()), id: \.offset) { i, p in
                            card(r, i, p)
                                .focused($focus, equals: .card(r.key, i))
                                .id(i)
                        }
                    }
                    .padding(.leading, Th.start).padding(.trailing, 96).padding(.vertical, 12)
                }
                .scrollClipDisabled()
                .onChange(of: focus) { _, f in
                    guard case .card(let k, let i)? = f, k == r.key else { return }
                    let cw = r.kind == .top ? (i + 1 >= 10 ? 420 : 300) : w
                    // start-anchored track: the focused card sits at x = 184
                    withAnimation(FocusPace.shared.fast ? Th.emph(140) : Th.emph(320)) { hp.scrollTo(i, anchor: UnitPoint(x: Th.start / (1920 - cw), y: 0)) }
                }
            }
            .padding(.top, -12)
        }
        .opacity(past ? 0 : 1)
        .animation(Th.out(240), value: past)
        .focusSection()
    }

    @ViewBuilder
    private func card(_ r: HomeRow, _ i: Int, _ p: JSON) -> some View {
        let onF = { m.onCardFocus(r, i) }
        switch r.kind {
        case .land:
            let n = m.cwNorm(i < r.raw.count ? r.raw[i] : p)
            LandCard(post: p, progress: n.prog, label: n.label.isEmpty ? p.localizedTitle : n.label, onFocus: onF) { goDetails(p, play: false) }
        case .top:
            TopCard(post: p, rank: i + 1, onFocus: onF) { goDetails(p, play: false) }
        default:
            PosterCard(post: p, onFocus: onF) { goDetails(p, play: false) }
        }
    }

    private var guestNote: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(t("loginRequired")).font(.vz(Th.tBody)).foregroundStyle(Th.text2)
            TVButton(title: t("signIn"), onFocus: {
                if !m.browse { withAnimation(Th.out(160)) { m.browse = true } }
                m.curRow = nil; m.curPost = nil
            }) { app.go(.login, reset: true) }
            .focused($focus, equals: .signIn)
        }
        .padding(.leading, Th.start).padding(.top, 40)
        .frame(height: 200, alignment: .topLeading)
    }

    private func goDetails(_ p: JSON, play: Bool) {
        guard p.truthy else { return }
        app.go(.details(id: p.postId, autoplay: play))
    }
}

/// Billboard text with the out → staggered-rise swap (DESIGN §7.1).
struct BillboardView: View {
    let bb: (post: JSON, eb: String, key: String)?
    @EnvironmentObject var app: AppState
    @State private var shown: (post: JSON, eb: String, key: String)?
    @State private var visible = true
    @State private var rise = false
    @State private var swapTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = shown {
                let p = s.post, o = p.otherTitle
                item(0) { Text(s.eb).font(.vz(Th.tCap, .medium)).tracking(app.lang == "fa" ? 0 : 0.88).foregroundStyle(Th.accent).frame(height: 32).lineLimit(1) }
                item(1) { TitleOrLogo(post: p, size: Th.tDisplay, minLogoH: 136).padding(.top, 8) }
                if !o.isEmpty { item(2) { Text(o).font(.vz(Th.tBody)).foregroundStyle(Th.text2).lineLimit(1).frame(height: 40).padding(.top, 6) } }
                item(3) { MetaLine(post: p, nGenres: 2).padding(.top, 10) }
                item(4) {
                    Text(p.localizedPlot).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2).lineLimit(3)
                        .lineSpacing(Th.tBodyL * (app.lang == "fa" ? 0.7 : 0.5)).frame(maxWidth: 820, alignment: .leading).padding(.top, 12)
                }
            }
        }
        .onChange(of: bb?.key) { _, _ in swap() }
        .onAppear { if shown == nil, let bb { shown = bb } }
    }

    private func item<V: View>(_ i: Int, @ViewBuilder _ v: () -> V) -> some View {
        v().opacity(visible ? 1 : 0).offset(y: rise ? 12 : 0)
            .animation(visible ? Th.out(260).delay(Double(i) * 0.04) : Th.out(120), value: visible)
            .animation(Th.out(260).delay(Double(i) * 0.04), value: rise)
    }

    private func swap() {
        guard let bb else { return }
        swapTask?.cancel()
        if shown == nil || app.calm { shown = bb; visible = true; return }
        visible = false
        swapTask = Task {
            await Task.sleep(ms: 120)
            if Task.isCancelled { return }
            var tr = Transaction(); tr.disablesAnimations = true
            withTransaction(tr) { shown = bb; rise = true }
            visible = true; rise = false
        }
    }
}

/// Title, or the TMDB title logo when the post carries one.
struct TitleOrLogo: View {
    let post: JSON
    let size: CGFloat
    var minLogoH: CGFloat = 136
    @EnvironmentObject var app: AppState
    var body: some View {
        if post["_logo"].truthy {
            RemoteImage(url: post["_logo"].str, mode: .fit)
                .frame(maxWidth: 640, minHeight: minLogoH, maxHeight: minLogoH, alignment: .bottomLeading)
                .shadow(color: .black.opacity(0.45), radius: 9, y: 4)
        } else {
            Text(post.localizedTitle).font(.vz(size, .heavy)).lineLimit(2)
                .lineSpacing(size * (app.lang == "fa" ? 0.3 : 0.08) - 6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
