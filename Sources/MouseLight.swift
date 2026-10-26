import SwiftUI
import AppKit

@_silgen_name("razer_send_to")
private func razer_send_to(_ vendor: Int32, _ product: Int32, _ iface: Int32, _ tid: UInt8,
                           _ cls: UInt8, _ cmd: UInt8, _ size: UInt8, _ args: UnsafePointer<UInt8>?) -> Int32
@_silgen_name("usb_output_report")
private func usb_output_report(_ vendor: Int32, _ product: Int32, _ iface: Int32, _ buf: UnsafePointer<UInt8>?, _ len: Int32) -> Int32
@_silgen_name("usb_present")
private func usb_present(_ vendor: Int32, _ product: Int32) -> Int32

/// A profile's mouse lighting (nil on a profile = KeyForge leaves the mouse's lights alone).
struct MouseLighting: Codable, Equatable {
    enum Effect: String, Codable, CaseIterable {
        case sync, solid, zones, breathing, cycle, wave, off

        var title: String {
            switch self {
            case .sync: "Sync"
            case .solid: "Solid"
            case .zones: "Per Zone"
            case .breathing: "Breathing"
            case .cycle: "Cycle"
            case .wave: "Wave"
            case .off: "Off"
            }
        }
    }
    var effect: Effect = .sync
    var color: UInt32 = 0xB23AEE
    /// G203 LIGHTSYNC: left, middle, right
    var zones: [UInt32] = [0xFF2E97, 0x9D4EDD, 0x00F0FF]
    var brightness = 1.0
    /// 0 slow … 1 fast
    var speed = 0.5

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        effect = (try? c.decodeIfPresent(Effect.self, forKey: .effect)) ?? .sync
        color = try c.decodeIfPresent(UInt32.self, forKey: .color) ?? color
        zones = try c.decodeIfPresent([UInt32].self, forKey: .zones) ?? zones
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
    }

    var usesColor: Bool { effect == .solid || effect == .breathing }

    /// What "Sync" means right now: the keyboard's effect translated for a mouse.
    func resolved(keyboard k: Lighting?) -> MouseLighting {
        guard effect == .sync else { return self }
        var m = self
        guard let k else { m.effect = .solid; return m }
        m.brightness = k.brightness
        m.color = k.baseHex
        switch k.effect {
        case .off: m.effect = .off
        case .breathing: m.effect = .breathing
        case .wave: m.effect = .wave
        case .spectrum: m.effect = .cycle
        case .perKey:
            // the colors of the keys under your hand (left, middle, right of the board)
            m.effect = .zones
            m.zones = [0x7_0000_0004, 0x7_0000_000A, 0x7_0000_000F].map { k.hex(for: $0) }
            m.color = m.zones[1]
        default: m.effect = .solid
        }
        return m
    }

    /// The colors shown on the on-screen mouse.
    var previewColors: [Color] {
        switch effect {
        case .off: [Color(white: 0.15)]
        case .zones: zones.map { Color(hex: $0) }
        case .cycle, .wave: [.red, .yellow, .green, .cyan, .blue, .purple]
        default: [Color(hex: color)]
        }
    }
}

/// The mice KeyForge can light.
struct LightableMouse: Identifiable, Hashable {
    enum Kind { case logitechG203, razer }
    let name: String
    let vendor: Int
    let product: Int
    let kind: Kind
    var zoneCount: Int { kind == .logitechG203 ? 3 : 1 }
    var id: String { String(format: "%04x:%04x", vendor, product) }

    static let all: [LightableMouse] = [
        LightableMouse(name: "Logitech G203 LIGHTSYNC", vendor: 0x046D, product: 0xC092, kind: .logitechG203),
        LightableMouse(name: "Razer Viper Ultimate", vendor: 0x1532, product: 0x007A, kind: .razer),
        LightableMouse(name: "Razer Viper Ultimate (wireless)", vendor: 0x1532, product: 0x007B, kind: .razer),
        LightableMouse(name: "Razer Mouse Dock", vendor: 0x1532, product: 0x007E, kind: .razer),
    ]

    static var connected: [LightableMouse] { all.filter { usb_present(Int32($0.vendor), Int32($0.product)) != 0 } }
}

