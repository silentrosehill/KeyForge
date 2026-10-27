import AppKit

// Legacy ICNS artwork needs the fitted canvas. The generated original is kept
// separately; shipping it directly makes macOS place the icon on a white plate.
func fail(_ reason: String) -> Never {
    fputs("Icon validation failed: \(reason)\n", stderr)
    exit(1)
}
let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon"
let png = try Data(contentsOf: URL(fileURLWithPath: "\(folder)/icon_1024.png"))
guard let image = NSBitmapImageRep(data: png), image.pixelsWide == 1024,
      image.pixelsHigh == 1024, image.hasAlpha else {
    fail("expected a transparent 1024px PNG")
}
var left = 1024, top = 1024, right = -1, bottom = -1
for y in 0..<1024 {
    for x in 0..<1024 where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.99 {
        left = min(left, x); top = min(top, y)
        right = max(right, x); bottom = max(bottom, y)
    }
}
guard [left, top, right, bottom] == [100, 100, 923, 923] else {
    fail("use the fitted artwork, with opaque bounds 100,100–923,923")
}
let icns = try Data(contentsOf: URL(fileURLWithPath: "\(folder)/AppIcon.icns"))
guard icns.count >= 8, String(data: icns.prefix(4), encoding: .ascii) == "icns" else {
    fail("invalid ICNS container")
}
var offset = 8, matched = false
while offset + 8 <= icns.count {
    let length = icns[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
    guard length >= 8, offset + length <= icns.count else { fail("invalid ICNS entry") }
    if String(data: icns[offset..<(offset + 4)], encoding: .ascii) == "ic10" {
        guard icns[(offset + 8)..<(offset + length)] == png else {
            fail("the packaged 1024px icon differs from the fitted PNG")
        }
        matched = true
    }
    offset += length
}
guard matched else { fail("missing the 1024px icon") }
print("Icon validated: fitted canvas and matching ICNS artwork")
