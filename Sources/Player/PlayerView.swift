import SwiftUI
import AVFoundation

/// AVPlayerLayer host.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> V {
        let v = V(); v.pl.player = player; v.pl.videoGravity = .resizeAspect; v.backgroundColor = .black; return v
    }
    func updateUIView(_ v: V, context: Context) { if v.pl.player !== player { v.pl.player = player } }
}

enum PFocus: Hashable { case catcher, menu(String), ep(Int), upPlay, upCred }

/// Player overlay (DESIGN §9.9–9.11).
struct PlayerView: View {
    @ObservedObject var p: PlayerController
    @EnvironmentObject var app: AppState
    @FocusState private var focus: PFocus?
    private let SCRUB_W: CGFloat = 1728

    var body: some View {
        let osdOn = p.osd
        ZStack(alignment: .topLeading) {
            Color.black
            VideoSurface(player: p.player).frame(width: 1920, height: 1080)

            // input catcher: owns focus while no sheet is open; OK / arrows / play-pause land here
            FButton(action: { p.handleSelect() }) { _ in Color.clear.frame(width: 1920, height: 1080) }
                .focused($focus, equals: .catcher)
                .disabled(p.menuOpen || p.epsOpen)
                .onMoveCommand { p.handleMove($0) }
                .onPlayPauseCommand { p.handlePlayPause() }

            subtitle(osdOn)
            osdLayer.opacity(osdOn ? 1 : 0).allowsHitTesting(false)
            glyph
            skipPill(osdOn)
            upNextCard(osdOn)
            epsSheet
            menuSheet
            if p.spin { Spinner().frame(width: 72, height: 72).padding(.leading, 924).padding(.top, 504) }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .onAppear { DispatchQueue.main.async { focus = .catcher } }
        .onChange(of: p.menuOpen) { _, o in
            if o { DispatchQueue.main.async { focus = .menu(p.audio.first(where: { $0.sel }).map { "a\($0.id)" } ?? "s" + p.subLang) } }
            else { focus = .catcher }
        }
        .onChange(of: p.epsOpen) { _, o in
            if o { DispatchQueue.main.async { focus = .ep(p.index) } } else { focus = .catcher }
        }
    }

    // MARK: subtitles
    private func subtitle(_ osdOn: Bool) -> some View {
        VStack {
            Spacer()
            Text(p.subText).font(.vz(p.subSize, .medium)).multilineTextAlignment(.center)
                .lineSpacing(p.subSize * (app.lang == "fa" ? 0.6 : 0.4))
                .shadow(color: .black, radius: 4).shadow(color: .black, radius: 6, y: 2)
                .environment(\.layoutDirection, p.subLang == "fa" ? .rightToLeft : .leftToRight)
                .frame(width: 1720)
                .padding(.bottom, 110)
                .offset(y: osdOn ? -150 : 0)
                .animation(Th.out(240), value: osdOn)
        }
        .frame(width: 1920, height: 1080)
        .allowsHitTesting(false)
    }

    // MARK: OSD
    private var osdLayer: some View {
        let d = p.duration, tt = p.shownTime
        let f = d > 0 ? max(0, min(1, tt / d)) : 0, b = d > 0 ? max(0, min(1, p.buffered / d)) : 0
        let x = CGFloat(f) * SCRUB_W
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).frame(width: 1920, height: 240)
            LinearGradient(colors: [Color.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .top).frame(width: 1920, height: 380).padding(.top, 700)
            VStack(alignment: .leading, spacing: 6) {
                Text(p.post.localizedTitle).font(.vz(Th.tL, .bold)).lineLimit(1)
                Text(p.seriesLine(p.index)).font(.vz(Th.tBody)).foregroundStyle(Th.text2).lineLimit(1)
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(.leading, 96).padding(.top, 64)
            ClockView(size: Th.tBody).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 96).padding(.top, 70)

            // scrubber (always LTR)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white.opacity(0.35)).frame(width: SCRUB_W * CGFloat(b))
                    Capsule().fill(Th.accent).frame(width: SCRUB_W * CGFloat(f))
                }
                .frame(width: SCRUB_W, height: 6)
                .scaleEffect(x: 1, y: p.osd ? 1.67 : 1)
                Circle().fill(Color.white).frame(width: 20, height: 20).scaleEffect(p.osd ? 1.4 : 1).offset(x: x - 10, y: -7)
                if p.seekAcc != 0 {
                    HStack(spacing: 10) {
                        Text(fmtTime(tt)).font(.vz(Th.tBodyL, .semibold, latin: true).monospacedDigit())
                        Text((p.seekAcc > 0 ? "+" : "") + JSON.fmt(p.seekAcc) + "s").font(.vz(Th.tBodyL, .semibold, latin: true)).foregroundStyle(Th.accent)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 16)
                    .background(Capsule().fill(Th.surface))
                    .fixedSize()
                    .frame(width: 0)
                    .offset(x: x, y: -76)
                }
            }
            .padding(.leading, 96).padding(.top, 930)
            HStack {
                Text(fmtTime(tt))
                Spacer()
                Text(d > 0 ? "-" + fmtTime(max(0, d - tt)) : "")
            }
            .font(.vz(Th.tBody, .regular, latin: true).monospacedDigit()).foregroundStyle(Th.text2)
            .frame(width: SCRUB_W).padding(.leading, 96).padding(.top, 960)
            Text(p.items.count > 1 ? t("hintPlayerEps") : t("hintPlayer")).font(.vz(Th.tCap)).foregroundStyle(Th.text3)
                .frame(width: SCRUB_W).padding(.leading, 96).padding(.top, 1010)
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    private var glyph: some View {
        GlyphView(kind: p.glyph, hold: p.glyphHold, pulse: p.glyphPulse)
            .frame(width: 140, height: 140).padding(.leading, 890).padding(.top, 470)
            .allowsHitTesting(false)
    }

