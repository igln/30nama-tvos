import SwiftUI

enum SetFocus: Hashable { case sec(String), opt(Int) }

/// Settings: section list + option pane (DESIGN §9.8).
struct SettingsView: View {
    let entryId: UUID
    let active: Bool
    let section: String?
    @EnvironmentObject var app: AppState
    @State private var sec = "account"
    @State private var shownSec = "account"
    @State private var swapping = false
    @State private var inPane = false
    @FocusState private var focus: SetFocus?
    /// Survives the language re-render (the whole stack is rebuilt for the new direction).
    @MainActor static var restore: (sec: String, idx: Int)?

    private let secs = ["account", "language", "playback", "display", "about"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(t("settings")).font(.vz(Th.tXL, .bold)).padding(.leading, Th.start).padding(.top, 70)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(secs, id: \.self) { s in
                    FButton(onFocus: { inPane = false; showPane(s) }, action: { firstOption() }) { f in
                        let cur = s == sec
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Th.rTile).fill(f ? Th.focus : Color.clear)
                            if cur { RoundedRectangle(cornerRadius: 3).fill(f ? Th.focusInk : Th.accent).frame(width: 5, height: 40) }
                            Text(t(s)).font(.vz(Th.tBodyL, cur ? .bold : .medium)).foregroundStyle(f ? Th.focusInk : (cur ? Th.text1 : Th.text2)).padding(.horizontal, 28)
                        }
                        .frame(width: 520, height: 80)
                    }
                    .focused($focus, equals: .sec(s))
                }
            }
            .padding(.leading, Th.start).padding(.top, 200)
            .disabled(inPane)

            VStack(alignment: .leading, spacing: 12) { pane(shownSec) }
                .id(shownSec)
                .frame(width: 1000, alignment: .topLeading)
                .padding(.leading, 760).padding(.top, 200)
                .opacity(swapping ? 0 : 1)
                .focusSection()
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .onAppear {
            app.stage.dim(0.72)
            if let r = SettingsView.restore {
                SettingsView.restore = nil
                sec = r.sec; shownSec = r.sec; inPane = true
                DispatchQueue.main.async { focus = .opt(r.idx) }
            } else {
                let s = section ?? "account"; sec = s; shownSec = s
                DispatchQueue.main.async { focus = .sec(s) }
            }
            app.setBack(entryId) {
                if inPane { inPane = false; DispatchQueue.main.async { focus = .sec(sec) }; return true }
                return false
            }
        }
        .onChange(of: active) { _, a in if a { app.stage.dim(0.72); DispatchQueue.main.async { focus = .sec(sec) } } }
        .onChange(of: focus) { _, f in if case .opt? = f { inPane = true } }
    }

    private func showPane(_ s: String) {
        if s == sec { return }
        sec = s
        withAnimation(Th.out(120)) { swapping = true }
        Task {
            await Task.sleep(ms: 120)
            guard sec == s else { return }
            shownSec = s
            withAnimation(Th.out(220)) { swapping = false }
        }
    }
    private func firstOption() {
        shownSec = sec; swapping = false
        DispatchQueue.main.async { focus = .opt(0) }
    }

    // MARK: rows
    private func step(_ d: MoveCommandDirection) -> Int { ((d == .right) != (app.lang == "fa")) ? 1 : -1 }

    private func opt<V: Equatable>(_ idx: Int, _ label: String, _ values: [(v: V, label: String)], get: @escaping () -> V, set: @escaping (V) -> Void) -> some View {
        let cur = values.firstIndex { $0.v == get() } ?? 0
        func cycle(_ d: Int) { set(values[(cur + d + values.count) % values.count].v); refresh() }
        return FButton(action: { cycle(1) }) { f in
            HStack {
                Text(label).font(.vz(Th.tBodyL, .medium))
                Spacer()
                HStack(spacing: 0) {
                    Text("‹ ›").font(.vz(Th.tCap)).opacity(0.6).padding(.horizontal, 12)
                    Text(values[cur].label).font(.vz(Th.tBodyL))
                }
                .foregroundStyle(f ? Th.focusInk.opacity(0.75) : Th.text2)
            }
            .padding(.horizontal, 32)
            .frame(width: 1000, height: 88)
            .foregroundStyle(f ? Th.focusInk : Th.text1)
            .background(RoundedRectangle(cornerRadius: Th.rTile).fill(f ? Th.focus : Th.surface))
        }
        .focused($focus, equals: .opt(idx))
        .onMoveCommand { d in if d == .left || d == .right { cycle(step(d)) } }
    }
    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.vz(Th.tBodyL, .medium))
            Spacer()
            Text(value).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2)
        }
        .padding(.horizontal, 32).frame(width: 1000, height: 88)
        .overlay(alignment: .bottom) { Rectangle().fill(Th.line).frame(height: 1) }
    }
    private func action(_ idx: Int, _ label: String, danger: Bool = false, _ fn: @escaping () -> Void) -> some View {
        FButton(action: fn) { f in
            Text(label).font(.vz(Th.tBodyL, .medium))
                .foregroundStyle(f ? Th.focusInk : (danger ? Th.danger : Th.text1))
                .padding(.horizontal, 32).frame(width: 1000, height: 88, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Th.rTile).fill(f ? Th.focus : Th.surface))
        }
        .focused($focus, equals: .opt(idx))
        .onMoveCommand { _ in }
    }
    @State private var tick = 0
    private func refresh() { tick += 1 }

    @ViewBuilder
    private func pane(_ s: String) -> some View {
        let _ = tick
        switch s {
        case "account":
            let u = Session.shared.user
            if Session.shared.isLoggedIn {
                info(t("account"), u["user_name"].string ?? u["user_email"].string ?? "user")
                info(t("userType"), u["user_type"].exists ? u["user_type"].str : "-")
                info(t("expires"), fmtExpire(u["user_expire"]))
                action(0, t("logout"), danger: true) {
                    app.confirm(title: t("logoutTitle"), body: t("logoutBody"), ok: t("logout"), danger: true) { app.logout() }
                }
            } else {
                info(t("account"), t("guestAcc"))
                action(0, t("login")) { app.go(.login, reset: true) }
            }
        case "language":
            opt(0, t("language"), [(v: "en", label: "English"), (v: "fa", label: "فارسی")], get: { app.lang }) { v in
                SettingsView.restore = ("language", 0)
                app.setLang(v)
            }
        case "playback":
            opt(0, t("defSubs"), [(v: "off", label: t("off")), (v: "fa", label: t("persian")), (v: "en", label: t("english"))],
                get: { Store.string("sub", "off") }) { Store.set("sub", $0) }
            opt(1, t("subSize"), [(v: 38, label: t("small")), (v: 46, label: t("medium")), (v: 54, label: t("large"))],
                get: { Store.int("subSize", 46) }) { Store.set("subSize", $0) }
            Text(t("sample")).font(.vz(CGFloat(Store.int("subSize", 46)), .medium)).shadow(color: .black, radius: 4).shadow(color: .black, radius: 6, y: 2)
                .frame(width: 1000, height: 120).background(RoundedRectangle(cornerRadius: Th.rTile).fill(Color.black))
            opt(2, t("autoplay"), [(v: true, label: t("on")), (v: false, label: t("off"))], get: { Store.bool("autoplay", true) }) { Store.set("autoplay", $0) }
        case "display":
            opt(0, t("reduce"), [(v: false, label: t("off")), (v: true, label: t("on"))], get: { app.calm }) { app.setCalm($0) }
        default:
            info("30nama TV", "")
            info(t("version"), Config.version)
            info(t("unofficial"), "")
            info(t("apiHost"), (API.shared.host ?? "").replacingOccurrences(of: "^https?://", with: "", options: .regularExpression).replacingOccurrences(of: "/api.*$", with: "", options: .regularExpression))
            info(t("tmdb"), TMDB.shared.mock ? t("tmdbMock") : (TMDB.shared.token.isEmpty ? t("tmdbOff") : t("tmdbOn")))
            if TMDB.shared.enabled {
                action(0, t("clearCache")) { TMDB.shared.clearCache(); app.toast(t("cleared")) }
                Text(t("tmdbCredit")).font(.vz(Th.tCap)).foregroundStyle(Th.text3).padding(.top, 12)
            }
        }
    }

    private func fmtExpire(_ v: JSON) -> String {
        if !v.exists || v.str.isEmpty { return t("unknown") }
        if case .number(var n) = v { if n < 1e11 { n *= 1000 }; return isoDay(n) }
        if v.str.range(of: "^\\d{9,13}$", options: .regularExpression) != nil, var n = v.double { if n < 1e11 { n *= 1000 }; return isoDay(n) }
        return v.str
    }
    private func isoDay(_ ms: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
