// Fits Codex's artwork (a rounded slab on a transparent or white background) to Apple's icon grid (824×824 rounded
// square, radius 185, at 100,100 on 1024) so macOS 26 doesn't put it on a white plate. The slab is
// found by its dark edge, cropped a little inside it so no white corner or fringe survives, and
// backed with solid black so it is fully opaque. Usage: swift fit_icon.swift original.png out_1024.png
import AppKit

let args = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let w = src.pixelsWide, h = src.pixelsHigh
func dark(_ x: Int, _ y: Int) -> Bool {
    guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { return false }
    return 0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent < 0.5
}
// the slab's edges along the middle row and column (its soft shadow stays lighter than the threshold)
let minX = (0..<w).first { dark($0, h / 2) }!, maxX = (0..<w).reversed().first { dark($0, h / 2) }!
let minY = (0..<h).first { dark(w / 2, $0) }!, maxY = (0..<h).reversed().first { dark(w / 2, $0) }!
let inset = CGFloat(maxX - minX) * 0.02
let crop = CGRect(x: CGFloat(minX) + inset, y: CGFloat(minY) + inset,
                  width: CGFloat(maxX - minX) - 2 * inset, height: CGFloat(maxY - minY) - 2 * inset)
print("slab \(minX),\(minY)–\(maxX),\(maxY), crop \(crop)")
let piece = src.cgImage!.cropping(to: crop.integral)!

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let target = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: target, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.04, blue: 0.08, alpha: 1))
ctx.fill(target)
ctx.draw(piece, in: target)
let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