    // MARK: skip intro / recap (takes OK while visible)
    private func skipPill(_ osdOn: Bool) -> some View {
        let s = p.skip
        return Text((s?.label ?? "") + "  ⏭").font(.vz(Th.tBody, .semibold)).foregroundStyle(Th.focusInk)
            .padding(.horizontal, 36).frame(height: 72)
            .background(RoundedRectangle(cornerRadius: Th.rBtn).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: Th.rBtn).stroke(Color.white, lineWidth: 2))
            .opacity(s == nil ? 0 : 1)
            .offset(x: s == nil ? (app.lang == "fa" ? -24 : 24) : 0, y: osdOn && s != nil ? -140 : 0)
            .animation(Th.emph(320), value: s?.label)
            .animation(Th.emph(320), value: osdOn)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 96).padding(.top, 800)
            .allowsHitTesting(false)
    }

    // MARK: up next
    @ViewBuilder
    private func upNextCard(_ osdOn: Bool) -> some View {
        let u = p.upNext
        let next = p.items.indices.contains(p.index + 1) ? p.items[p.index + 1] : JSON.null
        let info = next["info"]
        let shown = u?.shown ?? false
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Th.rSheet).fill(Th.surface.opacity(0.94))
            CardArt(title: "", url: p.post.coverUrl.isEmpty ? p.post.posterUrl : p.post.coverUrl, radius: 16)
                .frame(width: 320, height: 180).padding(10)
            VStack(alignment: .leading, spacing: 2) {
                Text(t("nextEpisode")).font(.vz(Th.tCap)).foregroundStyle(Th.text3)
                Text("S" + (info["season"].string ?? "1") + " · E" + (info["episode"].string ?? "\(p.index + 2)")).font(.vz(Th.tBodyL, .bold))
                Text(epName(next).isEmpty ? p.post.localizedTitle : epName(next)).font(.vz(Th.tCap)).foregroundStyle(Th.text2).lineLimit(1)
            }
            .padding(.leading, 346).padding(.top, 14).padding(.trailing, 16)
            HStack(spacing: 8) {
                upBtn(t("playNow"), on: u?.sel == "play")
                upBtn(t("credits"), on: u?.sel == "cred")
            }
            .padding(.leading, 346).padding(.top, 136)
            if u?.auto ?? false {
                VStack { Spacer()
                    GeometryReader { g in Rectangle().fill(Th.accent).frame(width: g.size.width * CGFloat(u?.progress ?? 0)) }.frame(height: 4)
                }
            }
        }
        .frame(width: 640, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: Th.rSheet))
        .opacity(shown ? 1 : 0)
        .offset(x: shown ? 0 : (app.lang == "fa" ? -40 : 40), y: osdOn && shown ? -100 : 0)
        .animation(Th.emph(420), value: shown)
        .animation(Th.emph(420), value: osdOn)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 96).padding(.top, 780)
        .allowsHitTesting(false)
    }
    private func upBtn(_ s: String, on: Bool) -> some View {
        Text(s).font(.vz(Th.tCap, .semibold)).foregroundStyle(on ? Th.focusInk : Th.text1)
            .padding(.horizontal, 16).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color.white : Color.white.opacity(0.12)))
    }

    // MARK: episodes (Down, series)
    private var epsSheet: some View {
        let cur = p.items.indices.contains(p.index) ? p.items[p.index] : JSON.null
        let season = cur["info"]["season"].int ?? 1
        let idxs = p.items.indices.filter { (p.items[$0]["info"]["season"].int ?? 1) == season }
        return ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Th.bg0, location: 0), .init(color: Th.bg0, location: 0.7), .init(color: Th.bg0.opacity(0), location: 1)], startPoint: .bottom, endPoint: .top)
            if p.epsOpen {
                ScrollViewReader { hp in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 24) {
                            ForEach(idxs, id: \.self) { i in
                                EpTile(item: p.items[i], idx: i) { p.closeEps(); p.playIndex(i) }
                                    .focused($focus, equals: .ep(i))
                                    .onMoveCommand { if $0 == .down { p.closeEps() } }
                                    .id(i)
                            }
                        }
                        .padding(.leading, Th.start).padding(.trailing, 96).padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                    .onChange(of: focus) { _, f in if case .ep(let i)? = f { withAnimation(Th.emph(320)) { hp.scrollTo(i, anchor: UnitPoint(x: Th.start / (1920 - 360), y: 0)) } } }
                    .onAppear { hp.scrollTo(p.index, anchor: UnitPoint(x: Th.start / (1920 - 360), y: 0)) }
                }
                .padding(.top, 100)
            }
        }
        .frame(width: 1920, height: 420, alignment: .topLeading)
        .padding(.top, 660)
        .offset(y: p.epsOpen ? 0 : 420)
        .disabled(!p.epsOpen)
    }

    // MARK: audio & subtitles sheet (Up)
    private var menuSheet: some View {
        let item = p.items.indices.contains(p.index) ? p.items[p.index] : JSON.null
        var subs: [(id: String, label: String)] = [("off", t("off"))]
        for l in p.availableSubs(item) { subs.append((l, l == "en" ? t("english") : t("persian"))) }
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                if !p.audio.isEmpty {
                    Text(t("audio")).font(.vz(Th.tCap)).foregroundStyle(Th.text3).padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 6)
                    ForEach(p.audio, id: \.id) { a in
                        menuOpt(a.label, sel: a.sel, id: "a\(a.id)") { p.setAudio(a.id); p.closeMenu() }
                    }
                }
                Text(t("subtitles")).font(.vz(Th.tCap)).foregroundStyle(Th.text3).padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 6)
                ForEach(subs, id: \.id) { s in
                    menuOpt(s.label, sel: p.subLang == s.id, id: "s" + s.id) { Store.set("sub", s.id); p.setSub(s.id); p.closeMenu() }
                }
                Spacer()
            }
            .padding(.vertical, 64).padding(.horizontal, 40)
            .frame(width: 640, height: 1080, alignment: .topLeading)
            .background(Color(hex: 0x0e1016).opacity(0.96))
            .offset(x: p.menuOpen ? 0 : 640)
            .opacity(p.menuOpen ? 1 : 0)
            .disabled(!p.menuOpen)
            .focusSection()
        }
        .frame(width: 1920, height: 1080)
    }
    private func menuOpt(_ label: String, sel: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        FButton(action: action) { f in
            HStack(spacing: 16) {
                Icon.check.image.font(.system(size: 24, weight: .bold)).foregroundStyle(f ? Th.focusInk : Th.accent).opacity(sel ? 1 : 0).frame(width: 28)
                Text(label).font(.vz(Th.tBodyL))
                Spacer()
            }
            .padding(.leading, 20).padding(.trailing, 20)
            .frame(width: 560, height: 72)
            .foregroundStyle(f ? Th.focusInk : Th.text1)
            .background(RoundedRectangle(cornerRadius: Th.rBtn).fill(f ? Color.white : Color.clear))
        }
        .focused($focus, equals: .menu(id))
    }
}

/// Centre play/pause glyph: pulse on play, pulse then hold at .9 on pause.
struct GlyphView: View {
    let kind: String?
    let hold: Bool
    let pulse: Int
    @State private var op: Double = 0
    @State private var sc: CGFloat = 0.85
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.45))
            (kind == "pause" ? Icon.pause : Icon.play).image.font(.system(size: 56))
        }
        .opacity(hold && kind == "pause" ? 0.9 : op)
        .scaleEffect(sc)
        .onChange(of: pulse) { _, _ in
            op = 0; sc = 0.85
            withAnimation(Th.out(210)) { op = 1; sc = 1 }
            withAnimation(Th.out(390).delay(0.21)) { op = 0 }
        }
        .onChange(of: kind) { _, k in if k == nil { op = 0 } }
    }
}

struct Spinner: View {
    @State private var r = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 6)
            Circle().trim(from: 0, to: 0.25).stroke(Th.accent, style: StrokeStyle(lineWidth: 6, lineCap: .butt))
                .rotationEffect(.degrees(r ? 360 : 0))
        }
        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { r = true } }
    }
}
