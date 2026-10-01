import Foundation
import Carbon
import AppKit

/// A HID usage as hidutil wants it: page << 32 | usage (keyboard page 0x07, consumer page 0x0C).
typealias Usage = UInt64

enum HID {
    static func key(_ u: UInt64) -> Usage { 0x7_0000_0000 | u }
    static func consumer(_ u: UInt64) -> Usage { 0xC_0000_0000 | u }
    /// Apple's Fn / Globe key (vendor top-case page).
    static let fn: Usage = 0xFF_0000_0003
    /// Mapping a key here makes it do nothing.
    static let none: Usage = 0x7_0000_0000

    static func isConsumer(_ u: Usage) -> Bool { u >> 32 == 0x0C }
}

/// One physical key drawn on the keyboard.
struct KeyDef: Identifiable {
    enum Shape { case normal, isoEnter, round }
    let usage: Usage
    /// macOS virtual key code (for the layout-aware legend and the live "press a key" highlight).
    let vk: Int?
    /// Position and size in key units (1 unit = one letter key).
    let x: Double, y: Double
    var w: Double = 1, h: Double = 1
    var shape: Shape = .normal
    /// Keys handled by the keyboard's own firmware (Fn) can't be remapped.
    var fixed = false
    /// Printed legend when it differs from the layout's (Mac keyboards: "⌘ command", "fn", "Touch ID").
    var label: String? = nil
    var id: Usage { fixed ? 0xDEAD_0000 + usage : usage }

    func with(x: Double? = nil, y: Double? = nil, w: Double? = nil, h: Double? = nil, label: String? = nil, fixed: Bool? = nil) -> KeyDef {
        KeyDef(usage: usage, vk: vk, x: x ?? self.x, y: y ?? self.y, w: w ?? self.w, h: h ?? self.h, shape: shape,
               fixed: fixed ?? self.fixed, label: label ?? self.label)
    }
}

/// The shape of a keyboard, for drawing it.
enum LayoutKind: String, Codable, CaseIterable, Hashable {
    case huntsman, full, tkl, sixty, mac

    var title: String {
        switch self {
        case .huntsman: "Full + media"
        case .full: "Full"
        case .tkl: "TKL"
        case .sixty: "60%"
        case .mac: "Mac"
        }
    }
}

enum Keys {
    // MARK: Names

    /// Human names for keys that don't print a character.
    static let names: [Usage: String] = {
        var n: [Usage: String] = [
            HID.key(0x28): "Enter", HID.key(0x29): "Esc", HID.key(0x2A): "Backspace", HID.key(0x2B): "Tab",
            HID.key(0x2C): "Space", HID.key(0x39): "Caps Lock",
            HID.key(0x46): "Print Screen", HID.key(0x47): "Scroll Lock", HID.key(0x48): "Pause",
            HID.key(0x49): "Insert", HID.key(0x4A): "Home", HID.key(0x4B): "Page Up", HID.key(0x4C): "Delete",
            HID.key(0x4D): "End", HID.key(0x4E): "Page Down",
            HID.key(0x4F): "Right Arrow", HID.key(0x50): "Left Arrow", HID.key(0x51): "Down Arrow", HID.key(0x52): "Up Arrow",
            HID.key(0x53): "Num Lock", HID.key(0x54): "Numpad /", HID.key(0x55): "Numpad *", HID.key(0x56): "Numpad −",
            HID.key(0x57): "Numpad +", HID.key(0x58): "Numpad Enter", HID.key(0x63): "Numpad .",
            HID.key(0x65): "Menu",
            HID.key(0xE0): "Left Ctrl", HID.key(0xE1): "Left Shift", HID.key(0xE2): "Left Alt (⌥)",
            HID.key(0xE3): "Left Win (⌘)", HID.key(0xE4): "Right Ctrl", HID.key(0xE5): "Right Shift",
            HID.key(0xE6): "Alt Gr (⌥)", HID.key(0xE7): "Right Win (⌘)",
            HID.fn: "Fn / Globe",
            HID.none: "Disabled",
            HID.consumer(0xCD): "Play / Pause", HID.consumer(0xB5): "Next Track", HID.consumer(0xB6): "Previous Track",
            HID.consumer(0xE2): "Mute", HID.consumer(0xE9): "Volume Up", HID.consumer(0xEA): "Volume Down",
            HID.consumer(0x6F): "Brightness Up", HID.consumer(0x70): "Brightness Down",
            HID.consumer(0x29F): "Mission Control", HID.consumer(0x2A2): "Launchpad", HID.consumer(0x221): "Spotlight",
            HID.consumer(0xCF): "Dictation",
        ]
        for i in 0..<12 { n[HID.key(0x3A + UInt64(i))] = "F\(i + 1)" }
        for i in 0..<8 { n[HID.key(0x68 + UInt64(i))] = "F\(i + 13)" }
        for i in 0..<9 { n[HID.key(0x59 + UInt64(i))] = "Numpad \(i + 1)" }
        n[HID.key(0x62)] = "Numpad 0"
        return n
    }()

