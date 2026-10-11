import SwiftUI
import UIKit

/// Image fetch + decode with an in-memory cache and request de-duplication.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    init() { cache.totalCostLimit = 300 << 20 }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if url.isEmpty { return nil }
        if let i = cached(url) { return i }
        if let t = inflight[url] { return await t.value }
        let t = Task<UIImage?, Never> {
            guard let u = URL(string: url), let (d, _) = try? await API.shared.session.data(from: u), let img = UIImage(data: d) else { return nil }
            let ready = await img.byPreparingForDisplay() ?? img
            return ready
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSString, cost: Int(img.size.width * img.size.height * 4)) }
        return img
    }
}

/// Key-repeat detection (DESIGN §7.3): focus changes < 160ms apart mean a held D-pad. Heavy swaps
/// (stage, billboard) are deferred until 220ms after the last change, then settle callbacks run once.
@MainActor
final class FocusPace: ObservableObject {
    static let shared = FocusPace()
    @Published private(set) var fast = false
    private var last = 0.0, settleTask: Task<Void, Never>?
    private var settleFns: [UUID: () -> Void] = [:]

    func tick() {
        let now = nowMs()
        if now - last < 160 && !fast { fast = true }
        last = now
        settleTask?.cancel()
        settleTask = Task {
            await Task.sleep(ms: 220)
            guard !Task.isCancelled, self.fast else { return }
            self.fast = false
            for f in self.settleFns.values { f() }
        }
    }
    func onSettle(_ id: UUID, _ fn: @escaping () -> Void) { settleFns[id] = fn }
    func offSettle(_ id: UUID) { settleFns[id] = nil }
}

/// The one persistent full-bleed backdrop behind every screen (DESIGN §1, §5, §6). Two layers crossfade.
@MainActor
final class StageModel: ObservableObject {
    struct Layer: Identifiable, Equatable {
        let id = UUID()
        let image: UIImage
        let bleed: Bool
        let kb: Int
        static func == (a: Layer, b: Layer) -> Bool { a.id == b.id }
    }
    @Published var layers: [Layer?] = [nil, nil]
    @Published var cur = -1
    @Published var dimLevel: Double = 0
    @Published var detailsOn = false
    @Published var hidden = false

    private var curSrc: String?
    private(set) var curId: String?
    private var token = 0, timer: Task<Void, Never>?

    struct Info { let src: String; let bleed: Bool; let id: String }
    static func info(_ post: JSON) -> Info? {
        let c = post.coverUrl
        if post["_bd"].truthy && (post["_bdPref"].truthy || c.isEmpty) { return Info(src: post["_bd"].str, bleed: false, id: post.postId) }
        if !c.isEmpty { return Info(src: c, bleed: false, id: post.postId) }
        let p = post.posterUrl
        if !p.isEmpty { return Info(src: p, bleed: true, id: post.postId) }
        return nil
    }

    private func swap(_ info: Info, _ done: ((Bool) -> Void)?) {
        token += 1
        let my = token
        Task {
            let img: UIImage? = try? await withTimeout(2500, "stage") { await ImageLoader.shared.load(info.src) }
            guard my == self.token else { return }
            guard let img else { done?(false); return }
            let next = self.cur == 0 ? 1 : 0
            let kbId = Int(info.id) ?? abs(info.id.hashValue)
            self.layers[next] = Layer(image: img, bleed: info.bleed, kb: kbId % 4)
            withAnimation(Th.io(700)) { self.cur = next }
            self.curSrc = info.src; self.curId = info.id
            done?(true)
            let old = next == 0 ? 1 : 0
            Task {
                await Task.sleep(ms: 900)
                if self.cur != old { self.layers[old] = nil }
            }
        }
    }

    /// immediate: no debounce. done(ok) runs once the image is up (or failed).
    func show(_ post: JSON, immediate: Bool = false, done: ((Bool) -> Void)? = nil) {
        timer?.cancel()
        guard let info = StageModel.info(post) else { return }
        if info.src == curSrc { token += 1; done?(true); return }
        if immediate { swap(info, done); return }
        timer = Task {
            await Task.sleep(ms: 350)
            while FocusPace.shared.fast && !Task.isCancelled { await Task.sleep(ms: 120) }
            if Task.isCancelled { return }
            self.swap(info, done)
        }
    }
    func cancel() { timer?.cancel() }
    func dim(_ level: Double) { if dimLevel != level { withAnimation(Th.out(400)) { dimLevel = level } } }
    func details(_ on: Bool) { if detailsOn != on { withAnimation(Th.out(300)) { detailsOn = on } } }
    func hide() { hidden = true }
    func restore() { hidden = false }
}

