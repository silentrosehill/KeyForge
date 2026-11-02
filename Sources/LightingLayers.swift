import Foundation

/// A sparse painted overlay. Later layers appear above earlier ones.
struct LightingLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Layer"
    var enabled = true
    var opacity = 1.0
    var brightness = 1.0
    var keyColors: [Usage: UInt32] = [:]
}

enum LightingLayers {
    private static func blend(_ base: UInt32, _ paint: UInt32, brightness: Double, opacity: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double(base >> shift & 0xFF)
            let b = (Double(paint >> shift & 0xFF) * brightness).rounded()
            return UInt32((a * (1 - opacity) + b * opacity).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func composite(_ frame: [Usage: UInt32], layers: [LightingLayer]) -> [Usage: UInt32] {
        var result = frame
        for layer in layers where layer.enabled {
            let opacity = max(0, min(1, layer.opacity))
            let brightness = max(0, min(1, layer.brightness))
            for (key, color) in layer.keyColors {
                result[key] = blend(result[key] ?? 0, color, brightness: brightness, opacity: opacity)
            }
        }
        return result
    }
}

