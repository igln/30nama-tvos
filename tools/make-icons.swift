// Renders the tvOS brand assets (layered app icon + top shelf) into Resources/Assets.xcassets.
// Usage: swift tools/make-icons.swift   (run from the 30nama-tvos directory; macOS only)
import AppKit
import CoreText

let root = FileManager.default.currentDirectoryPath
for f in ["Vazirmatn-ExtraBold"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "\(root)/Resources/Fonts/\(f).woff2") as CFURL, .process, nil)
}
let bg0 = NSColor(srgbRed: 0x07/255, green: 0x08/255, blue: 0x0b/255, alpha: 1)
let bg1 = NSColor(srgbRed: 0x0e/255, green: 0x10/255, blue: 0x16/255, alpha: 1)
let accent = NSColor(srgbRed: 0xF0/255, green: 0x45/255, blue: 0x4A/255, alpha: 1)
let text1 = NSColor(srgbRed: 0xf4/255, green: 0xf1/255, blue: 0xea/255, alpha: 1)

func png(_ w: Int, _ h: Int, _ path: String, opaque: Bool, _ draw: (CGContext, CGFloat, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    draw(c, CGFloat(w), CGFloat(h))
    NSGraphicsContext.restoreGraphicsState()
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
func back(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let g = CGGradient(colorsSpace: nil, colors: [bg1.cgColor, bg0.cgColor] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    let r = min(w, h) * 0.9
    let bloom = CGGradient(colorsSpace: nil, colors: [accent.withAlphaComponent(0.42).cgColor, accent.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(bloom, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: r, options: [])
}
func wordmark(_ c: CGContext, _ w: CGFloat, _ h: CGFloat, size: CGFloat, cx: CGFloat? = nil) {
    let font = NSFont(name: "Vazirmatn-ExtraBold", size: size) ?? .boldSystemFont(ofSize: size)
    let s = NSMutableAttributedString(string: "30", attributes: [.font: font, .foregroundColor: accent])
    s.append(NSAttributedString(string: "nama", attributes: [.font: font, .foregroundColor: text1]))
    let b = s.size()
    let x = (cx ?? w / 2) - b.width / 2, y = h / 2 - b.height / 2
    s.draw(at: CGPoint(x: x, y: y))
    c.setFillColor(accent.cgColor)
    c.fill(CGRect(x: (cx ?? w / 2) - size, y: y + size * 0.12, width: size * 2, height: max(2, size * 0.02)))
}

let A = "\(root)/Resources/Assets.xcassets"
let B = "\(A)/App Icon & Top Shelf Image.brandassets"
func json(_ path: String, _ s: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try! s.write(toFile: path + "/Contents.json", atomically: true, encoding: .utf8)
}
let info = "\"info\" : { \"author\" : \"xcode\", \"version\" : 1 }"
json(A, "{ \(info) }")
json("\(A)/LaunchBackground.colorset", """
{ "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0x0B", "green" : "0x08", "red" : "0x07" } }, "idiom" : "universal" } ], \(info) }
""")
json(B, """
{ "assets" : [
  { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
  { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
  { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" },
  { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" }
], \(info) }
""")
func stack(_ name: String, _ w: Int, _ h: Int, scales: [Int], idiom: String) {
    let S = "\(B)/\(name).imagestack"
    json(S, "{ \(info), \"layers\" : [ { \"filename\" : \"Front.imagestacklayer\" }, { \"filename\" : \"Back.imagestacklayer\" } ] }")
    for layer in ["Front", "Back"] {
        let L = "\(S)/\(layer).imagestacklayer"
        json(L, "{ \(info) }")
        var imgs: [String] = []
        for sc in scales {
            let fn = "\(layer.lowercased())\(sc > 1 ? "@\(sc)x" : "").png"
            png(w * sc, h * sc, "\(L)/Content.imageset/\(fn)", opaque: layer == "Back") { c, W, H in
                if layer == "Back" { back(c, W, H) } else { wordmark(c, W, H, size: H * 0.3) }
            }
            imgs.append("{ \"filename\" : \"\(fn)\", \"idiom\" : \"\(idiom)\", \"scale\" : \"\(sc)x\" }")
        }
        json("\(L)/Content.imageset", "{ \"images\" : [ \(imgs.joined(separator: ", ")) ], \(info) }")
    }
}
stack("App Icon", 400, 240, scales: [1, 2], idiom: "tv")
stack("App Icon - App Store", 1280, 768, scales: [1], idiom: "tv-marketing")
func shelf(_ name: String, _ w: Int, _ h: Int) {
    let S = "\(B)/\(name).imageset"
    var imgs: [String] = []
    for sc in [1, 2] {
        let fn = "shelf\(sc > 1 ? "@\(sc)x" : "").png"
        png(w * sc, h * sc, "\(S)/\(fn)", opaque: true) { c, W, H in back(c, W, H); wordmark(c, W, H, size: H * 0.26) }
        imgs.append("{ \"filename\" : \"\(fn)\", \"idiom\" : \"tv\", \"scale\" : \"\(sc)x\" }")
    }
    json(S, "{ \"images\" : [ \(imgs.joined(separator: ", ")) ], \(info) }")
}
shelf("Top Shelf Image", 1920, 720)
shelf("Top Shelf Image Wide", 2320, 720)
print("assets written to \(A)")
