import CoreVideo

@main
struct ScreenColorGridTests {
    static func buffer(_ width: Int, _ height: Int, format: OSType = kCVPixelFormatType_32BGRA,
                       color: (Int, Int) -> UInt32) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, format, nil, &result) == kCVReturnSuccess)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = color(x, y), offset = y * stride + x * 4
                pixels[offset] = UInt8(rgb & 255)
                pixels[offset + 1] = UInt8(rgb >> 8 & 255)
                pixels[offset + 2] = UInt8(rgb >> 16 & 255)
                pixels[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func main() {
        // Distinct corners detect inverted rows, reversed channels, and left/right flips.
        let quadrants = buffer(88, 24) { x, y in
            if y < 12 { return x < 44 ? 0xFF0000 : 0x00FF00 }
            return x < 44 ? 0x0000FF : 0xFFFFFF
        }
        let grid = ScreenColorGrid.sample(quadrants)!
        precondition(grid.count == 132)
        precondition(grid[0] == 0xFF0000 && grid[21] == 0x00FF00)
        precondition(grid[110] == 0x0000FF && grid[131] == 0xFFFFFF)
        // Uneven dimensions also exercise row padding and complete coverage at the far edge.
        let uniform = ScreenColorGrid.sample(buffer(91, 29) { _, _ in 0x1234AB })!
        precondition(Set(uniform) == [0x1234AB])
        let average = ScreenColorGrid.sample(buffer(44, 12) { x, _ in x % 2 == 0 ? 0xFF0000 : 0x0000FF })!
        precondition(Set(average) == [0x7F007F])
        precondition(ScreenColorGrid.sample(buffer(10, 4) { _, _ in 0 }) == nil)
        precondition(ScreenColorGrid.sample(buffer(44, 12, format: kCVPixelFormatType_32ARGB) { _, _ in 0 }) == nil)
        let weighted = ScreenColorGrid.sample(buffer(91, 29) { x, _ in x < 45 ? 0xFF0000 : 0x0000FF }, uniform: true)!
        precondition(Set(weighted) == [0x7E0080])
        let letterbox = buffer(88, 24) { _, y in y < 4 || y >= 20 ? 0 : 0x336699 }
        precondition(Set(ScreenColorGrid.sample(letterbox, ignoreBlackBars: true)!) == [0x336699])
        let dark = buffer(88, 24) { _, y in y < 4 ? 0x030303 : 0x336699 }
        precondition(ScreenColorGrid.sample(dark, ignoreBlackBars: true)![0] == 0x030303)
        precondition(ScreenColorGrid.sample(buffer(88, 24) { _, _ in 0 }, ignoreBlackBars: true)! == ScreenColorGrid.black)
        precondition(ScreenColorGrid.smooth([0xFFFFFF], previous: [0], speed: 0) == [0])
        precondition(ScreenColorGrid.smooth([0xFFFFFF], previous: [0], speed: 1) == [0xFFFFFF])
        let bands = (0..<132).map { index -> UInt32 in
            let col = index % 22
            return col < 7 ? 0xFF0000 : (col < 14 ? 0x00FF00 : 0x0000FF)
        }
        precondition(ScreenColorGrid.zones(bands) == [0xFF0000, 0x00FF00, 0x0000FF])
        precondition(ScreenColorGrid.zones([]) == [0, 0, 0])
        var fade = ScreenColorGrid.smooth([0xFFFFFF], previous: [0])
        precondition(fade[0] > 0 && fade[0] < 0xFFFFFF)
        for _ in 0..<12 { fade = ScreenColorGrid.smooth([0xFFFFFF], previous: fade) }
        precondition(fade == [0xFFFFFF])
        precondition(ScreenColorGrid.smooth([0x112233], previous: []) == [0x112233])
        print("Screen color tests passed: spatial orientation, RGB channels, averaging, stride, validation, mouse zones, smoothing")
    }
}
