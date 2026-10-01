import SwiftUI
import AppKit

@_silgen_name("razer_send")
private func razer_send(_ vendor: Int32, _ product: Int32, _ cls: UInt8, _ cmd: UInt8, _ size: UInt8, _ args: UnsafePointer<UInt8>?) -> Int32

/// A profile's keyboard lighting.
struct Lighting: Codable, Equatable {
    enum Effect: String, Codable, CaseIterable {
        case solid, perKey, breathing, reactive, wave, spectrum, off
        // drawn live by KeyForge (the app has to be running)
        case ripple, rain, heatmap, cover, music

        static let builtIn: [Effect] = [.solid, .perKey, .breathing, .reactive, .wave, .spectrum, .off]
        static let live: [Effect] = [.ripple, .rain, .heatmap, .cover, .music]
        var isLive: Bool { Self.live.contains(self) }
    }
    var effect: Effect = .solid
    /// The main color (Per Key: the color of keys you haven't painted).
    var red = 0.70, green = 0.23, blue = 0.93
    var brightness = 1.0
    var waveRight = true
    /// Per Key: painted keys → 0xRRGGBB
    var keyColors: [Usage: UInt32] = [:]

    static let standard = Lighting()

    init() {}

    // older profiles.json files don't have every field
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        effect = (try? c.decodeIfPresent(Effect.self, forKey: .effect)) ?? .solid
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? red
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? green
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? blue
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
        waveRight = try c.decodeIfPresent(Bool.self, forKey: .waveRight) ?? waveRight
        keyColors = try c.decodeIfPresent([Usage: UInt32].self, forKey: .keyColors) ?? [:]
    }

    var baseHex: UInt32 {
        get { UInt32(max(0, min(255, red * 255))) << 16 | UInt32(max(0, min(255, green * 255))) << 8 | UInt32(max(0, min(255, blue * 255))) }
        set { red = Double(newValue >> 16 & 0xFF) / 255; green = Double(newValue >> 8 & 0xFF) / 255; blue = Double(newValue & 0xFF) / 255 }
    }

    /// 0xRRGGBB this key shows.
    func hex(for key: Usage) -> UInt32 { effect == .perKey ? keyColors[key] ?? baseHex : baseHex }

    var color: Color {
        get { Color(.sRGB, red: red, green: green, blue: blue) }
        set {
            let c = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
            red = Double(c.redComponent); green = Double(c.greenComponent); blue = Double(c.blueComponent)
        }
    }

    /// Effects that use the chosen color.
    var usesColor: Bool { [.solid, .perKey, .breathing, .reactive, .ripple, .rain, .music].contains(effect) }

    var title: String {
        switch effect {
        case .solid: "Solid"
        case .perKey: "Per Key"
        case .breathing: "Breathing"
        case .reactive: "Reactive"
        case .wave: "Wave"
        case .spectrum: "Spectrum"
        case .off: "Off"
        case .ripple: "Ripple"
        case .rain: "Rain"
        case .heatmap: "Heatmap"
        case .cover: "Album Cover"
        case .music: "Music"
        }
    }
}

/// Sends lighting to the keyboard on a background queue, newest setting wins.
enum LightingController {
    private enum Job { case effect(Lighting), frame([Usage: UInt32], Double) }
    private static let queue = DispatchQueue(label: "keyforge.lighting")
    private static var pending: Job?
    private static var product: Int32 = 0x026C
    private static var sentBrightness: UInt8?

    /// A built-in effect (the keyboard animates it itself).
    static func apply(_ l: Lighting, product p: Int?) { schedule(.effect(l), product: p, delay: 0.03) }

    /// One frame of per-key colors (Per Key with the Caps light, and the live effects).
    static func sendFrame(_ colors: [Usage: UInt32], brightness: Double, product p: Int?) {
        schedule(.frame(colors, brightness), product: p, delay: 0)
    }