/// Sends mouse lighting on a background queue; re-sends when a supported mouse is plugged in.
@MainActor
final class MouseLightController: ObservableObject {
    static let shared = MouseLightController()
    @Published private(set) var connected: [LightableMouse] = []
    private var current: MouseLighting?
    private var keyboard: Lighting?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "keyforge.mouselight")

    func start() {
        guard timer == nil else { return }
        connected = LightableMouse.connected
        // mice come and go (wireless dongles, docks): look every few seconds, re-apply to newcomers
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = LightableMouse.connected
                let added = now.filter { !self.connected.contains($0) }
                if now != self.connected { self.connected = now }
                if !added.isEmpty { self.send(to: added) }
            }
        }
    }

    func apply(_ m: MouseLighting?, keyboard k: Lighting?) {
        start()
        let changed = m != current || (m?.effect == .sync && k != keyboard)
        current = m; keyboard = k
        if changed { send(to: connected) }
    }

    private func send(to mice: [LightableMouse]) {
        guard let m = current?.resolved(keyboard: keyboard), !mice.isEmpty else { return }
        if ProcessInfo.processInfo.environment["KEYFORGE_DRY"] != nil { return }
        queue.async {
            for mouse in mice {
                switch mouse.kind {
                case .logitechG203: Self.g203(mouse, m)
                case .razer: Self.razer(mouse, m)
                }
            }
        }
    }

    private nonisolated static func rgb(_ hex: UInt32, _ k: Double) -> [UInt8] {
        let s = Color.scale(hex, max(0, min(1, k)))
        return [UInt8(s >> 16 & 0xFF), UInt8(s >> 8 & 0xFF), UInt8(s & 0xFF)]
    }

    // MARK: Logitech G203 LIGHTSYNC (OpenRGB's LogitechG203LController)

    private nonisolated static func g203(_ d: LightableMouse, _ m: MouseLighting) {
        func send(_ bytes: [UInt8]) {
            var b = bytes + [UInt8](repeating: 0, count: max(0, 20 - bytes.count))
            _ = b.withUnsafeMutableBufferPointer { usb_output_report(Int32(d.vendor), Int32(d.product), 1, $0.baseAddress, 20) }
            usleep(15000)
        }
        // speed is a period in ms: 20000 slow … 1000 fast
        let ms = Int(20000 - m.speed * 19000)
        let hi = UInt8(ms >> 8 & 0xFF), lo = UInt8(ms & 0xFF)
        let pct = UInt8(max(1, min(100, Int(m.brightness * 100))))
        let c = rgb(m.color, 1)
        var p: [UInt8] = [0x11, 0xFF, 0x0E, 0x10, 0x00]
        switch m.effect {
        case .zones:
            send([0x11, 0xFF, 0x0E, 0x50, 0x01, 0x03, 0x07])            // software control (direct mode)
            let z = (0..<3).map { rgb(m.zones[min($0, m.zones.count - 1)], m.brightness) }
            let frame: [UInt8] = [0x11, 0xFF, 0x12, 0x10, 0x01] + z[0] + [0x02] + z[1] + [0x03] + z[2] + [0xFF]
            for _ in 0..<2 { send(frame); send([0x11, 0xFF, 0x12, 0x70]) }   // twice: OpenRGB's fix for color lag
            return
        case .off:
            p += [0x00]
        case .solid, .sync:
            p += [0x01] + rgb(m.color, m.brightness) + [0x02]
        case .breathing:
            p += [0x04] + c + [hi, lo, 0x00, pct]
        case .cycle:
            p += [0x02] + c + [0x00, 0x00, hi, lo, pct]
        case .wave:
            p += [0x03] + c + [0x00, 0x00, lo, 0x01, pct, hi]
        }
        while p.count < 16 { p.append(0) }
        p.append(0x01)                                                     // end byte at 0x10
        send(p)
    }

    // MARK: Razer mice and docks (same extended-matrix commands as the keyboard, interface 0, id 0x3F)

    private nonisolated static func razer(_ d: LightableMouse, _ m: MouseLighting) {
        func cmd(_ cls: UInt8, _ id: UInt8, _ args: [UInt8]) {
            _ = args.withUnsafeBufferPointer {
                razer_send_to(Int32(d.vendor), Int32(d.product), 0, 0x3F, cls, id, UInt8(args.count), $0.baseAddress)
            }
        }
        let c = rgb(m.color, 1)
        switch m.effect {
        case .off: cmd(0x0F, 0x02, [0x01, 0x05, 0x00, 0x00, 0x00, 0x00])
        case .solid, .sync: cmd(0x0F, 0x02, [0x01, 0x05, 0x01, 0x00, 0x00, 0x01] + c)
        case .zones: cmd(0x0F, 0x02, [0x01, 0x05, 0x01, 0x00, 0x00, 0x01] + rgb(m.zones.first ?? m.color, 1))
        case .breathing: cmd(0x0F, 0x02, [0x01, 0x05, 0x02, 0x01, 0x00, 0x01] + c)
        case .cycle, .wave: cmd(0x0F, 0x02, [0x01, 0x05, 0x03, 0x00, 0x00, 0x00])
        }
        cmd(0x0F, 0x04, [0x01, 0x05, UInt8(max(0, min(255, m.brightness * 255)))])
    }
}

