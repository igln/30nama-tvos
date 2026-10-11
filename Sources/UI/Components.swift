import SwiftUI
import UIKit

// MARK: - focus-aware buttons

/// Renders `make(focused)` for a Button and reports focus gains (the Tizen `onfocus2` hook).
struct FocusAwareStyle<L: View>: ButtonStyle {
    let onFocus: (() -> Void)?
    let make: (Bool) -> L
    func makeBody(configuration: Configuration) -> some View { Styled(onFocus: onFocus, make: make) }
    struct Styled: View {
        @Environment(\.isFocused) private var focused
        let onFocus: (() -> Void)?
        let make: (Bool) -> L
        var body: some View {
            make(focused)
                .onChange(of: focused) { _, f in
                    if f { FocusPace.shared.tick(); onFocus?() }
                }
        }
    }
}

/// A focusable control whose look depends on focus.
struct FButton<L: View>: View {
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> L
    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(FocusAwareStyle(onFocus: onFocus, make: label))
    }
}

/// SF Symbol stand-ins for the Tizen SVG sprite.
enum Icon: String {
    case search = "magnifyingglass", home = "house", movies = "film", series = "tv", anime = "sparkles", archive = "square.grid.2x2"
    case settings = "slider.horizontal.3", user = "person", play = "play.fill", pause = "pause.fill", check = "checkmark", info = "info.circle"
    case list = "list.bullet", warn = "exclamationmark.triangle", back = "arrow.left", mic = "mic"
    var image: Image { Image(systemName: rawValue) }
}

enum BtnKind { case normal, primary, danger }

/// `.btn` (DESIGN §4): 72 tall, white fill on focus, primary rests on accent.
struct TVButton: View {
    let title: String
    var icon: Icon? = nil
    var kind: BtnKind = .normal
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        FButton(onFocus: onFocus, action: action) { f in
            HStack(spacing: 12) {
                if let icon { icon.image.font(.system(size: 26, weight: .semibold)) }
                Text(title).font(.vz(Th.tBody, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 40)
            .frame(height: 72)
            .foregroundStyle(f ? Th.focusInk : (kind == .danger ? Th.danger : (kind == .primary ? Color.white : Th.text1)))
            .background(RoundedRectangle(cornerRadius: Th.rBtn).fill(f ? Th.focus : (kind == .primary ? Th.accent : Color.white.opacity(0.12))))
            .scaleEffect(f ? 1.04 : 1)
            .animation(Th.out(180), value: f)
        }
    }
}

/// `.pill`: 56 tall; current = text-1 with an accent underline.
struct PillButton: View {
    let title: String
    var cur = false
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        FButton(onFocus: onFocus, action: action) { f in
            Text(title).font(.vz(Th.tBody, .semibold)).lineLimit(1)
                .padding(.horizontal, 28)
                .frame(height: 56)
                .foregroundStyle(f ? Th.focusInk : (cur ? Th.text1 : Th.text2))
                .background(Capsule().fill(f ? Th.focus : Color.white.opacity(0.08)))
                .overlay(alignment: .bottom) {
                    if cur { RoundedRectangle(cornerRadius: 2).fill(f ? Th.focusInk : Th.accent).frame(height: 3).padding(.horizontal, 28).padding(.bottom, 7) }
                }
                .animation(Th.out(180), value: f)
        }
    }
}

// MARK: - images

struct RemoteImage: View {
    let url: String
    var mode: ContentMode = .fill
    @State private var img: UIImage?
    var body: some View {
        ZStack {
            if let img {
                Image(uiImage: img).resizable().aspectRatio(contentMode: mode).transition(.opacity)
            }
        }
        .task(id: url) {
            if let c = ImageLoader.shared.cached(url) { img = c; return }
            img = nil
            let i = await ImageLoader.shared.load(url)
            withAnimation(Th.out(240)) { img = i }
        }
    }
}

// MARK: - cards

enum CardKind { case poster, land, top, grid, tile, search }

/// Ring + lift + scale for a focused card (DESIGN §4).
struct CardFocus: ViewModifier {
    let f: Bool
    var radius: CGFloat = Th.rCard
    var scale: CGFloat = 1.08
    var anchor: UnitPoint = .bottom
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.black).shadow(color: .black.opacity(0.55), radius: 24, y: 24).opacity(f ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: radius + 6).stroke(Th.focus, lineWidth: 4).padding(-6).opacity(f ? 1 : 0))
            .scaleEffect(f ? scale : 1, anchor: anchor)
            .animation(Th.out(180), value: f)
    }
}