    private static func schedule(_ job: Job, product p: Int?, delay: Double) {
        if ProcessInfo.processInfo.environment["KEYFORGE_DRY"] != nil { return }
        queue.async {
            if let p { product = Int32(p) }
            let first = pending == nil
            pending = job
            guard first else { return }   // a send is already queued; it will pick up the newest job
            queue.asyncAfter(deadline: .now() + delay) {
                guard let job = pending else { return }
                pending = nil
                switch job {
                case .effect(let l): send(l)
                case .frame(let f, let b): sendRows { f[$0] ?? 0 }; setBrightness(b)
                }
            }
        }
    }

    private static func setBrightness(_ b: Double, force: Bool = false) {
        let v = UInt8(max(0, min(255, b * 255)))
        guard force || v != sentBrightness else { return }
        sentBrightness = v
        cmd(0x0F, 0x04, [0x01, 0x05, v])
    }

    /// One frame row at a time (6 rows × 22 LEDs), then switch to the custom-frame effect.
    private static func sendRows(_ color: (Usage) -> UInt32) {
        for row in 0..<LEDMatrix.rows {
            var args: [UInt8] = [0x00, 0x00, UInt8(row), 0x00, UInt8(LEDMatrix.cols - 1)]
            for col in 0..<LEDMatrix.cols {
                let hex = LEDMatrix.usage(row: row, col: col).map(color) ?? 0
                args += [UInt8(hex >> 16 & 0xFF), UInt8(hex >> 8 & 0xFF), UInt8(hex & 0xFF)]
            }
            cmd(0x0F, 0x03, args)
        }
        cmd(0x0F, 0x02, [0x00, 0x00, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    private static func cmd(_ cls: UInt8, _ id: UInt8, _ args: [UInt8]) {
        _ = args.withUnsafeBufferPointer { razer_send(0x1532, product, cls, id, UInt8(args.count), $0.baseAddress) }
    }

    private static func send(_ l: Lighting) {
        let r = UInt8(max(0, min(255, l.red * 255))), g = UInt8(max(0, min(255, l.green * 255))), b = UInt8(max(0, min(255, l.blue * 255)))
        // variable storage 0x01, backlight LED 0x05 (OpenRazer's extended matrix commands)
        switch l.effect {
        case .off:       cmd(0x0F, 0x02, [0x01, 0x05, 0x00, 0x00, 0x00, 0x00])
        case .solid:     cmd(0x0F, 0x02, [0x01, 0x05, 0x01, 0x00, 0x00, 0x01, r, g, b])
        case .breathing: cmd(0x0F, 0x02, [0x01, 0x05, 0x02, 0x01, 0x00, 0x01, r, g, b])
        case .reactive:  cmd(0x0F, 0x02, [0x01, 0x05, 0x05, 0x00, 0x02, 0x01, r, g, b])
        case .spectrum:  cmd(0x0F, 0x02, [0x01, 0x05, 0x03, 0x00, 0x00, 0x00])
        case .wave:      cmd(0x0F, 0x02, [0x01, 0x05, 0x04, l.waveRight ? 0x01 : 0x02, 0x28, 0x00])
        case .perKey:
            sendRows { l.hex(for: $0) }
        case .ripple, .rain, .heatmap, .cover, .music:
            break   // LightingEngine sends these as frames
        }
        setBrightness(l.brightness, force: true)
    }
}

/// Which LED sits under which key on the Huntsman V2: OpenRGB's full-size grid (Esc at column 0) plus the
/// media keys at 17–20. (Polychromatic's Huntsman V2 Analog map is the same grid shifted one column right,
/// which left Esc/Tab/Caps/Shift/Ctrl dark on the real keyboard.)
enum LEDMatrix {
    static let rows = 6, cols = 22
    private static let table: [(Usage, Int, Int)] = [
        (0x700000029, 0, 0), (0x70000003A, 0, 2), (0x70000003B, 0, 3), (0x70000003C, 0, 4), (0x70000003D, 0, 5),
        (0x70000003E, 0, 6), (0x70000003F, 0, 7), (0x700000040, 0, 8), (0x700000041, 0, 9), (0x700000042, 0, 10),
        (0x700000043, 0, 11), (0x700000044, 0, 12), (0x700000045, 0, 13), (0x700000046, 0, 14), (0x700000047, 0, 15),
        (0x700000048, 0, 16), (0xC000000B6, 0, 17), (0xC000000CD, 0, 18), (0xC000000B5, 0, 19), (0xC000000E2, 0, 20),
        (0x700000035, 1, 0), (0x70000001E, 1, 1), (0x70000001F, 1, 2), (0x700000020, 1, 3), (0x700000021, 1, 4),
        (0x700000022, 1, 5), (0x700000023, 1, 6), (0x700000024, 1, 7), (0x700000025, 1, 8), (0x700000026, 1, 9),
        (0x700000027, 1, 10), (0x70000002D, 1, 11), (0x70000002E, 1, 12), (0x70000002A, 1, 13), (0x700000049, 1, 14),
        (0x70000004A, 1, 15), (0x70000004B, 1, 16), (0x700000053, 1, 17), (0x700000054, 1, 18), (0x700000055, 1, 19),
        (0x700000056, 1, 20),
        (0x70000002B, 2, 0), (0x700000014, 2, 1), (0x70000001A, 2, 2), (0x700000008, 2, 3), (0x700000015, 2, 4),
        (0x700000017, 2, 5), (0x70000001C, 2, 6), (0x700000018, 2, 7), (0x70000000C, 2, 8), (0x700000012, 2, 9),
        (0x700000013, 2, 10), (0x70000002F, 2, 11), (0x700000030, 2, 12), (0x700000031, 2, 13), (0x70000004C, 2, 14),
        (0x70000004D, 2, 15), (0x70000004E, 2, 16), (0x70000005F, 2, 17), (0x700000060, 2, 18), (0x700000061, 2, 19),
        (0x700000057, 2, 20),
        (0x700000039, 3, 0), (0x700000004, 3, 1), (0x700000016, 3, 2), (0x700000007, 3, 3), (0x700000009, 3, 4),
        (0x70000000A, 3, 5), (0x70000000B, 3, 6), (0x70000000D, 3, 7), (0x70000000E, 3, 8), (0x70000000F, 3, 9),
        (0x700000033, 3, 10), (0x700000034, 3, 11), (0x700000032, 3, 12), (0x700000028, 3, 13), (0x70000005C, 3, 17),
        (0x70000005D, 3, 18), (0x70000005E, 3, 19),
        (0x7000000E1, 4, 0), (0x700000064, 4, 1), (0x70000001D, 4, 2), (0x70000001B, 4, 3), (0x700000006, 4, 4),
        (0x700000019, 4, 5), (0x700000005, 4, 6), (0x700000011, 4, 7), (0x700000010, 4, 8), (0x700000036, 4, 9),
        (0x700000037, 4, 10), (0x700000038, 4, 11), (0x7000000E5, 4, 13), (0x700000052, 4, 15), (0x700000059, 4, 17),
        (0x70000005A, 4, 18), (0x70000005B, 4, 19), (0x700000058, 4, 20),
        (0x7000000E0, 5, 0), (0x7000000E3, 5, 1), (0x7000000E2, 5, 2), (0x70000002C, 5, 6), (0x7000000E6, 5, 10),
        (0xFF00000003, 5, 11), (0x700000065, 5, 12), (0x7000000E4, 5, 13), (0x700000050, 5, 14), (0x700000051, 5, 15),
        (0x70000004F, 5, 16), (0x700000062, 5, 18), (0x700000063, 5, 19),
    ]
    private static let grid: [Int: Usage] = {
        var g: [Int: Usage] = [:]
        for (u, r, c) in table { g[r * cols + c] = u }
        return g
    }()

    static func usage(row: Int, col: Int) -> Usage? { grid[row * cols + col] }

    private static let positions: [Usage: (row: Int, col: Int)] = {
        var p: [Usage: (row: Int, col: Int)] = [:]
        for (u, r, c) in table { p[u] = (r, c) }
        return p
    }()

    static func position(of u: Usage) -> (row: Int, col: Int)? { positions[u] }
}

// MARK: - Premade themes and the randomizer

/// Ready-made Per Key looks, generated from each key's position on the board.
enum LightingPreset: String, CaseIterable, Identifiable {
    case synthwave = "Synthwave", aurora = "Aurora", sunset = "Sunset", inferno = "Inferno",
         glacier = "Glacier", gamer = "Gamer", razer = "Razer"
    var id: String { rawValue }

    /// Colors for the chip's preview gradient.
    var preview: [UInt32] {
        switch self {
        case .synthwave: [0xFF2E97, 0x9D4EDD, 0x00F0FF]
        case .aurora: [0x00FF87, 0x00C2FF, 0x7B2FF7]
        case .sunset: [0x6A1B9A, 0xFF2E63, 0xFF9A00]
        case .inferno: [0xFF0000, 0xFF6A00, 0xFFE600]
        case .glacier: [0xFFFFFF, 0x7FD8FF, 0x1E5BFF]
        case .gamer: [0x3C1F6E, 0xFF1E1E, 0xFF8A00]
        case .razer: [0x0B3D0B, 0x44D62C, 0xFFFFFF]
        }
    }

    /// 0xRRGGBB for a key at x, y (0…1 across the board).
    func color(for k: KeyDef, x: Double, y: Double) -> UInt32 {
        switch self {
        case .synthwave: return Self.blend(preview, x)
        case .aurora: return Self.blend(preview, min(1, max(0, x * 0.85 + y * 0.15)))
        case .sunset: return Self.blend(preview, y)                                   // purple sky → orange at the bottom
        case .inferno: return Self.blend(preview, 1 - y)                              // red at the bottom, yellow flames on top
        case .glacier: return Self.blend(preview, min(1, max(0, (x + y) / 2)))
        case .gamer:
            let u = k.usage & 0xFFFF
            if k.usage >> 32 == 7 && [0x1A, 0x04, 0x16, 0x07, 0x4F, 0x50, 0x51, 0x52].contains(u) { return 0xFF1E1E }  // ZQSD/WASD + arrows
            if k.usage >> 32 == 7 && [0x2C, 0xE1, 0xE0, 0x2B, 0x15, 0x08, 0x14].contains(u) { return 0xFF8A00 }        // space, shift, ctrl, tab, R, E, A/Q
            if k.usage == HID.key(0x29) { return 0xFFFFFF }
            return 0x3C1F6E
        case .razer:
            if k.usage >> 32 == 7 && [0x4F, 0x50, 0x51, 0x52, 0x29].contains(k.usage & 0xFFFF) { return 0xFFFFFF }
            return (k.usage >> 32 == 7 && (0x04...0x27).contains(k.usage & 0xFFFF)) ? 0x44D62C : 0x1F8A12
        }
    }

    /// Linear blend through `stops` at t (0…1).
    static func blend(_ stops: [UInt32], _ t: Double) -> UInt32 {
        let t = min(1, max(0, t)) * Double(stops.count - 1)
        let i = min(Int(t), stops.count - 2), f = t - Double(i)
        func ch(_ c: UInt32, _ s: UInt32) -> Double { Double(c >> s & 0xFF) }
        var out: UInt32 = 0
        for sh in [16, 8, 0] as [UInt32] {
            let v = ch(stops[i], sh) + (ch(stops[i + 1], sh) - ch(stops[i], sh)) * f
            out |= UInt32(max(0, min(255, v.rounded()))) << sh
        }
        return out
    }

    /// The whole board in this theme.
    func keyColors(iso: Bool) -> [Usage: UInt32] {
        var m: [Usage: UInt32] = [:]
        for k in Keys.huntsmanV2(iso: iso) {
            m[k.usage] = color(for: k, x: (k.x + k.w / 2) / Keys.layoutWidth, y: (k.y + k.h / 2) / Keys.layoutHeight)
        }
        return m
    }

    /// Every key its own vivid random color.
    static func random(iso: Bool) -> [Usage: UInt32] {
        var m: [Usage: UInt32] = [:]
        for k in Keys.huntsmanV2(iso: iso) {
            let c = NSColor(hue: .random(in: 0...1), saturation: .random(in: 0.75...1), brightness: 1, alpha: 1)
            m[k.usage] = Color(nsColor: c).hex
        }
        return m
    }
}

// MARK: - UI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var hex: UInt32 {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return UInt32(max(0, min(255, c.redComponent * 255))) << 16 | UInt32(max(0, min(255, c.greenComponent * 255))) << 8
            | UInt32(max(0, min(255, c.blueComponent * 255)))
    }
}

/// Colors the user saved from the Lighting tab (shared by all profiles).
@MainActor
final class SavedColors: ObservableObject {
    static let shared = SavedColors()
    static let limit = 12
    @Published private(set) var colors: [UInt32] =
        (UserDefaults.standard.array(forKey: "savedColors") as? [Int] ?? []).map { UInt32(truncatingIfNeeded: $0) }

