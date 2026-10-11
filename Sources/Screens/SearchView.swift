import SwiftUI

enum SearchFocus: Hashable { case key(String), fn(Int), mic, result(Int) }

/// Search with an on-screen grid keyboard (DESIGN §9.6).
struct SearchView: View {
    let entryId: UUID
    let active: Bool
    @EnvironmentObject var app: AppState
    @FocusState private var focus: SearchFocus?
    @State private var q = ""
    @State private var hid = ""
    @State private var kbLang = I18n.lang == "fa" ? "fa" : "en"
    @State private var posts: [JSON] = []
    @State private var header = ""
    @State private var msg = ""
    @State private var swapping = false
    @State private var gen = 0
    @State private var seq = 0
    @State private var debounce: Task<Void, Never>?
    @State private var showTask: Task<Void, Never>?
    @State private var caretOn = true
    @State private var lastFocus: SearchFocus?

    private static let KB: [String: (cols: Int, keys: [String])] = [
        "en": (7, "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)),
        "fa": (8, "ابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهی۰۱۲۳۴۵۶۷۸۹".map(String.init))
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            panel.padding(.leading, Th.start)
            results.padding(.leading, 860)
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .onAppear {
            app.stage.dim(0.72)
            if posts.isEmpty { popular("") }
            DispatchQueue.main.async { focus = .key(SearchView.KB[kbLang]!.keys[0]) }
            app.setBack(entryId) { false }
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) { caretOn = false }
        }
        .onChange(of: active) { _, a in
            if a { app.stage.dim(0.72); DispatchQueue.main.async { focus = lastFocus ?? .key(SearchView.KB[kbLang]!.keys[0]) } }
        }
        .onChange(of: focus) { _, f in if let f { lastFocus = f } }
    }

