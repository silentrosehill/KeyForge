// Renders the KeyForge icon: a clear "K" keycap on black with a pen, in the MP3 Tagger v3 style.
// Usage: swiftc make_icon.swift -o make_icon && ./make_icon out.png
import AppKit
import CoreImage

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let ci = CIContext(options: [.workingColorSpace: cs])

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { rgb(0xFFFFFF, a) }
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

let green = 0x1ED760 as UInt32, deepGreen = 0x0F7A35 as UInt32

/// Blurred snapshot of everything drawn so far (the "backdrop" glass refracts).
func backdrop(blur: Double) -> CGImage {
    let img = CIImage(cgImage: ctx.makeImage()!)
    let out = img.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: img.extent)
    return ci.createCGImage(out, from: img.extent)!
}

/// Draws a Liquid Glass slab: soft shadow, refracted + frosted backdrop, tint, specular rim.
func glass(_ path: CGPath, tint: CGColor, blur: Double = 22, refraction: CGFloat = 1.08, rim: CGFloat = 5, eo: Bool = false) {
    let rule: CGPathFillRule = eo ? .evenOdd : .winding
    let b = path.boundingBox
    let bg = backdrop(blur: blur)

    // drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: rgb(0x000000, 0.55))
    ctx.addPath(path); ctx.setFillColor(rgb(0x000000)); ctx.fillPath(using: rule)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip(using: rule)
    // refraction: backdrop slightly magnified around the slab's center
    ctx.saveGState()
    ctx.translateBy(x: b.midX, y: b.midY); ctx.scaleBy(x: refraction, y: refraction); ctx.translateBy(x: -b.midX, y: -b.midY)
    ctx.draw(bg, in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.restoreGState()
    // tint + frosting
    ctx.setFillColor(tint); ctx.fill(b)
    ctx.drawLinearGradient(gradient([white(0.24), white(0.03), white(0.0), white(0.08)], [0, 0.45, 0.7, 1]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    // inner edge glow (light caught inside the thickness of the glass)
    ctx.setShadow(offset: .zero, blur: 30, color: white(0.55))
    ctx.addRect(b.insetBy(dx: -200, dy: -200)); ctx.addPath(path)
    ctx.setFillColor(white(1)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // specular rim: bright top-left and bottom-right, fading in between
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(rim); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([white(0.95), white(0.25), white(0.05), white(0.25), white(0.75)], [0, 0.3, 0.5, 0.7, 1]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    ctx.restoreGState()
}

// MARK: Variant (2nd argument): frosted (default), purple, razer, rgb, obsidian, crystal, sunset
struct Style {
    var haze: CGFloat = 1                         // frost amount
    var tint: [(UInt32, CGFloat)] = [(0xFF6A88, 0.06), (0xB23AEE, 0.05), (0x4B1FB8, 0.08)]
    var kColor: UInt32 = 0xFFFFFF
    var kGlow: (UInt32, CGFloat) = (0xC78BFF, 0.6)
    var underglow: [UInt32] = []                  // RGB light spilling out under the keycap
    var edge: CGFloat = 0.85
    var rim: CGFloat = 1
}
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "sunset"   // the chosen icon (1.7.1)
let style: Style = {
    var s = Style()
    switch variant {
    case "purple":
        s.tint = [(0xFF6AD5, 0.16), (0xB23AEE, 0.22), (0x5A1FD8, 0.28)]
        s.kGlow = (0xD08BFF, 0.9); s.underglow = [0xB23AEE]
    case "razer":
        s.tint = [(0x44D62C, 0.05), (0x2FA81E, 0.06), (0x0E5A08, 0.10)]
        s.kColor = 0xE9FFE4; s.kGlow = (0x44D62C, 0.9); s.underglow = [0x44D62C]
    case "rgb":
        s.underglow = [0xFF2E63, 0xFF9A00, 0xFFE600, 0x2BFF88, 0x00C2FF, 0x7B2FF7, 0xFF2E97]
        s.kGlow = (0xFFFFFF, 0.5)
    case "obsidian":
        s.haze = 0.3; s.tint = [(0x000000, 0.25), (0x000000, 0.3), (0x000000, 0.35)]
        s.kGlow = (0xFFFFFF, 0.25); s.edge = 1; s.rim = 0.7
    case "crystal":
        s.haze = 0.45; s.tint = [(0x9FE8FF, 0.05), (0xFFFFFF, 0.02), (0x7FB2FF, 0.06)]
        s.kColor = 0xEAFBFF; s.kGlow = (0x6FE3FF, 0.9); s.rim = 1.5
    case "sunset":
        s.tint = [(0xFFB000, 0.14), (0xFF4F6E, 0.18), (0x7A2BD8, 0.22)]
        s.kGlow = (0xFF8A5C, 0.85); s.underglow = [0xFF9A00, 0xFF2E63, 0x9D4EDD]
    default: break
    }
    return s
}()

// MARK: Black background (same as MP3 Tagger)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.5))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x050506)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x19191C), rgb(0x0A0A0B), rgb(0x020202)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

/// Clear plastic: faint tint, violet/pink shimmer, a soft light wedge and a glassy rim.
func clearPlastic(_ path: CGPath, _ b: CGRect, fill: CGFloat, rimWidth: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient([white(fill * 1.6), white(fill), white(fill * 0.6)]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    ctx.drawLinearGradient(gradient([rgb(0xFF6A88, 0.07), rgb(0xB23AEE, 0.035), rgb(0x4B1FB8, 0.08)]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    // diagonal light reflection
    let band = CGMutablePath()
    band.move(to: CGPoint(x: b.minX + b.width * 0.08, y: b.maxY))
    band.addLine(to: CGPoint(x: b.minX + b.width * 0.36, y: b.maxY))
    band.addLine(to: CGPoint(x: b.minX - b.width * 0.1, y: b.minY + b.height * 0.2))
    band.addLine(to: CGPoint(x: b.minX - b.width * 0.3, y: b.minY + b.height * 0.2))
    band.closeSubpath()
    ctx.addPath(band); ctx.clip()
    ctx.drawLinearGradient(gradient([white(0.2), white(0.02)]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.midX, y: b.midY), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(rimWidth); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([white(0.9), white(0.25), white(0.08), white(0.3), white(0.7)], [0, 0.3, 0.5, 0.7, 1]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    ctx.restoreGState()
}

// MARK: Frosted glass keycap, seen from the front and a little above (like a photo of a real key)
let fb: CGFloat = 214                              // foot of the front face
let fe: CGFloat = 540                              // front-top edge (where the light catches)
let tb: CGFloat = 790                              // back edge of the top
let bl: CGFloat = 206, br: CGFloat = 818          // foot corners
let el: CGFloat = 272, er: CGFloat = 752          // front-top edge corners
let kl: CGFloat = 276, kr: CGFloat = 748          // back edge corners
let arc: CGFloat = -5                               // the front edge bows down a touch in the middle

func frontFace() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: bl + 30, y: fb))
    p.addLine(to: CGPoint(x: br - 30, y: fb))
    p.addQuadCurve(to: CGPoint(x: br - 4, y: fb + 26), control: CGPoint(x: br, y: fb))
    p.addLine(to: CGPoint(x: er, y: fe))
    p.addQuadCurve(to: CGPoint(x: el, y: fe), control: CGPoint(x: 512, y: fe + arc * 2))
    p.addLine(to: CGPoint(x: bl + 4, y: fb + 26))
    p.addQuadCurve(to: CGPoint(x: bl + 30, y: fb), control: CGPoint(x: bl, y: fb))
    p.closeSubpath()
    return p
}
func topFace() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: el, y: fe))
    p.addQuadCurve(to: CGPoint(x: er, y: fe), control: CGPoint(x: 512, y: fe + arc * 2))
    p.addLine(to: CGPoint(x: kr - 6, y: tb - 20))
    p.addQuadCurve(to: CGPoint(x: kr - 34, y: tb), control: CGPoint(x: kr, y: tb))
    p.addQuadCurve(to: CGPoint(x: kl + 34, y: tb), control: CGPoint(x: 512, y: tb - 22))   // back edge dips with the dish
    p.addQuadCurve(to: CGPoint(x: kl + 6, y: tb - 20), control: CGPoint(x: kl, y: tb))
    p.closeSubpath()
    return p
}
let front = frontFace(), top = topFace()
let whole = CGMutablePath(); whole.addPath(front); whole.addPath(top)

// reflection on the glossy black
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.clip(to: CGRect(x: 0, y: 100, width: S, height: fb - 100 - 6))
ctx.translateBy(x: 0, y: 2 * fb - 6); ctx.scaleBy(x: 1, y: -1)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(front); ctx.setFillColor(white(0.10)); ctx.fillPath()
ctx.setBlendMode(.destinationIn)
ctx.drawLinearGradient(gradient([rgb(0x000000, 0.6), rgb(0x000000, 0)]),
                       start: CGPoint(x: 0, y: fb), end: CGPoint(x: 0, y: fb + 130), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()

// RGB underglow: light spilling onto the black around the foot of the key
if !style.underglow.isEmpty {
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let n = style.underglow.count
    for (i, c) in style.underglow.enumerated() {
        let x = n == 1 ? 512 : bl - 40 + (br - bl + 80) * CGFloat(i) / CGFloat(n - 1)
        ctx.saveGState()
        ctx.translateBy(x: x, y: fb + 40); ctx.scaleBy(x: n == 1 ? 1.25 : 0.55, y: 0.42)
        ctx.drawRadialGradient(gradient([rgb(c, n == 1 ? 0.85 : 0.75), rgb(c, 0)]), startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: 420, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

// soft shadow under the whole cap
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 46, color: rgb(0x000000, 0.9))
ctx.addPath(whole); ctx.setFillColor(rgb(0x0A0A0C)); ctx.fillPath()
ctx.restoreGState()

/// Frosted glass: milky white haze with a violet cast and fine grain.
func frosted(_ path: CGPath, from: CGPoint, to: CGPoint, haze: [CGFloat]) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient(haze.map { white($0 * style.haze) }), start: from, end: to, options: [])
    ctx.drawLinearGradient(gradient(style.tint.map { rgb($0.0, $0.1) }),
                           start: CGPoint(x: bl, y: tb), end: CGPoint(x: br, y: fb), options: [])
    // frost grain
    var seed: UInt64 = 0x9E3779B97F4A7C15
    let b = path.boundingBox
    for _ in 0..<4200 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let x = b.minX + CGFloat(seed >> 40 & 0xFFFF) / 65535 * b.width
        let y = b.minY + CGFloat(seed >> 20 & 0xFFFF) / 65535 * b.height
        ctx.setFillColor(white(CGFloat(seed & 0xFF) / 255 * 0.07))
        ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
    }
    ctx.restoreGState()
}
// front face is in shade, the top catches the light
frosted(front, from: CGPoint(x: 512, y: fe), to: CGPoint(x: 512, y: fb), haze: [0.22, 0.13, 0.085])
frosted(top, from: CGPoint(x: 512, y: tb), to: CGPoint(x: 512, y: fe), haze: [0.36, 0.27, 0.3])

// glassy rim around the silhouette
ctx.saveGState()
let outline = CGMutablePath()
outline.move(to: CGPoint(x: bl + 30, y: fb)); outline.addLine(to: CGPoint(x: br - 30, y: fb))
outline.addQuadCurve(to: CGPoint(x: br - 4, y: fb + 26), control: CGPoint(x: br, y: fb))
outline.addLine(to: CGPoint(x: er, y: fe)); outline.addLine(to: CGPoint(x: kr - 6, y: tb - 20))
outline.addQuadCurve(to: CGPoint(x: kr - 34, y: tb), control: CGPoint(x: kr, y: tb))
outline.addQuadCurve(to: CGPoint(x: kl + 34, y: tb), control: CGPoint(x: 512, y: tb - 22))
outline.addQuadCurve(to: CGPoint(x: kl + 6, y: tb - 20), control: CGPoint(x: kl, y: tb))
outline.addLine(to: CGPoint(x: el, y: fe)); outline.addLine(to: CGPoint(x: bl + 4, y: fb + 26))
outline.addQuadCurve(to: CGPoint(x: bl + 30, y: fb), control: CGPoint(x: bl, y: fb))
outline.closeSubpath()
ctx.addPath(outline); ctx.setLineWidth(4); ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([0.75, 0.3, 0.12, 0.3, 0.55].map { white(min(1, $0 * style.rim)) }, [0, 0.3, 0.5, 0.7, 1]),
                       start: CGPoint(x: bl, y: tb), end: CGPoint(x: br, y: fb), options: [])
ctx.restoreGState()

// the bright rounded edge between top and front (like in the photo)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 10, color: white(0.6))
let edge = CGMutablePath()
edge.move(to: CGPoint(x: el + 8, y: fe + 2))
edge.addQuadCurve(to: CGPoint(x: er - 8, y: fe + 2), control: CGPoint(x: 512, y: fe + arc * 2 + 2))
ctx.addPath(edge); ctx.setStrokeColor(white(style.edge)); ctx.setLineWidth(6); ctx.setLineCap(.round); ctx.strokePath()
ctx.restoreGState()

// "K" printed on the top, foreshortened by the angle
let font = NSFont.systemFont(ofSize: 210, weight: .semibold)
let kc = style.kColor
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: CGFloat(kc >> 16 & 0xFF) / 255,
    green: CGFloat(kc >> 8 & 0xFF) / 255, blue: CGFloat(kc & 0xFF) / 255, alpha: 0.95)]
let k = NSAttributedString(string: "K", attributes: attrs)
let ks = k.size()
ctx.saveGState()
ctx.translateBy(x: 512, y: (fe + tb) / 2 + 22)
ctx.scaleBy(x: 1, y: 0.62)
ctx.setShadow(offset: .zero, blur: 18, color: rgb(style.kGlow.0, style.kGlow.1))
k.draw(at: CGPoint(x: -ks.width / 2, y: -ks.height / 2))
ctx.restoreGState()

// MARK: Glass rim on the icon body itself
ctx.saveGState()
ctx.addPath(bodyPath); ctx.setLineWidth(8); ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([white(0.35), white(0.06), white(0.02), white(0.06), white(0.2)], [0, 0.3, 0.5, 0.7, 1]),
                       start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.restoreGState()

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
