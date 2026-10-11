import SwiftUI
import CoreText

/// Design tokens from design/DESIGN.md §3 (1 pt = 1 px at 1080p).
enum Th {
    static let bg0 = Color(hex: 0x07080b)
    static let bg1 = Color(hex: 0x0e1016)
    static let surface = Color(hex: 0x161922)
    static let surface2 = Color(hex: 0x20242f)
    static let line = Color.white.opacity(0.08)
    static let text1 = Color(hex: 0xf4f1ea)
    static let text2 = Color(hex: 0xf4f1ea).opacity(0.72)
    static let text3 = Color(hex: 0xf4f1ea).opacity(0.46)
    static let accent = Color(hex: 0xF0454A)
    static let accent2 = Color(hex: 0xC8323A)
    static let focus = Color.white
    static let focusInk = Color(hex: 0x0b0c10)
    static let good = Color(hex: 0x62d39b)
    static let danger = Color(hex: 0xff6b5e)

    static let tDisplay: CGFloat = 72, tXL: CGFloat = 56, tL: CGFloat = 40, tM: CGFloat = 32, tBodyL: CGFloat = 28, tBody: CGFloat = 26, tCap: CGFloat = 22

    static let safeX: CGFloat = 96, safeY: CGFloat = 54
    static let start: CGFloat = 184
    static let rCard: CGFloat = 12, rTile: CGFloat = 16, rSheet: CGFloat = 24, rBtn: CGFloat = 14

    static let eOut = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)
    static func out(_ ms: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: ms / 1000) }
    static func emph(_ ms: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: ms / 1000) }
    static func io(_ ms: Double) -> Animation { .timingCurve(0.65, 0, 0.35, 1, duration: ms / 1000) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

/// Vazirmatn (bundled WOFF2, registered at launch). Farsi-digit variant when the UI language is fa.
enum Fonts {
    static func register() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: "Fonts") ?? [])
        for u in urls { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
    }
    static func name(_ w: Font.Weight, fd: Bool) -> String {
        let base = fd ? "Vazirmatn-FD-" : "Vazirmatn-"
        switch w {
        case .regular, .light, .thin, .ultraLight: return base + "Regular"
        case .medium: return base + "Medium"
        case .semibold, .bold: return base + "Bold"
        default: return base + "ExtraBold"
        }
    }
}

extension Font {
    /// `Vz` / `VzFD` at a fixed size.
    static func vz(_ size: CGFloat, _ w: Font.Weight = .regular, latin: Bool = false) -> Font {
        .custom(Fonts.name(w, fd: I18n.lang == "fa" && !latin), fixedSize: size)
    }
}
