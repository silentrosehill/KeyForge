import CoreVideo

/// A small, top-to-bottom RGB grid. No image or recording is kept on disk.
enum ScreenColorGrid {
    static let columns = 22, rows = 6
    static let black = [UInt32](repeating: 0, count: columns * rows)

    static func sample(_ buffer: CVPixelBuffer, ignoreBlackBars: Bool = false, uniform: Bool = false) -> [UInt32]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= columns, height >= rows, let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // Only trim completely near-black edge lines. A dark image with any visible
        // color stays intact, and an all-black frame remains black.
        var left = 0, right = width, top = 0, bottom = height
        func blackPixel(_ x: Int, _ y: Int) -> Bool {
            let p = pixels + y * stride + x * 4
            return p[0] <= 2 && p[1] <= 2 && p[2] <= 2
        }
        if ignoreBlackBars {
            while top < bottom && (0..<width).allSatisfy({ blackPixel($0, top) }) { top += 1 }
            while bottom > top && (0..<width).allSatisfy({ blackPixel($0, bottom - 1) }) { bottom -= 1 }
            if top < bottom {
                while left < right && (top..<bottom).allSatisfy({ blackPixel(left, $0) }) { left += 1 }
                while right > left && (top..<bottom).allSatisfy({ blackPixel(right - 1, $0) }) { right -= 1 }
            }
            if top == bottom || left == right { return black }
        }
        var contentWidth = right - left, contentHeight = bottom - top
        // A very small nonblack region cannot fill the grid; retain the full frame.
        if contentWidth < columns || contentHeight < rows {
            left = 0; right = width; top = 0; bottom = height
            contentWidth = width; contentHeight = height
        }
        var result = black
        var totalRed = 0, totalGreen = 0, totalBlue = 0
        for row in 0..<rows {
            let y0 = top + row * contentHeight / rows, y1 = top + (row + 1) * contentHeight / rows
            for col in 0..<columns {
                let x0 = left + col * contentWidth / columns, x1 = left + (col + 1) * contentWidth / columns
                var red = 0, green = 0, blue = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let p = pixels + y * stride + x * 4
                        blue += Int(p[0]); green += Int(p[1]); red += Int(p[2])
                    }
                }
                totalRed += red; totalGreen += green; totalBlue += blue
                let count = (x1 - x0) * (y1 - y0)
                result[row * columns + col] = UInt32(red / count) << 16 | UInt32(green / count) << 8 | UInt32(blue / count)
            }
        }
        if uniform {
            let count = contentWidth * contentHeight
            let color = UInt32(totalRed / count) << 16 | UInt32(totalGreen / count) << 8 | UInt32(totalBlue / count)
            return [UInt32](repeating: color, count: columns * rows)
        }
        return result
    }

    static func zones(_ colors: [UInt32]) -> [UInt32] {
        guard colors.count == columns * rows else { return [0, 0, 0] }
        return (0..<3).map { zone in
            let columnsInZone = (zone * columns / 3)..<((zone + 1) * columns / 3)
            var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0
            for row in 0..<rows {
                for col in columnsInZone {
                    let color = colors[row * columns + col]
                    red += color >> 16 & 255; green += color >> 8 & 255; blue += color & 255
                }
            }
            let count = UInt32(columnsInZone.count * rows)
            return (red / count) << 16 | (green / count) << 8 | blue / count
        }
    }

    static func smooth(_ current: [UInt32], previous: [UInt32], speed: Double = 0.55) -> [UInt32] {
        guard previous.count == current.count else { return current }
        let amount = max(0, min(1, speed))
        return zip(previous, current).map { old, new in
            var color: UInt32 = 0
            for shift in [16, 8, 0] {
                let a = Double((old >> shift) & 255), b = Double((new >> shift) & 255)
                let value = amount == 0 ? a : (abs(a - b) <= 2 ? b : a + (b - a) * amount)
                color |= UInt32(value.rounded()) << shift
            }
            return color
        }
    }
}

