import SwiftUI
import UIKit

enum Route: Equatable {
    case login
    case home
    case details(id: String, autoplay: Bool)
    case search
    case archive(slug: String?, name: String?)
    case settings(section: String?)

    var name: String {
        switch self {
        case .login: return "login"
        case .home: return "home"
        case .details: return "details"
        case .search: return "search"
        case .archive: return "archive"
        case .settings: return "settings"
        }
    }
}

struct StackEntry: Identifiable, Equatable {
    let id = UUID()
    let route: Route
    static func == (a: StackEntry, b: StackEntry) -> Bool { a.id == b.id }
}

struct ConfirmSheet: Identifiable {
    let id = UUID()
    let title: String, body: String, ok: String, danger: Bool
    let onOk: () -> Void
}

/// Boot, router, rail, modals, splash, back handling (port of js/app.js).
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var stack: [StackEntry] = []
    @Published var booted = false
    @Published var bootError: String?
    @Published var lang = I18n.lang
    @Published var calm = Store.bool("calm", false)
    @Published var toastText: String?
    @Published var modal: ConfirmSheet?
    @Published var splashDone = false
    @Published var splashDots = false
    /// Set to a rail key to move focus into the rail; RootView consumes it.
    @Published var railRequest: String?
    @Published var railOpen = false
    @Published var playerOpen = false

    let stage = StageModel()
    lazy var player = PlayerController(app: self)

    /// Per-screen Back handlers (return true when handled).
    private var backHandlers: [UUID: () -> Bool] = [:]
    private var toastTask: Task<Void, Never>?
    private let splashT0 = Date()

    var current: StackEntry? { stack.last }
    var railVisible: Bool { booted && bootError == nil && current?.route != .login }

    init() {
        API.shared.onSessionInvalid = { [weak self] in self?.logout(silent: true) }
        Task { await Task.sleep(ms: 1800); self.splashDots = true }
        Task { await Task.sleep(ms: 10000); self.splashExit() }
    }

    // MARK: boot
    func boot() {
        bootError = nil
        Task {
            do {
                try await API.shared.initialize()
                if Session.shared.isLoggedIn, let j = try? await API.shared.call("user") , j["success"].truthy, j["result"].truthy {
                    let r = j["result"], u = r["user_session"].truthy ? r : (r["user"]["user_session"].truthy ? r["user"] : JSON.null)
                    if u.truthy { Session.shared.set(user: u) } else { Session.shared.mergeUser(r) }
                }
                booted = true
                if Session.shared.isLoggedIn || Store.bool("guest", false) { go(.home, reset: true) } else { go(.login, reset: true) }
            } catch {
                splashReady()
                bootError = error.localizedDescription
            }
        }
    }

    // MARK: router
    /// reset: clear history; replace: swap top entry.
    func go(_ route: Route, reset: Bool = false, replace: Bool = false) {
        railOpen = false
        let e = StackEntry(route: route)
        if reset { stack.forEach { backHandlers[$0.id] = nil }; stack = [e] }
        else if replace, let last = stack.last { backHandlers[last.id] = nil; stack[stack.count - 1] = e }
        else { stack.append(e) }
        stage.dim(0); stage.details(false)
    }
    func setBack(_ id: UUID, _ fn: @escaping () -> Bool) { backHandlers[id] = fn }

    func onBack() {
        if playerOpen { player.handleBack(); return }
        if modal != nil { modal = nil; return }
        if railOpen { confirmExit(); return }
        if let c = current, let h = backHandlers[c.id], h() { return }
        if stack.count > 1 {
            let top = stack.removeLast(); backHandlers[top.id] = nil
            stage.dim(0); stage.details(false)
            return
        }
        if railVisible { enterRail(); return }
        confirmExit()
    }

    // MARK: rail
    var railCurKey: String {
        var i = stack.count - 1
        while i > 0, stack[i].route.name == "details" { i -= 1 }
        guard i >= 0, i < stack.count else { return "" }
        switch stack[i].route {
        case .archive(let slug, _) where ["movies", "series", "anime"].contains(slug ?? ""): return slug!
        case .settings(let s) where s == "account": return "account"
        default: return stack[i].route.name
        }
    }
    func enterRail() {
        guard railVisible, !railOpen else { return }
        railRequest = railCurKey.isEmpty ? "home" : railCurKey
    }
    func railGo(_ key: String) {
        railOpen = false
        switch key {
        case "search": go(.search, reset: true)
        case "home": go(.home, reset: true)
        case "movies", "series", "anime": go(.archive(slug: key, name: t(key)), reset: true)
        case "archive": go(.archive(slug: nil, name: nil), reset: true)
        case "settings": go(.settings(section: nil), reset: true)
        case "account": go(.settings(section: "account"), reset: true)
        default: break
        }
    }

    // MARK: modal / exit
    func confirm(title: String, body: String, ok: String, danger: Bool, onOk: @escaping () -> Void) {
        if modal != nil { return }
        modal = ConfirmSheet(title: title, body: body, ok: ok, danger: danger, onOk: onOk)
    }
    func confirmExit() {
        confirm(title: t("exitTitle"), body: t("exitBody"), ok: t("exit"), danger: false) {
            // Return to the TV home screen, as the system Menu button would.
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        }
    }

    // MARK: toast
    func toast(_ msg: String, _ ms: Int = 3000) {
        toastText = msg
        toastTask?.cancel()
        toastTask = Task { await Task.sleep(ms: ms); if !Task.isCancelled { self.toastText = nil } }
    }

    // MARK: splash
    func splashReady() {
        if splashDone { return }
        let wait = max(0, 1200 - Int(Date().timeIntervalSince(splashT0) * 1000))
        Task { await Task.sleep(ms: wait); self.splashExit() }
    }
    private func splashExit() {
        if splashDone { return }
        withAnimation(.easeOut(duration: 0.4)) { splashDone = true }
    }

    // MARK: home cache
    private var homeTask: Task<JSON, Error>?, homeT = 0.0
    func getHome() async throws -> JSON {
        if let t = homeTask, nowMs() - homeT < 90000 { return try await t.value }
        homeT = nowMs()
        let t = Task { try await API.shared.get("home_stream") }
        homeTask = t
        do { return try await t.value } catch { homeTask = nil; throw error }
    }
    func dropHome() { homeTask = nil }

    // MARK: session / settings
    func logout(silent: Bool = false) {
        if Session.shared.isLoggedIn { Task { _ = try? await API.shared.call("logout") } }
        Session.shared.clear()
        if !silent { dropHome(); go(.login, reset: true) }
    }
    func setLang(_ l: String) {
        I18n.lang = l; Store.set("lang", l)
        dropHome()
        lang = l
    }
    func setCalm(_ v: Bool) { Store.set("calm", v); calm = v }

    func playerClosed() {
        stage.restore()
    }
}
