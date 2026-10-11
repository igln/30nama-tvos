import SwiftUI
import AVFoundation

@main
struct Nama30App: App {
    init() {
        Fonts.register()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @StateObject private var app = AppState()
    @FocusState private var railFocus: String?

    var body: some View {
        let rtl = app.lang == "fa"
        ZStack(alignment: .topLeading) {
            Th.bg0.ignoresSafeArea()
            StageView(stage: app.stage)

            // screens: the whole history stays mounted (state and scroll positions survive Back); only the top is live
            ZStack(alignment: .topLeading) {
                ForEach(app.stack) { e in
                    let active = e == app.stack.last
                    ScreenHost(entry: e, active: active)
                        .opacity(active ? 1 : 0)
                        .disabled(!active)
                        .allowsHitTesting(active)
                        .zIndex(active ? 1 : 0)
                }
                if let err = app.bootError {
                    ErrorView(message: err) { app.boot() }
                }
            }
            .frame(width: 1920, height: 1080, alignment: .topLeading)
            .id(app.lang)
            .disabled(app.modal != nil || app.playerOpen)

            if app.railVisible && !app.playerOpen {
                RailView(focus: $railFocus).disabled(app.modal != nil)
            }

            if app.playerOpen { PlayerView(p: app.player).transition(.opacity) }

            ToastView()
            if let m = app.modal { ConfirmView(sheet: m).transition(.opacity) }
            if !app.splashDone { SplashView().transition(.opacity) }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .foregroundStyle(Th.text1)
        .environmentObject(app)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, Locale(identifier: rtl ? "fa_IR" : "en_US"))
        .transaction { if app.calm { $0.animation = nil } }
        .ignoresSafeArea()
        .onExitCommand { app.onBack() }
        .onChange(of: app.railRequest) { _, k in
            guard let k else { return }
            railFocus = k
            app.railRequest = nil
        }
        .onChange(of: railFocus) { _, k in
            withAnimation(Th.out(240)) { app.railOpen = k != nil }
        }
        .onAppear { app.boot() }
        .preferredColorScheme(.dark)
    }
}

struct ScreenHost: View {
    let entry: StackEntry
    let active: Bool
    var body: some View {
        Group {
            switch entry.route {
            case .login: LoginView(entryId: entry.id, active: active)
            case .home: HomeView(entryId: entry.id, active: active)
            case .details(let id, let autoplay): DetailsView(entryId: entry.id, active: active, postId: id, autoplay: autoplay)
            case .search: SearchView(entryId: entry.id, active: active)
            case .archive(let slug, let name):
                if let slug { ArchiveListView(entryId: entry.id, active: active, slug: slug, name: name ?? slug) }
                else { ArchiveView(entryId: entry.id, active: active) }
            case .settings(let section): SettingsView(entryId: entry.id, active: active, section: section)
            }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .pageEnter()
    }
}

// MARK: - rail (DESIGN §8)

struct RailView: View {
    @EnvironmentObject var app: AppState
    var focus: FocusState<String?>.Binding
    private static let items: [(key: String, icon: Icon)] = [
        ("search", .search), ("home", .home), ("movies", .movies), ("series", .series), ("anime", .anime), ("archive", .archive), ("settings", .settings)
    ]
    private func y(_ i: Int) -> CGFloat { i < RailView.items.count ? 288 + CGFloat(i) * 72 : 966 }