    /// Short legend printed on the keycap.
    static let caps: [Usage: String] = [
        HID.key(0x28): "Enter", HID.key(0x29): "Esc", HID.key(0x2A): "⌫", HID.key(0x2B): "Tab ⇥",
        HID.key(0x2C): "", HID.key(0x39): "Caps",
        HID.key(0x46): "PrtSc", HID.key(0x47): "ScrLk", HID.key(0x48): "Pause",
        HID.key(0x49): "Ins", HID.key(0x4A): "Home", HID.key(0x4B): "PgUp", HID.key(0x4C): "Del",
        HID.key(0x4D): "End", HID.key(0x4E): "PgDn",
        HID.key(0x4F): "→", HID.key(0x50): "←", HID.key(0x51): "↓", HID.key(0x52): "↑",
        HID.key(0x53): "Num", HID.key(0x54): "/", HID.key(0x55): "*", HID.key(0x56): "−", HID.key(0x57): "+",
        HID.key(0x58): "Enter", HID.key(0x63): ".", HID.key(0x65): "☰",
        HID.key(0xE0): "Ctrl", HID.key(0xE1): "⇧ Shift", HID.key(0xE2): "Alt", HID.key(0xE3): "Win",
        HID.key(0xE4): "Ctrl", HID.key(0xE5): "⇧ Shift", HID.key(0xE6): "Alt Gr", HID.key(0xE7): "Win",
        HID.fn: "Fn", HID.none: "⊘",
        HID.consumer(0xCD): "⏯", HID.consumer(0xB5): "⏭", HID.consumer(0xB6): "⏮",
        HID.consumer(0xE2): "Mute", HID.consumer(0xE9): "Vol+", HID.consumer(0xEA): "Vol−",
        HID.consumer(0x6F): "☀︎+", HID.consumer(0x70): "☀︎−",
        HID.consumer(0x29F): "Mission", HID.consumer(0x2A2): "Launch", HID.consumer(0x221): "Search", HID.consumer(0xCF): "Dictate",
    ]

    /// What the Mac calls the modifier (shown under the Windows-style keycap legend).
    static let macHint: [Usage: String] = [
        HID.key(0xE0): "⌃", HID.key(0xE2): "⌥", HID.key(0xE3): "⌘",
        HID.key(0xE4): "⌃", HID.key(0xE6): "⌥", HID.key(0xE7): "⌘",
    ]

    // MARK: Layout-aware legends

    /// The character a key types on the current keyboard layout (so AZERTY shows AZERTY), plus its shifted one.
    static func typed(vk: Int) -> (plain: String, shifted: String)? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        func tr(_ mods: UInt32) -> String {
            data.withUnsafeBytes { raw -> String in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                UCKeyTranslate(layout, UInt16(vk), UInt16(kUCKeyActionDisplay), mods, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                return String(utf16CodeUnits: chars, count: len)
            }
        }
        let p = tr(0), s = tr(UInt32(shiftKey >> 8) & 0xFF)
        guard !p.isEmpty, p.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return (p, s)
    }

    /// vk code for each usage that types a character (ISO-aware: macOS swaps the two keys around "<").
    static func vk(for usage: Usage, iso: Bool) -> Int? {
        if usage == HID.key(0x35) { return iso ? 10 : 50 }
        if usage == HID.key(0x64) { return iso ? 50 : 10 }
        return vkTable[usage]
    }