    func add(_ hex: UInt32) {
        guard !colors.contains(hex) else { return }
        colors.append(hex)
        if colors.count > Self.limit { colors.removeFirst(colors.count - Self.limit) }   // oldest goes first
        persist()
    }

    func remove(_ hex: UInt32) {
        colors.removeAll { $0 == hex }
        persist()
    }

    private func persist() { UserDefaults.standard.set(colors.map { Int($0) }, forKey: "savedColors") }
}

/// The color Per Key painting uses.
@MainActor
final class PaintBrush: ObservableObject {
    static let shared = PaintBrush()
    @Published var hex: UInt32 = 0xFFFFFF

    /// Paints (or erases) one key of the active profile.
    func paint(_ key: Usage, erase: Bool, store: ProfileStore) {
        guard var l = store.active?.lighting ?? Optional(.standard), l.effect == .perKey else { return }
        let want: UInt32? = erase ? nil : hex
        guard l.keyColors[key] != want else { return }
        l.keyColors[key] = want
        store.setLighting(l)
    }
}

struct LightingCard: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject private var brush = PaintBrush.shared
    @ObservedObject private var saved = SavedColors.shared
    @ObservedObject private var engine = LightingEngine.shared
    @ObservedObject private var tap = KeyTap.shared
    @ObservedObject private var nowPlaying = NowPlayingLink.shared
    @ObservedObject private var heat = Heatmap.shared
    @Environment(\.appTheme) private var theme

