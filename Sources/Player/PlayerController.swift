import SwiftUI
import AVFoundation
import Combine

struct Cue { let s: Double; let e: Double; let t: String }

/// Player state + logic (port of js/player.js). AVPlayer plays the HLS stream; subtitles are our own WebVTT overlay.
@MainActor
final class PlayerController: ObservableObject {
    unowned let app: AppState
    init(app: AppState) { self.app = app }

    let player = AVPlayer()
    @Published var post: JSON = .null
    @Published var items: [JSON] = []
    @Published var index = 0
    @Published var paused = false
    @Published var spin = false
    @Published var osd = false
    @Published var subText = ""
    @Published var subLang = "off"
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
    @Published var seekAcc: Double = 0
    @Published var skip: (label: String, to: Double)?
    @Published var menuOpen = false
    @Published var epsOpen = false
    @Published var glyph: String?          // "play" | "pause"
    @Published var glyphHold = false
    @Published var glyphPulse = 0
    @Published var upNext: UpNext?
    @Published var audio: [(id: Int, label: String, sel: Bool)] = []

    struct UpNext { var sel = "play"; var dismissed = false; var auto = true; var hold = false; var shown = true; var progress: Double = 0; var started = Date() }

    private var cues: [Cue] = []
    private var subCache: [String: [Cue]] = [:]
    private var resume: JSON?
    private var timeObs: Any?
    private var bag = Set<AnyCancellable>()
    private var hbTimer: Timer?, osdTask: Task<Void, Never>?, seekTask: Task<Void, Never>?, loadTask: Task<Void, Never>?, glyphTask: Task<Void, Never>?, upTask: Task<Void, Never>?
    private var loading = false
    private var audioGroup: AVMediaSelectionGroup?
    var subSize: CGFloat { CGFloat(Store.int("subSize", 46)) }

    // MARK: lifecycle
    func start(post: JSON, items: [JSON], index: Int, resume: JSON?) {
        self.post = post; self.items = items; self.resume = resume
        app.stage.hide()
        withAnimation(Th.out(250)) { app.playerOpen = true }
        playIndex(index)
    }

    func seriesLine(_ i: Int) -> String {
        guard items.indices.contains(i) else { return "" }
        let info = items[i]["info"]
        if items.count > 1 || info["season"].truthy {
            let n = epName(items[i])
            return "S" + (info["season"].string ?? "1") + " · E" + (info["episode"].string ?? "\(i + 1)") + (n.isEmpty ? "" : " — " + n)
        }
        return ""
    }