    static let vkTable: [Usage: Int] = {
        let letters: [Int] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]  // a…z
        let digits: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]                                                        // 1…0
        var t: [Usage: Int] = [:]
        for (i, v) in letters.enumerated() { t[HID.key(0x04 + UInt64(i))] = v }
        for (i, v) in digits.enumerated() { t[HID.key(0x1E + UInt64(i))] = v }
        let rest: [(UInt64, Int)] = [
            (0x28, 36), (0x29, 53), (0x2A, 51), (0x2B, 48), (0x2C, 49), (0x2D, 27), (0x2E, 24), (0x2F, 33), (0x30, 30),
            (0x31, 42), (0x32, 42), (0x33, 41), (0x34, 39), (0x36, 43), (0x37, 47), (0x38, 44), (0x39, 57),
            (0x3A, 122), (0x3B, 120), (0x3C, 99), (0x3D, 118), (0x3E, 96), (0x3F, 97), (0x40, 98), (0x41, 100),
            (0x42, 101), (0x43, 109), (0x44, 103), (0x45, 111),
            (0x68, 105), (0x69, 107), (0x6A, 113), (0x6B, 106), (0x6C, 64), (0x6D, 79), (0x6E, 80), (0x6F, 90),
            (0x49, 114), (0x4A, 115), (0x4B, 116), (0x4C, 117), (0x4D, 119), (0x4E, 121),
            (0x4F, 124), (0x50, 123), (0x51, 125), (0x52, 126),
            (0x53, 71), (0x54, 75), (0x55, 67), (0x56, 78), (0x57, 69), (0x58, 76), (0x63, 65),
            (0x59, 83), (0x5A, 84), (0x5B, 85), (0x5C, 86), (0x5D, 87), (0x5E, 88), (0x5F, 89), (0x60, 91), (0x61, 92), (0x62, 82),
            (0xE0, 59), (0xE1, 56), (0xE2, 58), (0xE3, 55), (0xE4, 62), (0xE5, 60), (0xE6, 61), (0xE7, 54),
        ]
        for (u, v) in rest { t[HID.key(u)] = v }
        return t
    }()

    /// Reverse lookup for the live highlight / key recording: vk code → usage.
    static func usage(forVK vk: Int, iso: Bool) -> Usage? {
        if vk == 10 { return HID.key(iso ? 0x35 : 0x64) }
        if vk == 50 { return HID.key(iso ? 0x64 : 0x35) }
        if vk == 42 { return HID.key(iso ? 0x32 : 0x31) }
        if vk == 63 { return HID.fn }
        return vkTable.first { $0.value == vk }?.key
    }

    /// Modifier flag bit that goes with each modifier vk (for flagsChanged: down or up?).
    static let modifierFlag: [Int: UInt] = [
        59: 0x1, 62: 0x2000, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40,  // device-dependent NX_DEVICE*KEYMASK bits
        57: 1 << 16, 63: 1 << 23,
    ]

    /// Consumer usage for a media key NSEvent (systemDefined subtype 8, NX_KEYTYPE_* in data1 >> 16).
    static func consumer(nxKey: Int) -> Usage? {
        switch nxKey {
        case 0: return HID.consumer(0xE9)
        case 1: return HID.consumer(0xEA)
        case 2: return HID.consumer(0x6F)
        case 3: return HID.consumer(0x70)
        case 7: return HID.consumer(0xE2)
        case 16: return HID.consumer(0xCD)
        case 17, 19: return HID.consumer(0xB5)
        case 18, 20: return HID.consumer(0xB6)
        default: return nil
        }
    }

    // Legends come from the keyboard layout (TIS + UCKeyTranslate), which is slow: cache them and
    // throw the cache away when the user switches input source.
    private struct LegendKey: Hashable { let u: Usage; let iso: Bool }
    nonisolated(unsafe) private static var legendCache: [LegendKey: (main: String, top: String?)] = [:]
    nonisolated(unsafe) private static var layoutCache: [Bool: [KeyDef]] = [:]
    private struct LayoutKey: Hashable { let kind: LayoutKind; let iso: Bool }
    nonisolated(unsafe) private static var kindCache: [LayoutKey: [KeyDef]] = [:]
    nonisolated(unsafe) private static var observing = false

    private static func watchInputSource() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in
            legendCache = [:]; layoutCache = [:]; kindCache = [:]
        }
    }

    /// Big legend + optional small second legend (top) for a usage on the current layout.
    static func legend(_ u: Usage, iso: Bool) -> (main: String, top: String?) {
        watchInputSource()
        let key = LegendKey(u: u, iso: iso)
        if let hit = legendCache[key] { return hit }
        let l = computeLegend(u, iso: iso)
        legendCache[key] = l
        return l
    }

    private static func computeLegend(_ u: Usage, iso: Bool) -> (main: String, top: String?) {
        if let c = caps[u] { return (c, nil) }
        if let n = names[u], u >> 32 == 0x07, (0x3A...0x45).contains(u & 0xFFFF) || (0x68...0x6F).contains(u & 0xFFFF) { return (n, nil) }
        if (0x59...0x62).contains(u & 0xFFFF), u >> 32 == 0x07 { return (u & 0xFFFF == 0x62 ? "0" : "\((u & 0xFFFF) - 0x58)", nil) }
        if let vk = vk(for: u, iso: iso), let t = typed(vk: vk) {
            let plain = t.plain.uppercased() == t.shifted ? t.shifted : t.plain
            if t.shifted != plain && t.shifted.uppercased() != plain { return (plain, t.shifted) }
            return (plain.uppercased(), nil)
        }
        return (names[u] ?? String(format: "0x%llX", u), nil)
    }

    /// Full name used in lists and menus.
    static func name(_ u: Usage, iso: Bool) -> String {
        if let n = names[u] { return n }
        let l = legend(u, iso: iso)
        return l.top.map { "\(l.main)  \($0)" } ?? l.main
    }

    // MARK: Targets for the picker

    struct Group: Identifiable { let title: String; let icon: String; let usages: [Usage]; var id: String { title } }

    static func targetGroups(iso: Bool) -> [Group] {
        let letters = (0x04...0x1D).map { HID.key(UInt64($0)) }.sorted { legend($0, iso: iso).main < legend($1, iso: iso).main }
        let numbers = (0x1E...0x27).map { HID.key(UInt64($0)) }
        var symbols = [0x2D, 0x2E, 0x2F, 0x30, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38].map { HID.key(UInt64($0)) }
        symbols += iso ? [HID.key(0x32), HID.key(0x64)] : [HID.key(0x31)]
        return [
            Group(title: "Letters", icon: "textformat", usages: letters),
            Group(title: "Numbers", icon: "number", usages: numbers),
            Group(title: "Symbols", icon: "at", usages: symbols),
            Group(title: "Modifiers", icon: "command",
                  usages: [0xE3, 0xE2, 0xE0, 0xE1, 0xE7, 0xE6, 0xE4, 0xE5, 0x39].map { HID.key(UInt64($0)) } + [HID.fn]),
            Group(title: "Editing & Navigation", icon: "arrow.up.arrow.down",
                  usages: [0x29, 0x28, 0x2B, 0x2C, 0x2A, 0x4C, 0x49, 0x4A, 0x4D, 0x4B, 0x4E, 0x52, 0x51, 0x50, 0x4F,
                           0x46, 0x47, 0x48, 0x65].map { HID.key(UInt64($0)) }),
            Group(title: "Function Keys", icon: "f.cursive", usages: (0x3A...0x45).map { HID.key(UInt64($0)) } + (0x68...0x6F).map { HID.key(UInt64($0)) }),
            Group(title: "Numpad", icon: "square.grid.3x3",
                  usages: (0x59...0x62).map { HID.key(UInt64($0)) } + [0x54, 0x55, 0x56, 0x57, 0x58, 0x63, 0x53].map { HID.key(UInt64($0)) }),
            Group(title: "Media", icon: "playpause",
                  usages: [0xCD, 0xB5, 0xB6, 0xE2, 0xE9, 0xEA, 0x6F, 0x70].map { HID.consumer(UInt64($0)) }),
            Group(title: "Mac", icon: "macwindow",
                  usages: [0x29F, 0x2A2, 0x221, 0xCF].map { HID.consumer(UInt64($0)) }),
        ]
    }

    // MARK: Huntsman V2 (full size) layout

    static func huntsmanV2(iso: Bool) -> [KeyDef] {
        if let hit = layoutCache[iso] { return hit }
        let k = buildHuntsmanV2(iso: iso)
        layoutCache[iso] = k
        return k
    }

    private static func buildHuntsmanV2(iso: Bool) -> [KeyDef] {
        var k: [KeyDef] = []
        func add(_ u: UInt64, _ x: Double, _ y: Double, w: Double = 1, h: Double = 1, shape: KeyDef.Shape = .normal) {
            let usage = HID.key(u)
            k.append(KeyDef(usage: usage, vk: vk(for: usage, iso: iso), x: x, y: y, w: w, h: h, shape: shape))
        }
        // function row
        add(0x29, 0, 0)
        for i in 0..<4 { add(0x3A + UInt64(i), 2 + Double(i), 0) }
        for i in 0..<4 { add(0x3E + UInt64(i), 6.5 + Double(i), 0) }
        for i in 0..<4 { add(0x42 + UInt64(i), 11 + Double(i), 0) }
        add(0x46, 15.25, 0); add(0x47, 16.25, 0); add(0x48, 17.25, 0)
        // media keys + volume dial (top right on the Huntsman V2)
        let media: [UInt64] = [0xB6, 0xCD, 0xB5, 0xE2]
        for (i, u) in media.enumerated() {
            k.append(KeyDef(usage: HID.consumer(u), vk: nil, x: 18.6 + Double(i) * 0.82, y: 0.1, w: 0.72, h: 0.8, shape: .round))
        }

        // number row
        let y1 = 1.25
        add(0x35, 0, y1)
        for i in 0..<10 { add(0x1E + UInt64(i), 1 + Double(i), y1) }
        add(0x2D, 11, y1); add(0x2E, 12, y1); add(0x2A, 13, y1, w: 2)
        add(0x49, 15.25, y1); add(0x4A, 16.25, y1); add(0x4B, 17.25, y1)
        add(0x53, 18.5, y1); add(0x54, 19.5, y1); add(0x55, 20.5, y1); add(0x56, 21.5, y1)

        // top letter row
        let y2 = y1 + 1
        add(0x2B, 0, y2, w: 1.5)
        let top: [UInt64] = [0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x2F, 0x30]
        for (i, u) in top.enumerated() { add(u, 1.5 + Double(i), y2) }
        if iso { add(0x28, 13.5, y2, w: 1.5, h: 2, shape: .isoEnter) } else { add(0x31, 13.5, y2, w: 1.5) }
        add(0x4C, 15.25, y2); add(0x4D, 16.25, y2); add(0x4E, 17.25, y2)
        add(0x5F, 18.5, y2); add(0x60, 19.5, y2); add(0x61, 20.5, y2); add(0x57, 21.5, y2, h: 2)

        // home row
        let y3 = y2 + 1
        add(0x39, 0, y3, w: 1.75)
        let home: [UInt64] = [0x04, 0x16, 0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33, 0x34]
        for (i, u) in home.enumerated() { add(u, 1.75 + Double(i), y3) }
        if iso { add(0x32, 12.75, y3) } else { add(0x28, 12.75, y3, w: 2.25) }
        add(0x5C, 18.5, y3); add(0x5D, 19.5, y3); add(0x5E, 20.5, y3)

        // bottom letter row
        let y4 = y3 + 1
        var x = 0.0
        if iso { add(0xE1, 0, y4, w: 1.25); add(0x64, 1.25, y4); x = 2.25 } else { add(0xE1, 0, y4, w: 2.25); x = 2.25 }
        let bottom: [UInt64] = [0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38]
        for (i, u) in bottom.enumerated() { add(u, x + Double(i), y4) }
        add(0xE5, 12.25, y4, w: 2.75)
        add(0x52, 16.25, y4)
        add(0x59, 18.5, y4); add(0x5A, 19.5, y4); add(0x5B, 20.5, y4); add(0x58, 21.5, y4, h: 2)

        // space row: Ctrl Win Alt Space AltGr Fn Menu Ctrl
        let y5 = y4 + 1
        add(0xE0, 0, y5, w: 1.25); add(0xE3, 1.25, y5, w: 1.25); add(0xE2, 2.5, y5, w: 1.25)
        add(0x2C, 3.75, y5, w: 6.25)
        add(0xE6, 10, y5, w: 1.25)
        k.append(KeyDef(usage: HID.fn, vk: nil, x: 11.25, y: y5, w: 1.25, fixed: true))
        add(0x65, 12.5, y5, w: 1.25); add(0xE4, 13.75, y5, w: 1.25)
        add(0x50, 15.25, y5); add(0x51, 16.25, y5); add(0x4F, 17.25, y5)
        add(0x62, 18.5, y5, w: 2); add(0x63, 20.5, y5)
        return k
    }

    static let layoutWidth = 22.5
    static let layoutHeight = 6.25

    // MARK: Other keyboards

    /// Keys of any supported keyboard shape.
    static func layout(_ kind: LayoutKind, iso: Bool) -> [KeyDef] {
        let key = LayoutKey(kind: kind, iso: iso)
        if let hit = kindCache[key] { return hit }
        let full = huntsmanV2(iso: iso)
        var k: [KeyDef]
        switch kind {
        case .huntsman:
            k = full
        case .full:
            k = full.filter { $0.shape != .round }                         // no media buttons
        case .tkl:
            k = full.filter { $0.shape != .round && $0.x < 18.4 }          // no numpad
        case .sixty:
            // main block only, no F-row; the top-left key is Esc (` lives behind Fn on 60% boards)
            k = full.filter { $0.x < 15 && $0.y >= 1.25 }.map { d in
                d.usage == HID.key(0x35)
                    ? KeyDef(usage: HID.key(0x29), vk: 53, x: d.x, y: d.y - 1.25, w: d.w, h: d.h)
                    : d.with(y: d.y - 1.25)
            }
        case .mac:
            k = mac(iso: iso, full: full)
        }
        kindCache[key] = k
        return k
    }

    /// Size of a layout in key units.
    static func bounds(_ keys: [KeyDef]) -> (w: Double, h: Double) {
        (keys.map { $0.x + $0.w }.max() ?? layoutWidth, keys.map { $0.y + $0.h }.max() ?? layoutHeight)
    }

    /// MacBook / Magic Keyboard: esc + F-row + Touch ID, fn ⌃ ⌥ ⌘ bottom row and inverted-T half-height arrows.
    private static func mac(iso: Bool, full: [KeyDef]) -> [KeyDef] {
        func key(_ u: UInt64, _ x: Double, _ y: Double, w: Double = 1, h: Double = 1, label: String? = nil) -> KeyDef {
            let usage = HID.key(u)
            return KeyDef(usage: usage, vk: vk(for: usage, iso: iso), x: x, y: y, w: w, h: h, label: label)
        }
        var k: [KeyDef] = []
        k.append(key(0x29, 0, 0, w: 1.5, label: "esc"))
        for i in 0..<12 { k.append(key(0x3A + UInt64(i), 1.5 + Double(i), 0)) }
        k.append(KeyDef(usage: HID.key(0x66), vk: nil, x: 13.5, y: 0, w: 1.5, fixed: true, label: "Touch ID"))
        // rows 1–4 are the usual main block, with Mac names on the big keys
        let names: [UInt64: String] = [0x2A: "delete", 0x2B: "tab", 0x39: "caps lock", 0x28: "return", 0xE1: "shift", 0xE5: "shift"]
        for d in full where d.x < 15 && d.y >= 1.25 && d.y < 5 {
            k.append(names[d.usage & 0xFF].map { d.with(label: $0) } ?? d)
        }
        let y5 = 5.25
        k.append(KeyDef(usage: HID.fn, vk: 63, x: 0, y: y5, label: "fn 🌐"))
        k.append(key(0xE0, 1, y5, label: "⌃ control"))
        k.append(key(0xE2, 2, y5, label: "⌥ option"))
        k.append(key(0xE3, 3, y5, w: 1.25, label: "⌘ command"))
        k.append(key(0x2C, 4.25, y5, w: 5.5))
        k.append(key(0xE7, 9.75, y5, w: 1.25, label: "⌘ command"))
        k.append(key(0xE6, 11, y5, label: "⌥ option"))
        k.append(key(0x50, 12, y5 + 0.5, h: 0.5))
        k.append(key(0x52, 13, y5, h: 0.5))
        k.append(key(0x51, 13, y5 + 0.5, h: 0.5))
        k.append(key(0x4F, 14, y5 + 0.5, h: 0.5))
        return k
    }

    /// True when the Mac's current keyboard type is ISO (the Huntsman V2 FR/DE/UK versions).
    static var systemIsISO: Bool { KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO }
}
