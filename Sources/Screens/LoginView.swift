import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR login (DESIGN §9.2).
struct LoginView: View {
    let entryId: UUID
    let active: Bool
    @EnvironmentObject var app: AppState
    @State private var code = ""
    @State private var qr: UIImage?
    @State private var dim = false
    @State private var done = false
    @State private var expText = t("expired")
    @State private var statusOn = true
    @State private var gen = 0
    @State private var pulse = false
    @FocusState private var focus: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // start column
            VStack(alignment: .leading, spacing: 0) {
                Text(t("signIn")).font(.vz(Th.tCap, .medium)).foregroundStyle(Th.text3)
                Text(t("scanTitle")).font(.vz(Th.tXL, .bold)).padding(.top, 8)
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(["step1", "step2", "step3"].enumerated()), id: \.offset) { i, k in
                        HStack(spacing: 20) {
                            Text("\(i + 1)").font(.vz(22, .bold)).foregroundStyle(Color(hex: 0x1a1205))
                                .frame(width: 40, height: 40).background(Circle().fill(Th.accent))
                            Text(t(k)).font(.vz(Th.tBodyL)).foregroundStyle(Th.text2)
                        }
                    }
                }
                .padding(.top, 40)
                VStack(alignment: .leading, spacing: 8) {
                    altLine.font(.vz(Th.tBodyL)).foregroundStyle(Th.text2)
                    Text(code).font(.vz(48, .bold, latin: true).monospacedDigit()).tracking(48 * 0.12)
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(height: 64)
                }
                .padding(.top, 40)
                HStack(spacing: 16) {
                    TVButton(title: t("guest"), kind: .primary) { app.go(.home, reset: true) }.focused($focus, equals: 0)
                    TVButton(title: t("refresh")) { begin() }.focused($focus, equals: 1)
                }
                .padding(.top, 48)
            }
            .frame(width: 760, alignment: .leading)
            .frame(maxHeight: .infinity)
            .padding(.leading, Th.start)

            // end column: QR tile + status
            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: Th.rSheet).fill(Color.white)
                    if let qr {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 404, height: 404).opacity(dim ? 0.3 : 1)
                            .animation(Th.out(260), value: dim)
                    }
                    if dim { Text(expText).font(.vz(Th.tL, .bold)).foregroundStyle(Color(hex: 0x14161c)) }
                    ZStack {
                        RoundedRectangle(cornerRadius: Th.rSheet).fill(Color.white)
                        Icon.check.image.font(.system(size: 200, weight: .light)).foregroundStyle(Th.accent)
                    }
                    .opacity(done ? 1 : 0).scaleEffect(done ? 1 : 0.9)
                    .animation(Th.out(260), value: done)
                }
                .frame(width: 460, height: 460)
                HStack(spacing: 12) {
                    Circle().fill(Th.accent).frame(width: 12, height: 12).opacity(pulse ? 1 : 0.3)
                    Text(t("waiting")).font(.vz(Th.tCap)).foregroundStyle(Th.text2)
                }
                .opacity(statusOn ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 96)
            .padding(.top, 50)
        }
        .frame(width: 1920, height: 1080)
        .onAppear {
            app.stage.dim(0.55)
            focus = 0
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            Task {
                // backdrop: first hero cover (guest payload)
                if let h = try? await app.getHome(), let p = h["hero_header"]["posts"].array.first(where: { !$0.coverUrl.isEmpty }) {
                    app.stage.show(p, immediate: true) { _ in app.splashReady() }
                } else { app.splashReady() }
            }
            begin()
        }
        .onDisappear { gen += 1 }
    }

    private var altLine: Text {
        let parts = t("orVisit").components(separatedBy: "30nama.com/auth")
        return Text(parts[0]) + Text("30nama.com/auth").font(.vz(Th.tBodyL, .bold, latin: true)).foregroundColor(Th.text1) + Text(parts.count > 1 ? parts[1] : "")
    }

    private func makeQR(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let o = f.outputImage, let cg = CIContext().createCGImage(o, from: o.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func begin() {
        gen += 1
        let my = gen
        dim = false; done = false; qr = nil; code = ""; statusOn = true; expText = t("expired")
        Task {
            do {
                let r = try await API.shared.get("qrlogin_code")
                guard my == gen else { return }
                code = r["code"].str
                let link = r["url"].string ?? (Config.qrBase + code)
                qr = makeQR(link)
                let start = nowMs()
                while my == gen {
                    await Task.sleep(ms: Config.qrPollMs)
                    guard my == gen else { return }
                    if nowMs() - start > Double(Config.qrTimeoutMs) { // expired
                        dim = true; statusOn = false; focus = 1; return
                    }
                    guard let j = try? await API.shared.call("qrlogin_login", ["auth_code": code]), my == gen, j["success"].truthy else { continue } // CODE_NOT_USED -> keep polling
                    let res = j["result"]
                    let u: JSON = res["user_session"].truthy ? res : (res["user"]["user_session"].truthy ? res["user"] : .null)
                    let token = u.truthy ? u["user_session"].str : (res["token"].string ?? res["user_session"].str)
                    if token.isEmpty { continue }
                    gen += 1
                    Session.shared.set(user: u.truthy ? u : .object(["user_session": .string(token)]))
                    // qrlogin_login returns only {token}; fetch the profile with it
                    if let uj = try? await API.shared.call("user"), uj["success"].truthy {
                        let rr = uj["result"]
                        var full = rr["user_session"].truthy ? rr : (rr["user"].truthy ? rr["user"] : rr)
                        if full.truthy {
                            if !full["user_session"].truthy { full["user_session"] = .string(token) }
                            Session.shared.set(user: full)
                        }
                    }
                    done = true; statusOn = false; app.dropHome()
                    app.toast(t("welcome") + " " + Session.shared.user["user_name"].str)
                    await Task.sleep(ms: 400)
                    app.go(.home, reset: true)
                    return
                }
            } catch {
                guard my == gen else { return }
                dim = true; expText = t("error"); statusOn = false; focus = 1
            }
        }
    }
}