    var body: some View {
        let open = app.railOpen, rtl = app.lang == "fa"
        let cur = app.railCurKey
        let all = RailView.items + [("account", Icon.user)]
        let fi = all.firstIndex { $0.key == focus.wrappedValue } ?? 1
        ZStack(alignment: .topLeading) {
            // scrim over content
            Color.black.opacity(open ? 0.45 : 0).frame(width: 1920, height: 1080).allowsHitTesting(false).animation(Th.out(240), value: open)
            // collapsed base
            LinearGradient(colors: [Th.bg0.opacity(0.8), Th.bg0.opacity(0)], startPoint: rtl ? .trailing : .leading, endPoint: rtl ? .leading : .trailing)
                .frame(width: 120, height: 1080)
            // expanded panel
            LinearGradient(stops: [.init(color: Th.bg0.opacity(0.97), location: 0), .init(color: Th.bg0.opacity(0.97), location: 340.0 / 440), .init(color: Th.bg0.opacity(0), location: 1)],
                           startPoint: rtl ? .trailing : .leading, endPoint: rtl ? .leading : .trailing)
                .frame(width: 440, height: 1080)
                .opacity(open ? 1 : 0)
                .offset(x: open ? 0 : (rtl ? 24 : -24))
            Text("30").font(.vz(40, .heavy, latin: true)).foregroundStyle(Th.accent).frame(width: 120, height: 48).padding(.top, 54)
            // shared focus pill
            Capsule().fill(Color.white).frame(width: 300, height: 64)
                .padding(.leading, 20).padding(.top, y(fi))
                .opacity(open ? 1 : 0)
                .animation(Th.out(200), value: fi)
            // the focus section covers only the rail strip, so moves inside content never get pulled into it
            ZStack(alignment: .topLeading) {
                ForEach(Array(all.enumerated()), id: \.offset) { i, m in
                    railItem(m.key, m.icon, i: i, open: open, isCur: cur == m.key)
                        .padding(.top, y(i))
                }
            }
            .frame(width: open ? 320 : 120, height: 1080, alignment: .topLeading)
            .focusSection()
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    @ViewBuilder
    private func railItem(_ key: String, _ icon: Icon, i: Int, open: Bool, isCur: Bool) -> some View {
        FButton(action: { app.railGo(key) }) { f in
            let fg: Color = (open && f) ? Th.focusInk : (isCur ? Th.text1 : Th.text3)
            ZStack(alignment: .leading) {
                if isCur { RoundedRectangle(cornerRadius: 2).fill(Th.accent).frame(width: 4, height: 28) }
                Group {
                    if key == "account" {
                        Circle().fill((open && f) ? Color.black.opacity(0.12) : Th.surface2).frame(width: 40, height: 40)
                            .overlay(icon.image.font(.system(size: 20, weight: .regular)))
                    } else {
                        icon.image.font(.system(size: 30, weight: .light)).frame(width: 40, height: 40)
                    }
                }
                .padding(.leading, 40)
                Text(t(key)).font(.vz(Th.tBodyL, .semibold)).lineLimit(1).padding(.leading, 104)
                    .opacity(open ? 1 : 0).offset(x: open ? 0 : -12)
                    .animation(Th.out(240).delay(Double(i) * 0.02), value: open)
            }
            .foregroundStyle(fg)
            .frame(width: open ? 320 : 120, height: 64, alignment: .leading)
            .contentShape(Rectangle())
        }
        .focused(focus, equals: key)
    }
}

// MARK: - splash (DESIGN §9.1)

struct SplashView: View {
    @EnvironmentObject var app: AppState
    @State private var bloom = false
    @State private var wm = false
    @State private var line = false
    @State private var dotsOn = false
    var body: some View {
        ZStack {
            Th.bg0
            RadialGradient(colors: [Th.accent.opacity(0.38), Th.accent.opacity(0)], center: .center, startRadius: 0, endRadius: 450)
                .frame(width: 900, height: 900)
                .scaleEffect(bloom ? 1.15 : 0.6).opacity(bloom ? 0.35 : 0)
            VStack(spacing: 0) {
                (Text("30").foregroundColor(Th.accent) + Text("nama").foregroundColor(Th.text1))
                    .font(.vz(120, .heavy, latin: true))
                    .opacity(wm ? 1 : 0).offset(y: wm ? 0 : 14)
                Rectangle().fill(Th.accent).frame(width: 240, height: 2).scaleEffect(x: line ? 1 : 0, y: 1)
            }
            .environment(\.layoutDirection, .leftToRight)
            HStack(spacing: 16) {
                ForEach(0..<3) { i in Circle().fill(Th.text2).frame(width: 10, height: 10).modifier(Pulse()).animation(.default.delay(Double(i) * 0.15), value: dotsOn) }
            }
            .offset(y: 100)
            .opacity(app.splashDots ? 1 : 0)
        }
        .frame(width: 1920, height: 1080)
        .onAppear {
            withAnimation(Th.out(1100).delay(0.3)) { bloom = true }
            withAnimation(Th.out(600).delay(0.45)) { wm = true }
            withAnimation(Th.out(700).delay(0.7)) { line = true }
        }
    }
}

// MARK: - confirm sheet / toast (DESIGN §9.12)

struct ConfirmView: View {
    @EnvironmentObject var app: AppState
    let sheet: ConfirmSheet
    @FocusState private var f: Int?
    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(alignment: .leading, spacing: 0) {
                Text(sheet.title).font(.vz(Th.tL, .bold)).padding(.bottom, 12)
                Text(sheet.body).font(.vz(Th.tBody)).foregroundStyle(Th.text2).padding(.bottom, 36)
                HStack(spacing: 16) {
                    TVButton(title: t("cancel")) { app.modal = nil }.focused($f, equals: 0)
                    TVButton(title: sheet.ok, kind: sheet.danger ? .danger : .primary) { app.modal = nil; sheet.onOk() }.focused($f, equals: 1)
                }
            }
            .padding(48)
            .frame(width: 720, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Th.rSheet).fill(Th.surface))
        }
        .frame(width: 1920, height: 1080)
        .focusSection()
        .onAppear { DispatchQueue.main.async { f = 0 } }
    }
}

struct ToastView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack {
            Spacer()
            if let s = app.toastText {
                Text(s).font(.vz(Th.tBody)).lineLimit(1)
                    .padding(.vertical, 16).padding(.horizontal, 32)
                    .background(Capsule().fill(Th.surface.opacity(0.96)))
                    .overlay(Capsule().stroke(Th.line, lineWidth: 1))
                    .transition(.opacity.combined(with: .offset(y: 16)))
                    .padding(.bottom, 80)
            }
        }
        .frame(width: 1920, height: 1080)
        .animation(Th.out(240), value: app.toastText)
        .allowsHitTesting(false)
    }
}