/// Placeholder (title on surface) + lazily faded-in image.
struct CardArt: View {
    let title: String
    let url: String
    var radius: CGFloat = Th.rCard
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Th.surface)
            Text(title).font(.vz(Th.tCap, .medium)).foregroundStyle(Th.text3).multilineTextAlignment(.center).lineLimit(3).lineSpacing(4).padding(16)
            if !url.isEmpty { RemoteImage(url: url) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

struct Badge: View {
    let options: JSON
    var body: some View {
        if options["coming_soon"].truthy { tag(t("soon"), Th.surface2, Th.text1) }
        else if options["free_stream"].truthy { tag(t("free"), Th.good, Color(hex: 0x06180f)) }
        else if options["persian_subtitle"].truthy { tag(t("sub"), Color.black.opacity(0.7), Th.text1) }
    }
    private func tag(_ s: String, _ bg: Color, _ fg: Color) -> some View {
        Text(s).font(.vz(Th.tCap, .semibold)).foregroundStyle(fg).padding(.vertical, 4).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(bg)).padding(10)
    }
}

/// Poster / grid card: 200x300 (search grid 180x270) with a badge.
struct PosterCard: View {
    let post: JSON
    var kind: CardKind = .poster
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var size: CGSize { kind == .search ? CGSize(width: 180, height: 270) : CGSize(width: 200, height: 300) }
    var body: some View {
        FButton(onFocus: onFocus, action: action) { f in
            CardArt(title: post.localizedTitle, url: post.posterUrl)
                .overlay(alignment: .topLeading) { Badge(options: post.options) }
                .frame(width: size.width, height: size.height)
                .modifier(CardFocus(f: f, anchor: kind == .poster ? .bottom : .center))
        }
    }
}

/// Grid cell: poster + one-line title under it.
struct GridCell: View {
    let post: JSON
    var kind: CardKind = .grid
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        let w: CGFloat = kind == .search ? 180 : 200, h: CGFloat = kind == .search ? 270 : 300
        FButton(onFocus: onFocus, action: action) { f in
            VStack(alignment: .leading, spacing: 14) {
                CardArt(title: post.localizedTitle, url: post.posterUrl)
                    .overlay(alignment: .topLeading) { Badge(options: post.options) }
                    .frame(width: w, height: h)
                    .modifier(CardFocus(f: f, anchor: .center))
                Text(post.localizedTitle).font(.vz(Th.tCap)).foregroundStyle(f ? Th.text1 : Th.text2).lineLimit(1).frame(width: w, alignment: .leading)
            }
        }
    }
}

/// Continue-watching landscape card: 400x225 cover, progress bar, label under it.
struct LandCard: View {
    let post: JSON
    let progress: Double
    let label: String
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        FButton(onFocus: onFocus, action: action) { f in
            VStack(alignment: .leading, spacing: 12) {
                CardArt(title: post.localizedTitle, url: post.coverUrl.isEmpty ? post.posterUrl : post.coverUrl)
                    .overlay(alignment: .bottom) {
                        if progress > 0 {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.25))
                                GeometryReader { g in Capsule().fill(Th.accent).frame(width: g.size.width * min(1, progress)) }
                            }
                            .frame(height: 6).padding(.horizontal, 12).padding(.bottom, 12)
                        }
                    }
                    .frame(width: 400, height: 225)
                    .modifier(CardFocus(f: f))
                Text(label).font(.vz(Th.tCap)).foregroundStyle(Th.text2).lineLimit(1).frame(width: 400, alignment: .leading)
            }
        }
    }
}

/// Top 10: rank numeral (outlined) behind the poster's start edge.
struct TopCard: View {
    let post: JSON
    let rank: Int
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        let wide = rank >= 10
        FButton(onFocus: onFocus, action: action) { f in
            ZStack(alignment: .topLeading) {
                ZStack {
                    StrokeText(text: String(rank), size: wide ? 220 : 260, color: UIColor(white: 0.957, alpha: 0.35))
                    StrokeText(text: String(rank), size: wide ? 220 : 260, color: UIColor(Th.text1)).opacity(f ? 1 : 0)
                }
                .offset(x: -6, y: wide ? 44 - 0.1 * 220 : 30 - 0.1 * 260)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CardArt(title: post.localizedTitle, url: post.posterUrl)
                        .overlay(alignment: .topLeading) { Badge(options: post.options) }
                        .frame(width: 200, height: 300)
                        .modifier(CardFocus(f: f))
                }
            }
            .frame(width: wide ? 420 : 300, height: 300, alignment: .topLeading)
            .animation(Th.out(180), value: f)
        }
    }
}