struct StageView: View {
    @ObservedObject var stage: StageModel
    @EnvironmentObject var app: AppState

    var body: some View {
        let rtl = app.lang == "fa"
        ZStack(alignment: .topLeading) {
            Th.bg1
            ForEach(0..<2, id: \.self) { i in
                if let l = stage.layers[i] {
                    StageLayer(layer: l, rtl: rtl, calm: app.calm)
                        .opacity(stage.cur == i ? 1 : 0)
                        .animation(Th.io(700).delay(stage.cur == i ? 0 : 0.1), value: stage.cur)
                }
            }
            if let c = stage.cur >= 0 ? stage.layers[stage.cur] : nil, c.bleed {
                // bleed mask: bg1 -> transparent across the poster's first 360px
                HStack(spacing: 0) {
                    if !rtl { Spacer(minLength: 0) }
                    LinearGradient(stops: [.init(color: Th.bg1, location: 0), .init(color: Th.bg1.opacity(0), location: 0.5)],
                                   startPoint: rtl ? .trailing : .leading, endPoint: rtl ? .leading : .trailing)
                        .frame(width: 720, height: 1080)
                    if rtl { Spacer(minLength: 0) }
                }
            }
            // scrim-start
            LinearGradient(stops: [.init(color: Th.bg0.opacity(0.96), location: 0), .init(color: Th.bg0.opacity(0.78), location: 0.30), .init(color: Th.bg0.opacity(0), location: 0.68)],
                           startPoint: rtl ? .trailing : .leading, endPoint: rtl ? .leading : .trailing)
            // scrim-bottom
            LinearGradient(stops: [.init(color: Th.bg0, location: 0), .init(color: Th.bg0.opacity(0.85), location: 0.32), .init(color: Th.bg0.opacity(0), location: 0.62)],
                           startPoint: .bottom, endPoint: .top)
            // scrim-top
            LinearGradient(colors: [Th.bg0.opacity(0.5), Th.bg0.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            // scrim-details
            ZStack {
                LinearGradient(stops: [.init(color: Th.bg0.opacity(0.55), location: 0), .init(color: Th.bg0.opacity(0.3), location: 0.45), .init(color: Th.bg0.opacity(0), location: 0.75)],
                               startPoint: rtl ? .trailing : .leading, endPoint: rtl ? .leading : .trailing)
                LinearGradient(stops: [.init(color: Th.bg0.opacity(0.55), location: 0), .init(color: Th.bg0.opacity(0), location: 0.5)], startPoint: .bottom, endPoint: .top)
            }.opacity(stage.detailsOn ? 1 : 0)
            Color.black.opacity(stage.dimLevel)
        }
        .frame(width: 1920, height: 1080)
        .clipped()
        .environment(\.layoutDirection, .leftToRight)
        .opacity(stage.hidden ? 0 : 1)
        .ignoresSafeArea()
    }
}

/// One backdrop layer with the Ken Burns drift (DESIGN §7.2).
private struct StageLayer: View {
    let layer: StageModel.Layer
    let rtl: Bool
    let calm: Bool
    @State private var atEnd = false

    private static let presets: [(s0: CGFloat, x0: CGFloat, y0: CGFloat, s1: CGFloat, x1: CGFloat, y1: CGFloat)] = [
        (1.04, 0, 0, 1.12, -0.015, -0.01),
        (1.12, -0.01, 0, 1.04, 0.01, -0.01),
        (1.04, 0.01, 0.01, 1.10, -0.01, 0),
        (1.10, 0, -0.01, 1.04, 0, 0.01)
    ]

    var body: some View {
        if layer.bleed {
            HStack(spacing: 0) {
                if !rtl { Spacer(minLength: 0) }
                Image(uiImage: layer.image).resizable().aspectRatio(contentMode: .fill).frame(width: 720, height: 1080).clipped()
                if rtl { Spacer(minLength: 0) }
            }
        } else {
            let p = StageLayer.presets[layer.kb]
            let k = atEnd && !calm
            Image(uiImage: layer.image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 1920, height: 1080).clipped()
                .scaleEffect(calm ? 1 : (k ? p.s1 : p.s0))
                .offset(x: 1920 * (k ? p.x1 : p.x0), y: 1080 * (k ? p.y1 : p.y0))
                .onAppear {
                    guard !calm else { return }
                    withAnimation(.linear(duration: 24).repeatForever(autoreverses: true)) { atEnd = true }
                }
        }
    }
}