    func playIndex(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items[i]
        reportNow()
        stopBackend()
        index = i; paused = false; cues = []; subLang = Store.string("sub", "off"); subText = ""
        skip = nil; hideUpNext(force: true); closeEps(silent: true)
        var url = PlayerController.pickUrl(item["file"]["m3u8"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if url?.isEmpty ?? true { url = nil }
        guard let u = url, let U = URL(string: u) else {
            let raw = String((String(data: item["file"]["m3u8"].data() ?? Data(), encoding: .utf8) ?? "").prefix(160))
            app.toast(t("noStream") + " " + raw, 6000)
            close(); return
        }
        var start = 0.0
        if let r = resume, r["file_id"].str == item["info"]["file_id"].str { start = r["time"].num }
        resume = nil
        spin = true; glyph = nil; glyphHold = false
        loading = true
        let pi = AVPlayerItem(url: U)
        pi.preferredForwardBufferDuration = 0
        player.replaceCurrentItem(with: pi)
        pi.publisher(for: \.status).receive(on: RunLoop.main).sink { [weak self] st in
            guard let self, self.player.currentItem === pi else { return }
            if st == .readyToPlay && self.loading {
                self.loading = false; self.loadTask?.cancel()
                self.duration = pi.duration.seconds.isFinite ? pi.duration.seconds : 0
                if start > 5 { self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                self.player.play()
                self.spin = false
                let subs = self.availableSubs(item)
                let want = subs.contains(self.subLang) ? self.subLang : "off"
                self.setSub(want)
                self.loadAudio(pi)
                self.showOsd()
            } else if st == .failed {
                self.onError(pi.error?.localizedDescription ?? "error")
            }
        }.store(in: &bag)
        player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] s in
            guard let self, !self.loading else { return }
            self.spin = s == .waitingToPlayAtSpecifiedRate && !self.paused
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: pi).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onEnded() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: pi).receive(on: RunLoop.main)
            .sink { [weak self] n in self?.onError((n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "error") }.store(in: &bag)
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        loadTask = Task { await Task.sleep(ms: 25000); if !Task.isCancelled && self.loading && self.player.currentItem === pi { self.onError("timeout") } }
        hbTimer?.invalidate()
        hbTimer = Timer.scheduledTimer(withTimeInterval: Double(Config.heartbeatMs) / 1000, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        seekAcc = 0
        time = 0; duration = 0; buffered = 0
    }

    private func stopBackend() {
        if let o = timeObs { player.removeTimeObserver(o); timeObs = nil }
        bag.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        audioGroup = nil; audio = []
    }

    func close() {
        guard app.playerOpen else { return }
        reportNow()
        hbTimer?.invalidate(); osdTask?.cancel(); seekTask?.cancel(); loadTask?.cancel(); upTask?.cancel()
        stopBackend()
        menuOpen = false; epsOpen = false; upNext = nil; skip = nil; osd = false; subText = ""
        withAnimation(Th.out(250)) { app.playerOpen = false }
        app.playerClosed()
    }
    func onError(_ m: String) {
        loading = false; loadTask?.cancel()
        app.toast(t("playErr") + ": " + m, 6000)
        spin = false; showOsd()
    }
    func onEnded() { if index + 1 < items.count { playIndex(index + 1) } else { close() } }

    // MARK: progress reporting (observer)
    func report() {
        guard player.currentItem != nil, Session.shared.isLoggedIn, items.indices.contains(index) else { return }
        let item = items[index], info = item["info"], u = Session.shared.user
        let params: [String: String] = [
            "post_id": info["post_id"].string ?? post.postId, "file_id": info["file_id"].str,
            "user_id": u["user_id"].string ?? u["id"].str, "time": String(Int(curTime())), "duration": String(Int(duration)),
            "token": item["options"]["token"].str
        ]
        Task { _ = try? await API.shared.call("observer", params) }
    }
    func reportNow() { if player.currentItem != nil && curTime() > 1 { report() } }
    private func curTime() -> Double { let s = player.currentTime().seconds; return s.isFinite ? s : 0 }

    // MARK: url pick
    /// m3u8 may be a string, or an array of quality entries {label, default|file|…}; always prefer the highest fixed quality, Auto only as fallback.
    static func entryUrl(_ e: JSON) -> String? {
        switch e {
        case .string(let s): return s
        case .array(let a): return a.first.flatMap(entryUrl)
        case .object: for k in ["default", "file", "url", "src", "link", "m3u8", "path", "source"] where e[k].truthy { return entryUrl(e[k]) }; return nil
        default: return nil
        }
    }
    static func pickUrl(_ m: JSON) -> String? {
        guard case .array(let a) = m else { return entryUrl(m) }
        var best: String?, bestH = -1, auto: String?
        for e in a {
            guard let u = entryUrl(e) else { continue }
            let label = e["label"].str
            if label.range(of: "^(auto|خودکار)$", options: [.regularExpression, .caseInsensitive]) != nil { auto = u; continue }
            let h = Int(label.filter(\.isNumber)) ?? 0
            if h > bestH { best = u; bestH = h }
        }
        return best ?? auto
    }

    // MARK: subtitles
    private func subUrl(_ v: JSON) -> String? {
        switch v {
        case .string(let s): return s.isEmpty ? nil : s
        case .array(let a): return a.first.flatMap(subUrl)
        case .object: for k in ["url", "file", "src", "link", "vtt"] where v[k].truthy { return v[k].string }; return nil
        default: return nil
        }
    }
    func availableSubs(_ item: JSON) -> [String] {
        let s = item["file"]["subtitle"]
        return ["en", "fa"].filter { subUrl(s[$0]) != nil }
    }
    static func ts(_ s: String) -> Double? {
        let p = s.trimmingCharacters(in: .whitespaces)
        guard let r = try? NSRegularExpression(pattern: "^(?:(\\d+):)?(\\d+):(\\d+)[.,](\\d+)$"),
              let m = r.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) else { return nil }
        func g(_ i: Int) -> String { Range(m.range(at: i), in: p).map { String(p[$0]) } ?? "" }
        return (Double(g(1)) ?? 0) * 3600 + (Double(g(2)) ?? 0) * 60 + (Double(g(3)) ?? 0) + (Double("0." + g(4)) ?? 0)
    }
    static func parseVTT(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        var txt = text.replacingOccurrences(of: "\r", with: "")
        if txt.hasPrefix("\u{FEFF}") { txt.removeFirst() }
        for b in txt.replacingOccurrences(of: "\n\n+", with: "\u{0}", options: .regularExpression).components(separatedBy: "\u{0}") {
            let lines = b.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count > 1, let s = ts(parts[0]), let e = ts(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)[0]) else { continue }
            var tt = lines[(i + 1)...].joined(separator: "\n")
            tt = tt.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "\\{\\\\an?\\d\\}", with: "", options: .regularExpression)
            cues.append(Cue(s: s, e: e, t: tt))
        }
        return cues.sorted { $0.s < $1.s }
    }
    func setSub(_ lang: String) {
        subLang = lang; cues = []; subText = ""
        guard lang != "off", items.indices.contains(index), let u = subUrl(items[index]["file"]["subtitle"][lang]) else { return }
        if let c = subCache[u] { cues = c; return }
        Task {
            guard let url = URL(string: u), let (d, _) = try? await API.shared.session.data(from: url) else { app.toast(t("subFailed")); return }
            let s = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
            let c = PlayerController.parseVTT(s)
            subCache[u] = c
            if subLang == lang { cues = c }
        }
    }
    private func renderSub(_ t: Double) {
        var txt = ""
        if !cues.isEmpty {
            var lo = 0, hi = cues.count - 1, idx = -1
            while lo <= hi { let mid = (lo + hi) >> 1; if cues[mid].s <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 } }
            var j = idx
            while j >= 0 && j > idx - 4 { if cues[j].e > t { txt = cues[j].t; break }; j -= 1 }
        }
        if subText != txt { subText = txt }
    }

    // MARK: audio
    private func loadAudio(_ pi: AVPlayerItem) {
        Task {
            guard let g = try? await pi.asset.loadMediaSelectionGroup(for: .audible), player.currentItem === pi else { return }
            audioGroup = g
            refreshAudio()
        }
    }
    private func refreshAudio() {
        guard let g = audioGroup, let pi = player.currentItem else { audio = []; return }
        let sel = pi.currentMediaSelection.selectedMediaOption(in: g)
        audio = g.options.enumerated().map { i, o in
            let lang = o.extendedLanguageTag ?? o.locale?.identifier ?? ""
            return (i, PlayerController.langName(lang).isEmpty ? (o.displayName.isEmpty ? "Track \(i + 1)" : o.displayName) : PlayerController.langName(lang), o == sel)
        }
    }
    func setAudio(_ id: Int) {
        guard let g = audioGroup, g.options.indices.contains(id) else { return }
        player.currentItem?.select(g.options[id], in: g)
        refreshAudio()
    }
    static let LANGS = ["eng": "English", "en": "English", "per": "Persian", "fas": "Persian", "fa": "Persian", "fre": "French", "fra": "French", "ger": "German", "deu": "German", "spa": "Spanish", "jpn": "Japanese", "ja": "Japanese", "kor": "Korean", "tur": "Turkish", "ara": "Arabic", "rus": "Russian"]
    static func langName(_ l: String) -> String {
        if l.isEmpty { return "" }
        let s = l.lowercased()
        return LANGS[s] ?? LANGS[String(s.prefix(3))] ?? LANGS[String(s.prefix(2))] ?? l
    }

    // MARK: tick
    private func tn(_ v: JSON) -> Double {
        if case .string(let s) = v, s.contains(":") { return s.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) } }
        return v.num
    }
    func tick() {
        guard let pi = player.currentItem else { return }
        let t0 = curTime()
        if duration <= 0, pi.duration.seconds.isFinite { duration = pi.duration.seconds }
        renderSub(t0)
        time = t0
        if let r = pi.loadedTimeRanges.map({ $0.timeRangeValue }).first(where: { $0.start.seconds <= t0 + 0.5 && $0.end.seconds >= t0 }) { buffered = r.end.seconds } else { buffered = 0 }
        let o = items.indices.contains(index) ? items[index]["options"] : .null
        let isS = tn(o["intro_end"]) > 0 && t0 >= tn(o["intro_start"]) && t0 < tn(o["intro_end"]) - 1
        let isP = !isS && tn(o["previously_end"]) > 0 && t0 >= tn(o["previously_start"]) && t0 < tn(o["previously_end"]) - 1
        let show: (String, Double)? = isS ? (I18n.t("skipIntro"), tn(o["intro_end"])) : (isP ? (I18n.t("skipRecap"), tn(o["previously_end"])) : nil)
        if show?.0 != skip?.label || show?.1 != skip?.to { withAnimation(Th.emph(320)) { skip = show.map { (label: $0.0, to: $0.1) } } }
        // up next at credits
        let hasNext = index + 1 < items.count, end = tn(o["end"])
        if hasNext && end > 0 && t0 >= end && upNext == nil { showUpNext() }
        else if let u = upNext, end > 0, t0 < end - 3, !u.dismissed { hideUpNext(force: true) }
    }
    var shownTime: Double { seekAcc != 0 && duration > 0 ? max(0, min(duration, time + seekAcc)) : time }

    // MARK: OSD
    func showOsd() {
        withAnimation(Th.out(250)) { osd = true }
        osdTask?.cancel()
        osdTask = Task {
            await Task.sleep(ms: 4000)
            if Task.isCancelled { return }
            if !paused && !menuOpen && !epsOpen { withAnimation(Th.out(250)) { osd = false } }
        }
    }
    func pulseGlyph(_ kind: String) {
        glyphTask?.cancel()
        glyph = kind; glyphHold = false; glyphPulse += 1
        if kind == "pause" { glyphTask = Task { await Task.sleep(ms: 600); if !Task.isCancelled { self.glyphHold = true } } }
    }
    func togglePause() {
        guard player.currentItem != nil else { return }
        paused.toggle()
        if paused { player.pause() } else { player.play() }
        pulseGlyph(paused ? "pause" : "play")
        showOsd()
    }
    func seekBy(_ sec: Double) {
        guard player.currentItem != nil else { return }
        seekAcc += sec
        seekTask?.cancel()
        showOsd(); tick()
        seekTask = Task {
            await Task.sleep(ms: 700)
            if Task.isCancelled { return }
            var target = curTime() + seekAcc
            seekAcc = 0
            if duration > 0 { target = min(target, duration - 2) }
            player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600), completionHandler: { _ in })
        }
    }

    // MARK: up next
    func showUpNext() {
        guard index + 1 < items.count else { return }
        let auto = Store.bool("autoplay", true)
        withAnimation(Th.emph(420)) { upNext = UpNext(sel: "play", dismissed: false, auto: auto, hold: false, shown: true, progress: 0, started: Date()) }
        if auto { runCountdown(from: 0) }
    }
    private func runCountdown(from p: Double) {
        upTask?.cancel()
        let remain = 10 * (1 - p)
        withAnimation(.linear(duration: remain)) { upNext?.progress = 1 }
        upTask = Task {
            await Task.sleep(ms: Int(remain * 1000))
            if Task.isCancelled { return }
            if let u = upNext, u.auto, !u.hold { hideUpNext(force: true); playIndex(index + 1) }
        }
    }
    /// Any key other than OK/Back pauses the countdown; the bar holds.
    func holdUpNext() {
        guard var u = upNext, u.shown, u.auto, !u.hold else { return }
        upTask?.cancel()
        let elapsed = Date().timeIntervalSince(u.started) / 10
        u.hold = true; u.progress = min(1, elapsed)
        var tr = Transaction(); tr.disablesAnimations = true
        withTransaction(tr) { upNext = u }
    }
    func hideUpNext(force: Bool) {
        upTask?.cancel()
        if force { withAnimation(Th.emph(420)) { upNext = nil } }
        else if upNext != nil { withAnimation(Th.emph(420)) { upNext?.dismissed = true; upNext?.shown = false } }
    }

    // MARK: sheets
    func openMenu() {
        refreshAudio()
        withAnimation(Th.emph(420)) { menuOpen = true; osd = true }
    }
    func closeMenu(silent: Bool = false) {
        guard menuOpen else { return }
        withAnimation(Th.out(240)) { menuOpen = false }
        if !silent { showOsd() }
    }
    func openEps() {
        guard items.count > 1 else { return }
        withAnimation(Th.emph(420)) { epsOpen = true; osd = true }
    }
    func closeEps(silent: Bool = false) {
        guard epsOpen else { return }
        withAnimation(Th.out(240)) { epsOpen = false }
        if !silent { showOsd() }
    }

    // MARK: remote
    func handleBack() {
        if menuOpen { closeMenu(); return }
        if epsOpen { closeEps(); return }
        close()
    }
    func handleSelect() {
        showOsd()
        if let u = upNext, u.shown {
            let sel = u.sel
            hideUpNext(force: sel != "cred")
            if sel == "play" { playIndex(index + 1) }
            return
        }
        if let s = skip { player.seek(to: CMTime(seconds: s.to, preferredTimescale: 600)); return }
        togglePause()
    }
    func handlePlayPause() { showOsd(); togglePause() }
    func handleMove(_ d: MoveCommandDirection) {
        showOsd()
        if let u = upNext, u.shown {
            holdUpNext()
            if d == .left || d == .right { upNext?.sel = u.sel == "play" ? "cred" : "play"; return }
        }
        switch d {
        case .left: seekBy(-10)
        case .right: seekBy(10)
        case .up: openMenu()
        case .down: if items.count > 1 { openEps() }
        default: break
        }
    }
}
