import SwiftUI

/// Wrapping row layout (CSS flex-wrap).
struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += sz.width + spacing; lineH = max(lineH, sz.height); w = max(w, x - spacing)
        }
        return CGSize(width: min(w, maxW), height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > bounds.width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; lineH = max(lineH, sz.height)
        }
    }
}

@MainActor enum MenuCache { static var menu: JSON? }

enum ArchFocus: Hashable { case cat(Int), genre(Int), sort(String), cell(Int) }

/// Archive landing: categories + genre tiles (DESIGN §9.7).
struct ArchiveView: View {
    let entryId: UUID
    let active: Bool
    @EnvironmentObject var app: AppState
    @State private var menu: JSON? = MenuCache.menu
    @State private var error: String?
    @State private var scrolled = false
    @State private var lastFocus: ArchFocus?
    @FocusState private var focus: ArchFocus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let e = error {
                ErrorView(message: e) { app.go(.archive(slug: nil, name: nil), replace: true) }
            } else if let m = menu {
                content(m)
            } else {
                Text(t("loading")).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2).padding(.leading, Th.start).padding(.top, 300)
            }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .onAppear {
            app.stage.dim(0.72)
            app.setBack(entryId) { false }
            if menu == nil {
                Task {
                    do { let m = try await API.shared.get("menu"); MenuCache.menu = m; menu = m; DispatchQueue.main.async { focus = .cat(0) } }
                    catch { self.error = error.localizedDescription }
                }
            } else { DispatchQueue.main.async { focus = .cat(0) } }
        }
        .onChange(of: active) { _, a in if a { app.stage.dim(0.72); DispatchQueue.main.async { focus = lastFocus ?? .cat(0) } } }
        .onChange(of: focus) { _, f in if let f { lastFocus = f } }
    }

    private func content(_ m: JSON) -> some View {
        let cats = m["categories"].array, genres = m["genres"].array
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(t("browse")).font(.vz(Th.tXL, .bold)).padding(.top, 60).frame(height: 190, alignment: .topLeading).id("top")
                        .opacity(scrolled ? 0 : 1).animation(Th.out(240), value: scrolled)
                    FlowLayout(spacing: 12, lineSpacing: 12) {
                        ForEach(Array(cats.enumerated()), id: \.offset) { i, c in
                            PillButton(title: c["name"].str) { app.go(.archive(slug: c["slug"].str, name: c["name"].str)) }
                                .focused($focus, equals: .cat(i)).id("c\(i)")
                        }
                    }
                    .frame(width: 1640, alignment: .leading)
                    Text(t("genres")).font(.vz(Th.tL, .bold)).padding(.top, 48).padding(.bottom, 24)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(360), spacing: 24), count: 4), alignment: .leading, spacing: 32) {
                        ForEach(Array(genres.enumerated()), id: \.offset) { i, g in
                            let im = g["image"]
                            let u = im["webp"]["full"].string ?? im["webp"]["thumb"].string ?? im["jpg"]["full"].string ?? im["jpg"]["thumb"].str
                            GenreTile(name: g["name"].str, count: g["count"].string ?? "", image: u) {
                                app.go(.archive(slug: g["slug"].str, name: g["name"].str))
                            }
                            .focused($focus, equals: .genre(i)).id("g\(i)")
                        }
                    }
                    .frame(width: 1560, alignment: .leading)
                    .padding(.bottom, 400)
                }
                .padding(.leading, Th.start)
            }
            .scrollClipDisabled()
            .onChange(of: focus) { _, f in
                // keep the focused element at y=260
                switch f {
                case .cat?: scrolled = false; withAnimation(Th.emph(420)) { proxy.scrollTo("top", anchor: .top) }
                case .genre(let i)?: scrolled = true; withAnimation(Th.emph(420)) { proxy.scrollTo("g\(i)", anchor: UnitPoint(x: 0, y: 260 / (1080 - 200))) }
                default: break
                }
            }
        }
    }
}