/// Outlined numeral (CSS `-webkit-text-stroke`).
struct StrokeText: UIViewRepresentable {
    let text: String
    let size: CGFloat
    let color: UIColor
    func makeUIView(context: Context) -> UILabel {
        let l = UILabel(); l.setContentHuggingPriority(.required, for: .horizontal); return l
    }
    func updateUIView(_ l: UILabel, context: Context) {
        let font = UIFont(name: "Vazirmatn-ExtraBold", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
        l.attributedText = NSAttributedString(string: text, attributes: [.font: font, .strokeColor: color, .strokeWidth: 1.4, .foregroundColor: UIColor.clear])
    }
}

/// Genre tile: 360x200 image, shade, name + count.
struct GenreTile: View {
    let name: String
    let count: String
    let image: String
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        FButton(onFocus: onFocus, action: action) { f in
            ZStack(alignment: .bottomLeading) {
                CardArt(title: "", url: image, radius: Th.rTile)
                LinearGradient(stops: [.init(color: Th.bg0.opacity(0.88), location: 0), .init(color: Th.bg0.opacity(0), location: 0.7)], startPoint: .bottom, endPoint: .top)
                    .clipShape(RoundedRectangle(cornerRadius: Th.rTile))
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.vz(Th.tL, .bold)).lineLimit(1).foregroundStyle(Th.text1)
                    Text(count).font(.vz(Th.tCap)).foregroundStyle(Th.text2)
                }
                .padding(.leading, 20).padding(.bottom, 10).frame(maxWidth: 340, alignment: .leading)
            }
            .frame(width: 360, height: 200)
            .modifier(CardFocus(f: f, radius: Th.rTile, anchor: .center))
        }
    }
}

// MARK: - episodes

func epName(_ it: JSON) -> String {
    let i = it["info"]
    var tt = i["title"].truthy ? i["title"] : (i["name"].truthy ? i["name"] : it["title"])
    if tt.isObject {
        tt = (I18n.lang == "fa" && tt["local"].truthy) ? tt["local"] : (tt["english"].truthy ? tt["english"] : tt["local"])
    }
    return tt.string ?? ""
}

/// Typographic episode tile (no stills in the API): 360x200.
struct EpTile: View {
    let item: JSON
    let idx: Int
    var progress: Double = 0
    var watched = false
    var onFocus: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        let i = item["info"], n = i["episode"].int ?? (idx + 1)
        var dur = i["duration"].double ?? i["time"].double ?? 0
        if dur > 600 { dur /= 60 }
        let name = epName(item)
        return FButton(onFocus: onFocus, action: action) { f in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Th.rTile).fill(f ? Th.focus : Th.surface)
                Text("E" + (n < 10 ? "0\(n)" : "\(n)")).font(.vz(64, .heavy, latin: true)).foregroundStyle(f ? Th.focusInk.opacity(0.4) : Th.text3)
                    .padding(.top, 14).padding(.leading, 20)
                HStack {
                    Spacer()
                    if watched { Icon.check.image.font(.system(size: 26, weight: .bold)).foregroundStyle(Th.good) }
                    else if dur > 0 { Text("\(Int(dur.rounded())) " + t("min")).font(.vz(Th.tCap)).foregroundStyle(f ? Th.focusInk.opacity(0.7) : Th.text2) }
                }
                .padding(.top, 20).padding(.trailing, 20)
                VStack { Spacer()
                    Text(name.isEmpty ? t("episode") + " \(n)" : name).font(.vz(Th.tBody, .semibold)).lineLimit(2).lineSpacing(4)
                        .foregroundStyle(f ? Th.focusInk : Th.text1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
                if progress > 0 {
                    VStack { Spacer()
                        GeometryReader { g in Rectangle().fill(Th.accent).frame(width: g.size.width * min(1, progress)) }.frame(height: 4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Th.rTile))
                }
            }
            .frame(width: 360, height: 200)
            .modifier(CardFocus(f: f, radius: Th.rTile, scale: 1.06, anchor: .center))
        }
    }
}

// MARK: - text bits

func typeLabel(_ post: JSON, withSeasons: Bool) -> String {
    let po = post.options, pi = post.info
    var s = po["title_type"].string == "anime" ? t("anime") : (po["is_series"].truthy ? t("series") : t("movie"))
    if withSeasons && po["is_series"].truthy && pi["seasons"].truthy { s += " · " + pi["seasons"].str + " " + t("seasons") }
    return s
}

