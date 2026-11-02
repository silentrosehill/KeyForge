import Foundation

@main
struct QuickSearchTests {
    @MainActor static func main() {
        let source = HID.key(0x04), target = HID.key(0x2C), second = HID.key(0x05)
        let keys = [KeyDef(usage: source, vk: nil, x: 0, y: 0, label: "Custom Key"),
                    KeyDef(usage: second, vk: nil, x: 1, y: 0),
                    KeyDef(usage: HID.fn, vk: nil, x: 2, y: 0, fixed: true)]
        var profile = Profile(name: "Test")
        profile.map[source] = target
        profile.actions[second] = .text("hello world")
        func find(_ text: String) -> [Usage] {
            QuickSearchIndex.results(query: text, keys: keys, profile: profile, iso: false).map(\.usage)
        }
        precondition(find("custom") == [source])
        precondition(find("space") == [source])
        precondition(find("hello") == [second])
        precondition(find("type text") == [second])
        precondition(find("fn").isEmpty)
        precondition(find("  ").isEmpty)
        precondition(find("custom hello").isEmpty)
        print("Quick search tests passed")
    }
}