    static let swatches: [(String, UInt32)] = [
        ("Razer Green", 0x44D62C), ("Purple", 0xB23AEE), ("Pink", 0xFF3FA4), ("Red", 0xFF1A1A), ("Orange", 0xFF7A00),
        ("Yellow", 0xFFD400), ("Cyan", 0x00E5FF), ("Blue", 0x2F5BFF), ("White", 0xFFFFFF),
    ]

    private var lighting: Binding<Lighting> {
        Binding(get: { store.active?.lighting ?? .standard },
                set: { store.setLighting($0) })
    }

    /// The color the controls show and change: the brush in Per Key mode, otherwise the lighting color.
    private func currentHex(_ l: Lighting) -> UInt32 { l.effect == .perKey ? brush.hex : l.baseHex }

    private func choose(_ hex: UInt32) {
        var n = lighting.wrappedValue
        if n.effect == .perKey { brush.hex = hex; return }
        n.baseHex = hex
        if !n.usesColor { n.effect = .solid }
        lighting.wrappedValue = n
    }

    var body: some View {
        let l = lighting.wrappedValue
        let cur = currentHex(l)
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                effectRow("Effects", Lighting.Effect.builtIn, l)
                effectRow("Live", Lighting.Effect.live, l)
                if l.effect.isLive { liveInfo(l) }

                // premade looks + randomizer (they switch to Per Key)
                HStack(spacing: 8) {
                    Text("Themes").font(.subheadline).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                    ForEach(LightingPreset.allCases) { p in
                        Button {
                            var n = l
                            n.effect = .perKey
                            n.keyColors = p.keyColors(iso: store.iso)
                            n.baseHex = p.preview[1]
                            withAnimation(.easeInOut(duration: 0.25)) { lighting.wrappedValue = n }
                        } label: {
                            Text(p.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 1.5)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(LinearGradient(colors: p.preview.map { Color(hex: $0) },
                                                                          startPoint: .leading, endPoint: .trailing)))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(p.rawValue) theme (Per Key)")
                    }
                    Button {
                        var n = l
                        n.effect = .perKey
                        n.keyColors = LightingPreset.random(iso: store.iso)
                        lighting.wrappedValue = n
                    } label: {
                        Label("Randomize", systemImage: "dice.fill").fixedSize()
                    }
                    .buttonStyle(.purpleGlassProminent)
                    .help("Give every key its own random color (click again for a new mix)")
                }

                HStack(alignment: .center, spacing: 18) {
                    // big color preview + pickers
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(preview(l, cur))
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                    .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ForEach(Self.swatches, id: \.0) { s in
                                swatch(s.1, on: l.usesColor && cur == s.1).help(s.0)
                            }
                        }

                        // your own colors
                        HStack(spacing: 8) {
                            ForEach(saved.colors, id: \.self) { hex in
                                swatch(hex, on: l.usesColor && cur == hex)
                                    .help(String(format: "#%06X · right-click to remove", hex))
                                    .contextMenu {
                                        Button("Remove Color", role: .destructive) { withAnimation { saved.remove(hex) } }
                                    }
                                    .transition(.scale.combined(with: .opacity))
                            }
                            let canSave = l.usesColor && !saved.colors.contains(cur)
                            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { saved.add(cur) } } label: {
                                ZStack {
                                    Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                                }
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSave)
                            .opacity(canSave ? 1 : 0.4)
                            .help(saved.colors.contains(cur) ? "This color is already saved" : "Save the current color")
                            if saved.colors.isEmpty {
                                Text("Save your own colors here").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                NSColorSampler().show { picked in
                                    guard let picked else { return }
                                    choose(Color(nsColor: picked).hex)
                                }
                            } label: {
                                Label("Pick from Screen", systemImage: "eyedropper")
                            }
                            .buttonStyle(.purpleGlassProminent)
                            .help("Click anywhere on your screen to use that color")

                            ColorPicker("Custom", selection: Binding(get: { Color(hex: cur) }, set: { choose($0.hex) }),
                                        supportsOpacity: false)

                            Text(String(format: "#%06X", cur)).font(.callout.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: lighting.brightness, in: 0...1)
                    Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                    Text("\(Int(l.brightness * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    if l.effect == .wave {
                        GlassSegmented(selection: lighting.waveRight, options: [(false, "← Left"), (true, "Right →")])
                            .frame(width: 190)
                    }
                }
                .disabled(l.effect == .off)