func durationText(_ m: Double) -> String {
    let min = Int(m)
    if min <= 0 { return "" }
    let h = min / 60, mm = min % 60
    if I18n.lang == "fa" { return (h > 0 ? "\(h) ساعت " : "") + (mm > 0 ? "\(mm) دقیقه" : "") }
    return (h > 0 ? "\(h)h " : "") + (mm > 0 ? "\(mm)m" : "")
}

/// Meta line: [IMDb 7.8] 30nama-score · year · duration · [age] · genres (+ optional extras).
struct MetaLine: View {
    let post: JSON
    var nGenres = 2
    var tmdbRating: String? = nil
    var body: some View {
        let pi = post.info, sc = post["score"]
        var items: [AnyView] = []
        var needDot = false
        func dot() { if needDot { items.append(AnyView(Circle().fill(Th.text2).frame(width: 5, height: 5))) } }
        if sc["imdb"]["score"].truthy {
            items.append(AnyView(outlined("IMDb " + sc["imdb"]["score"].str, radius: 8, bold: true))); needDot = true
        }
        if sc["30nama"]["score"].truthy {
            items.append(AnyView(Text(sc["30nama"]["score"].str).font(.vz(Th.tBody, .bold)).foregroundStyle(Th.good))); needDot = true
        }
        if pi["year"].truthy {
            dot()
            var y = pi["year"].str
            if pi["year_end"].truthy && pi["year_end"].str != y && post.isSeries { y += "–" + pi["year_end"].str }
            items.append(AnyView(Text(y))); needDot = true
        }
        let d = durationText(pi["time"]["default"].num)
        if !d.isEmpty { dot(); items.append(AnyView(Text(d))); needDot = true }
        if pi["age"].truthy { dot(); items.append(AnyView(outlined(pi["age"].str, radius: 6, bold: false))); needDot = true }
        let g = post["genre"].array.prefix(nGenres).map { $0["name"].str }
        if !g.isEmpty { dot(); items.append(AnyView(Text(g.joined(separator: ", ")).lineLimit(1))); needDot = true }
        if let tmdbRating { items.append(AnyView(outlined("TMDB " + tmdbRating, radius: 8, bold: true).transition(.opacity))) }
        return HStack(spacing: 16) { ForEach(items.indices, id: \.self) { items[$0] } }
            .font(.vz(Th.tBody)).foregroundStyle(Th.text2)
    }
    private func outlined(_ s: String, radius: CGFloat, bold: Bool) -> some View {
        Text(s).font(.vz(22, bold ? .semibold : .regular)).foregroundStyle(bold ? Th.text1 : Th.text2)
            .padding(.vertical, bold ? 2 : 1).padding(.horizontal, bold ? 12 : 8)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Th.text3, lineWidth: 2))
    }
}

struct ClockView: View {
    var size: CGFloat = Th.tCap
    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            Text(clockNow()).font(.vz(size, .medium).monospacedDigit()).foregroundStyle(Th.text2)
        }
    }
}

/// Skeleton pulse container (opacity .5 ↔ .85).
struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 0.85 : 0.5)
            .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { on = true } }
    }
}

struct SkelBar: View {
    let w: CGFloat, h: CGFloat
    var body: some View { RoundedRectangle(cornerRadius: 8).fill(Th.surface2).frame(width: w, height: h) }
}

/// Centered error with Retry (focused).
struct ErrorView: View {
    let message: String
    let retry: () -> Void
    @FocusState private var f: Bool
    var body: some View {
        VStack(spacing: 0) {
            Icon.warn.image.font(.system(size: 64, weight: .light)).foregroundStyle(Th.text3).padding(.bottom, 24)
            Text(t("error") + (message.isEmpty ? "" : " (\(message))")).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 900).padding(.bottom, 32)
            TVButton(title: t("retry"), kind: .primary, action: retry).focused($f)
        }
        .frame(width: 1920, height: 1080)
        .onAppear { f = true }
    }
}

/// Page enter: opacity 0→1 + translateY 16→0 over 420ms.
struct PageEnter: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 16)
            .onAppear { withAnimation(Th.emph(420)) { shown = true } }
    }
}

extension View {
    func pageEnter() -> some View { modifier(PageEnter()) }
    /// Absolute placement in the 1920x1080 canvas (top-left origin, mirrored for RTL by the caller when needed).
    func at(x: CGFloat, y: CGFloat) -> some View { self.padding(.leading, x).padding(.top, y).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
}