// MARK: - The card in the Mouse tab

struct MouseLightingCard: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject private var mice = MouseLightController.shared
    @ObservedObject private var saved = SavedColors.shared
    @StateObject private var zone = ZonePick()
    @Environment(\.appTheme) private var theme

    final class ZonePick: ObservableObject { @Published var index = 0 }

    private var ml: MouseLighting? { store.active?.mouseLighting }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "light.max").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mouse Lighting").font(.headline)
                        Text(mice.connected.isEmpty ? "No supported mouse connected (Logitech G203 LIGHTSYNC, Razer Viper Ultimate, Razer Mouse Dock)"
                             : mice.connected.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("Mouse lighting", isOn: Binding(get: { ml != nil },
                                                           set: { on in withAnimation { store.setMouseLighting(on ? MouseLighting() : nil) } }))
                        .toggleStyle(.switch).labelsHidden()
                        .help("Off: KeyForge leaves your mouse's lights as they are in this profile")
                }

                if let ml {
                    GlassSegmented(selection: Binding(get: { ml.effect }, set: { e in var n = ml; n.effect = e; store.setMouseLighting(n) }),
                                   options: MouseLighting.Effect.allCases.map { ($0, $0.title) })

                    switch ml.effect {
                    case .sync:
                        Label("Copies your keyboard: its color and effect, and it follows profile and Game Mode switches. Per Key boards light the 3 zones with the keys under your hand.",
                              systemImage: "link")
                            .font(.callout).foregroundStyle(.secondary)
                    case .solid, .breathing:
                        colorRow(ml.color) { c in var n = ml; n.color = c; store.setMouseLighting(n) }
                    case .zones:
                        HStack(spacing: 10) {
                            ForEach(0..<3, id: \.self) { i in
                                Button { zone.index = i } label: {
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 6).fill(Color(hex: ml.zones[i])).frame(width: 54, height: 22)
                                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(zone.index == i ? Color.primary : .clear, lineWidth: 2))
                                        Text(["Left", "Middle", "Right"][i]).font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        colorRow(ml.zones[zone.index]) { c in var n = ml; n.zones[zone.index] = c; store.setMouseLighting(n) }
                        Text("Per Zone is for the G203 (3 zones); single-light mice use the left color.").font(.caption).foregroundStyle(.secondary)
                    case .cycle, .wave:
                        sliderRow("Speed", "tortoise", "hare", value: ml.speed) { v in var n = ml; n.speed = v; store.setMouseLighting(n) }
                    case .off:
                        Text("The mouse's lights are off.").font(.callout).foregroundStyle(.secondary)
                    }
                    if ml.effect == .breathing {
                        sliderRow("Speed", "tortoise", "hare", value: ml.speed) { v in var n = ml; n.speed = v; store.setMouseLighting(n) }
                    }
                    if ml.effect != .off && ml.effect != .sync {
                        sliderRow("Brightness", "sun.min", "sun.max.fill", value: ml.brightness) { v in var n = ml; n.brightness = v; store.setMouseLighting(n) }
                    }
                }
            }
        }
        .onAppear { mice.start() }
    }

    private func colorRow(_ current: UInt32, set: @escaping (UInt32) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(LightingCard.swatches + saved.colors.map { ("Saved", $0) }, id: \.1) { s in
                Button { set(s.1) } label: {
                    Circle().fill(Color(hex: s.1)).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(current == s.1 ? Color.primary : Color.primary.opacity(0.15), lineWidth: current == s.1 ? 2.5 : 0.5))
                }
                .buttonStyle(.plain)
            }
            Button {
                NSColorSampler().show { picked in if let picked { set(Color(nsColor: picked).hex) } }
            } label: { Image(systemName: "eyedropper") }
            .buttonStyle(.purpleGlassIcon(30))
            .help("Pick a color from your screen")
            ColorPicker("Custom", selection: Binding(get: { Color(hex: current) }, set: { set($0.hex) }), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func sliderRow(_ title: String, _ lo: String, _ hi: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Image(systemName: lo).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
            Image(systemName: hi).foregroundStyle(.secondary)
        }
    }
}