/// Paged, sortable poster grid for a category / genre slug.
struct ArchiveListView: View {
    let entryId: UUID
    let active: Bool
    let slug: String
    let name: String
    @EnvironmentObject var app: AppState
    @State private var posts: [JSON] = []
    @State private var page = 1
    @State private var pages = 1
    @State private var total = 0
    @State private var loading = false
    @State private var sort = "date"
    @State private var gen = 0
    @State private var error: String?
    @State private var scrolled = false
    @State private var lastFocus: ArchFocus?
    @FocusState private var focus: ArchFocus?
    private let COLS = 7
    private static let SORTS = [("date", "newest"), ("favorite", "popular"), ("update", "updated")]

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let e = error, posts.isEmpty {
                ErrorView(message: e) { error = nil; reset() }
            } else {
                grid
            }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .onAppear {
            app.stage.dim(0.72)
            app.setBack(entryId) { false }
            if posts.isEmpty && !loading { load() }
        }
        .onChange(of: active) { _, a in if a { app.stage.dim(0.72); DispatchQueue.main.async { focus = lastFocus ?? .cell(0) } } }
        .onChange(of: focus) { _, f in if let f { lastFocus = f } }
    }

    private var grid: some View {
        let skel = loading ? (page == 1 && posts.isEmpty ? 14 : 7) : 0
        return ZStack(alignment: .topLeading) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 250).id("top")
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(200), spacing: 32), count: COLS), alignment: .leading, spacing: 42) {
                            ForEach(Array(posts.enumerated()), id: \.offset) { i, p in
                                GridCell(post: p, onFocus: { cellFocus(i) }) { app.go(.details(id: p.postId, autoplay: false)) }
                                    .focused($focus, equals: .cell(i)).id(i)
                            }
                            ForEach(0..<skel, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: Th.rCard).fill(Th.surface2).frame(width: 200, height: 300).frame(height: 344, alignment: .top).modifier(Pulse())
                            }
                        }
                        .frame(width: 1700, alignment: .leading)
                        .padding(.bottom, 600)
                    }
                    .padding(.leading, Th.start)
                }
                .scrollClipDisabled()
                .onChange(of: focus) { _, f in
                    switch f {
                    case .cell(let i)?:
                        scrolled = i >= COLS
                        withAnimation(Th.emph(420)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 260 / (1080 - 344))) }
                    case .sort?: scrolled = false; withAnimation(Th.emph(420)) { proxy.scrollTo("top", anchor: .top) }
                    default: break
                    }
                }
                .onChange(of: gen) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
            // header + sorts slide up and fade with the first scroll
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(name).font(.vz(Th.tXL, .bold)).lineLimit(1)
                if total > 0 { Text(NumberFormatter.localizedString(from: NSNumber(value: total), number: .decimal) + " " + t("results")).font(.vz(Th.tBody)).foregroundStyle(Th.text3) }
            }
            .padding(.leading, Th.start).padding(.top, 60)
            .opacity(scrolled ? 0 : 1).offset(y: scrolled ? -40 : 0)
            .animation(Th.emph(420), value: scrolled)
            HStack(spacing: 12) {
                ForEach(ArchiveListView.SORTS, id: \.0) { s in
                    PillButton(title: t(s.1), cur: sort == s.0) {
                        if sort == s.0 { return }
                        sort = s.0; reset()
                    }
                    .focused($focus, equals: .sort(s.0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 96).padding(.top, 66)
            .opacity(scrolled ? 0 : 1).offset(y: scrolled ? -40 : 0)
            .animation(Th.emph(420), value: scrolled)
            .focusSection()
        }
    }

    private func cellFocus(_ idx: Int) {
        let row = idx / COLS, rows = (posts.count + COLS - 1) / COLS
        if row >= rows - 2 && page < pages && !loading { page += 1; load() }
    }

    private func reset() {
        gen += 1; page = 1; pages = 1; posts = []; scrolled = false
        load()
    }
    private func load() {
        if loading { return }
        loading = true
        let my = gen, pg = page
        Task {
            do {
                let r = try await API.shared.get("archive", ["slugs": slug, "streamonly": "1", "page": String(pg), "orderby": sort, "order": "desc"])
                guard my == gen else { return }
                loading = false
                let first = posts.isEmpty
                if let tt = r["total"].int, tt > 0 { total = tt }
                pages = r["pages"].int ?? 1
                posts += r["posts"].array
                if first { DispatchQueue.main.async { focus = posts.isEmpty ? .sort(sort) : .cell(0) } }
            } catch {
                guard my == gen else { return }
                loading = false
                if posts.isEmpty { self.error = error.localizedDescription }
            }
        }
    }
}