    // MARK: keyboard panel
    private var panel: some View {
        let L = SearchView.KB[kbLang]!
        let width = CGFloat(L.cols * 72)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 4) {
                if q.isEmpty {
                    Text(t("searchPh")).font(.vz(34, .medium)).foregroundStyle(Th.text3).lineLimit(1)
                } else {
                    Text(q).font(.vz(Th.tXL, .semibold)).lineLimit(1).truncationMode(.head)
                }
                Rectangle().fill(Th.accent).frame(width: 3, height: 56).opacity(caretOn ? 1 : 0)
                Spacer(minLength: 0)
            }
            .frame(width: 620, height: 88)
            .overlay(alignment: .bottom) { Rectangle().fill(Th.line).frame(height: 2) }
            .padding(.top, 90)

            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: L.cols), alignment: .leading, spacing: 8) {
                    ForEach(L.keys, id: \.self) { c in
                        keyButton(c, .key(c)) { type(c) }
                    }
                }
                .frame(width: width, alignment: .leading)
                .environment(\.layoutDirection, kbLang == "fa" ? .rightToLeft : .leftToRight)
                HStack(spacing: 8) {
                    keyButton(t("space"), .fn(0), wide: true) { type(" ") }
                    keyButton("⌫", .fn(1)) { if !q.isEmpty { q.removeLast(); changed() } }
                    keyButton(t("clearK"), .fn(2)) { q = ""; changed() }
                    keyButton(kbLang == "en" ? "فا" : "EN", .fn(3)) {
                        kbLang = kbLang == "en" ? "fa" : "en"
                        DispatchQueue.main.async { focus = .fn(3) }
                    }
                    micKey
                }
                .frame(width: width)
                .environment(\.layoutDirection, .leftToRight)
                .padding(.top, 8)
            }
            .padding(.top, 210)
            .focusSection()

            Text(t("kbHint")).font(.vz(Th.tCap)).foregroundStyle(Th.text3).lineSpacing(Th.tCap * 0.5).frame(width: 620, alignment: .leading)
                .padding(.top, 830)
        }
        .frame(width: 620, alignment: .topLeading)
    }

    private func keyButton(_ label: String, _ id: SearchFocus, wide: Bool = false, _ action: @escaping () -> Void) -> some View {
        FButton(action: action) { f in
            Text(label).font(.vz(id == .fn(0) || id == .fn(2) || id == .fn(3) ? Th.tBody : Th.tBodyL, .medium))
                .lineLimit(1)
                .padding(.horizontal, wide || label.count > 1 ? 18 : 0)
                .frame(minWidth: 64, maxWidth: wide ? .infinity : nil, minHeight: 64, maxHeight: 64)
                .foregroundStyle(f ? Th.focusInk : Th.text1)
                .background(RoundedRectangle(cornerRadius: 12).fill(f ? Th.focus : Th.surface))
        }
        .focused($focus, equals: id)
    }

    /// 🎤: the native text field, so the system keyboard (and dictation) can be used.
    private var micKey: some View {
        TextField("", text: $hid)
            .textFieldStyle(.plain)
            .foregroundStyle(.clear)
            .frame(width: 64, height: 64)
            .background(RoundedRectangle(cornerRadius: 12).fill(focus == .mic ? Th.focus : Th.surface))
            .overlay(Icon.mic.image.font(.system(size: 28)).foregroundStyle(focus == .mic ? Th.focusInk : Th.text1).allowsHitTesting(false))
            .focused($focus, equals: .mic)
            .onChange(of: hid) { _, v in if v != q { q = String(v.prefix(60)); changed() } }
            .onChange(of: focus) { _, f in if f == .mic { hid = q } }
            .onSubmit { debounce?.cancel(); run() }
    }

    private func type(_ c: String) { if q.count < 60 { q += c; changed() } }
    private func changed() {
        debounce?.cancel()
        debounce = Task { await Task.sleep(ms: 500); if !Task.isCancelled { run() } }
    }

    // MARK: results
    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(header).font(.vz(Th.tM, .bold)).frame(height: 88).padding(.top, 90)
                    if !msg.isEmpty {
                        Text(msg).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2).lineSpacing(Th.tBodyL * 0.6).frame(maxWidth: 880, alignment: .leading)
                            .padding(.top, 22).padding(.bottom, 24)
                    } else { Color.clear.frame(height: 22) }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(180), spacing: 16), count: 5), alignment: .leading, spacing: 16) {
                        ForEach(Array(posts.enumerated()), id: \.offset) { i, p in
                            GridCell(post: p, kind: .search) { app.go(.details(id: p.postId, autoplay: false)) }
                                .focused($focus, equals: .result(i))
                                .id(i)
                                .modifier(FadeIn(delay: i < 12 ? Double(i) * 0.015 : 0, key: gen))
                        }
                    }
                    .padding(.leading, 6)
                    .opacity(swapping ? 0 : 1)
                    Color.clear.frame(height: 400)
                }
                .frame(width: 980, alignment: .leading)
            }
            .scrollClipDisabled()
            .frame(width: 980, height: 1080)
            .focusSection()
            .onChange(of: focus) { _, f in
                if case .result(let i)? = f { withAnimation(Th.emph(420)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 300 / (1080 - 330))) } }
            }
            .onChange(of: gen) { _, _ in proxy.scrollTo(0, anchor: .top) }
        }
    }

    private func show(_ ps: [JSON], _ h: String, _ m: String) {
        showTask?.cancel()
        withAnimation(Th.out(120)) { swapping = true }
        showTask = Task {
            await Task.sleep(ms: 120)
            if Task.isCancelled { return }
            posts = ps; header = h; msg = m; gen += 1
            swapping = false
        }
    }
    private func popular(_ m: String) {
        Task {
            guard let h = try? await app.getHome() else { return }
            let ps = h["suggested"]["posts"].isArray ? h["suggested"]["posts"].array : h["movies"]["posts"].array
            show(Array(ps.prefix(15)), t("popularNow"), m)
        }
    }
    private func run() {
        let qq = q.trimmingCharacters(in: .whitespaces)
        seq += 1
        let my = seq
        if qq.isEmpty { popular(""); return }
        Task {
            do {
                let r = try await API.shared.get("search", ["query": qq, "streamonly": "0", "page": "1"])
                guard my == seq else { return }
                let ps = r["posts"].array
                if ps.isEmpty { popular(t("nothingFor") + " “" + qq + "”"); return }
                show(ps, t("topResults"), "")
            } catch {
                if my == seq { popular(t("error") + ": " + error.localizedDescription) }
            }
        }
    }
}

/// `fi` keyframe: opacity 0→1 + translateY 8→0 over 240ms, re-run when `key` changes.
struct FadeIn: ViewModifier {
    let delay: Double
    let key: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
            .onAppear { withAnimation(Th.out(240).delay(delay)) { shown = true } }
            .onChange(of: key) { _, _ in shown = false; withAnimation(Th.out(240).delay(delay)) { shown = true } }
    }
}