                if l.effect == .perKey {
                    HStack(spacing: 10) {
                        Image(systemName: "paintbrush.pointed.fill").foregroundStyle(Color(hex: brush.hex))
                        Text("Click or drag over keys to paint them. ⌥ Option-click to erase.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Fill All") {
                            var n = l; n.baseHex = brush.hex; n.keyColors = [:]; lighting.wrappedValue = n
                        }
                        .buttonStyle(.purpleGlass)
                        .help("Every key in the brush color")
                        Button("Clear Painted") {
                            var n = l; n.keyColors = [:]; lighting.wrappedValue = n
                        }
                        .buttonStyle(.purpleGlass)
                        .disabled(l.keyColors.isEmpty)
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    Toggle(isOn: $engine.capsLight) {
                        Text("Caps Lock light")
                    }
                    .toggleStyle(.switch)
                    ColorPicker("Caps Lock color", selection: Binding(get: { Color(hex: engine.capsHex) },
                                                                     set: { engine.capsHex = $0.hex }), supportsOpacity: false)
                        .labelsHidden()
                        .disabled(!engine.capsLight)
                    Text(engine.capsLight
                         ? (l.effect == .solid || l.effect == .perKey || l.effect.isLive
                            ? (engine.capsOn ? "Caps Lock is on" : "The Caps Lock key lights up while it's on")
                            : "Works with Solid, Per Key and the Live effects")
                         : "Light the Caps Lock key in its own color while Caps Lock is on")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }

                if store.devices.name == nil {
                    Text("Plug in your Huntsman V2 to see the colors.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func effectRow(_ title: String, _ effects: [Lighting.Effect], _ l: Lighting) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            GlassSegmented(selection: Binding(get: { l.effect }, set: { e in
                                var n = lighting.wrappedValue
                                if e == .perKey && n.effect != .perKey { brush.hex = n.baseHex == 0xFFFFFF ? 0xB23AEE : 0xFFFFFF }
                                n.effect = e
                                lighting.wrappedValue = n
                                if e == .ripple || e == .heatmap { tap.ensureRunning(); if !tap.trusted { tap.requestAccess() } }
                           }),
                           options: effects.map { e in (e, { var x = Lighting(); x.effect = e; return x.title }()) })
        }
    }

    @ViewBuilder private func liveInfo(_ l: Lighting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            switch l.effect {
            case .ripple:
                Text("Every key you press sends a ripple across the board in your color.")
            case .rain:
                Text("Drops of your color fall down the keyboard.")
            case .heatmap:
                Text("Keys glow hotter the more you use them (\(heat.counts.values.reduce(0, +)) presses counted).")
                Button("Reset") { heat.reset() }.buttonStyle(.purpleGlass)
            case .cover:
                if nowPlaying.colors.isEmpty {
                    Text("Play a song in MP3 Tagger and the keyboard takes its album cover colors.")
                } else {
                    Text(nowPlaying.playing ? "Now playing in MP3 Tagger: \(nowPlaying.title)" : "MP3 Tagger is paused (\(nowPlaying.title))")
                        .lineLimit(1)
                }
            case .music:
                if let e = AudioTap.shared.lastError {
                    Text("Couldn't listen to the Mac's audio: \(e). Allow KeyForge under System Settings → Privacy & Security → Screen & System Audio Recording.")
                } else {
                    Text("The columns dance to whatever your Mac is playing.")
                }
            default: EmptyView()
            }
            Spacer()
            if (l.effect == .ripple || l.effect == .heatmap) && !tap.trusted {
                Button("Allow Key Access…") { tap.requestAccess() }.buttonStyle(.purpleGlassProminent)
                    .help("KeyForge needs Accessibility to see your key presses")
                Button("Reset permission") { tap.resetAndRequest() }.buttonStyle(.link)
                    .help("Already switched on? This clears the old entry and asks again")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        Text("Live effects are drawn by KeyForge, so they run while it's open (it stays in the menu bar).")
            .font(.caption).foregroundStyle(.tertiary)
    }

    private func swatch(_ hex: UInt32, on: Bool) -> some View {
        Button { choose(hex) } label: {
            Circle()
                .fill(Color(hex: hex))
                .overlay(Circle().strokeBorder(on ? Color.primary : Color.primary.opacity(0.15), lineWidth: on ? 2.5 : 0.5))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private func preview(_ l: Lighting, _ cur: UInt32) -> AnyShapeStyle {
        switch l.effect {
        case .off: AnyShapeStyle(Color(white: 0.1))
        case .wave, .spectrum:
            AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
        default: AnyShapeStyle(Color(hex: cur))
        }
    }
}
