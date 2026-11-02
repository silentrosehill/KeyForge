import Foundation

typealias Usage = UInt64

@main struct LightingLayersTests {
    static func main() throws {
        let key: Usage = 4, other: Usage = 5
        var first = LightingLayer(name: "WASD")
        first.keyColors = [key: 0xFF0000]
        first.brightness = 0.5
        first.opacity = 0.5
        let base: [Usage: UInt32] = [key: 0x0000FF, other: 0x123456]
        let mixed = LightingLayers.composite(base, layers: [first])
        precondition(mixed[key] == 0x400080 && mixed[other] == 0x123456)
        var second = LightingLayer(name: "Top")
        second.keyColors = [key: 0x00FF00]
        precondition(LightingLayers.composite(base, layers: [first, second])[key] == 0x00FF00)
        second.enabled = false
        precondition(LightingLayers.composite(base, layers: [first, second]) == mixed)
        let encoded = try JSONEncoder().encode([first, second])
        let decoded = try JSONDecoder().decode([LightingLayer].self, from: encoded)
        precondition(decoded == [first, second])
        print("Lighting layer compositing and persistence passed")
    }
}
