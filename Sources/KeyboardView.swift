import SwiftUI
import AppKit

/// Keys lit up right now (the "try it" highlight), and key recording for the target picker.
@MainActor
final class LiveKeys: ObservableObject {
    static let shared = LiveKeys()
    @Published private(set) var down: Set<Usage> = []
    /// While set, the next key press is handed here instead of being shown.
    @Published var recorder: ((Usage) -> Void)?
    /// While set, the next key combination (with ⌘⌥⌃⇧) is handed here — for shortcut actions.
    @Published var shortcutRecorder: ((Shortcut) -> Void)?
    private var monitor: Any?

    func install(iso: @escaping () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak self] e in
            guard let self else { return e }
            // leave text fields, sheets and alerts alone
            if e.window?.sheetParent != nil || e.window is NSPanel { return e }
            if e.type == .keyDown, let rec = self.shortcutRecorder {
                if e.keyCode == 53 && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    self.shortcutRecorder = nil   // Esc cancels
                } else {
                    rec(Shortcut(event: e)); self.shortcutRecorder = nil
                }
                return nil
            }
            if e.window?.firstResponder is NSText { return e }
            if e.type == .keyDown, e.modifierFlags.contains(.command) { return e }   // ⌘Q, ⌘W, … keep working

            switch e.type {
            case .systemDefined:
                guard e.subtype.rawValue == 8 else { return e }
                let code = (e.data1 & 0xFFFF0000) >> 16, isDown = (e.data1 & 0xFF00) >> 8 == 0xA
                guard let u = Keys.consumer(nxKey: code) else { return e }
                if isDown, let r = self.recorder { r(u); self.recorder = nil }
                self.set(u, isDown)
                return e
            case .flagsChanged:
                guard let u = Keys.usage(forVK: Int(e.keyCode), iso: iso()) else { return e }
                let bit = Keys.modifierFlag[Int(e.keyCode)] ?? 0
                let isDown = e.modifierFlags.rawValue & bit != 0
                if e.keyCode == 57 { self.flash(u) } else { self.set(u, isDown) }   // Caps Lock only reports toggles
                if isDown, let r = self.recorder { r(u); self.recorder = nil }
                return e
            default:
                guard let u = Keys.usage(forVK: Int(e.keyCode), iso: iso()) else { return nil }
                if e.type == .keyDown, !e.isARepeat, let r = self.recorder { r(u); self.recorder = nil }
                self.set(u, e.type == .keyDown)
                return nil   // no beep
            }
        }
    }

    private func set(_ u: Usage, _ isDown: Bool) {
        if isDown { down.insert(u) } else { down.remove(u) }
    }

    private func flash(_ u: Usage) {
        down.insert(u)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.down.remove(u) }
    }

    func clear() { down = [] }
}

/// The Huntsman V2 drawn to scale; click a key to select it.
struct KeyboardView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var live = LiveKeys.shared
    @Binding var selected: Usage?
    /// When set, the keys preview the lighting instead of the key changes.
    var lighting: Lighting? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        let keys = Keys.layout(store.layout, iso: store.iso)
        let size = Keys.bounds(keys)
        let map = store.active?.map ?? [:]
        GeometryReader { geo in
            let pad: CGFloat = 18
            let unit = min((geo.size.width - pad * 2) / size.w, (geo.size.height - pad * 2) / size.h, 54)
            let w = unit * size.w + pad * 2, h = unit * size.h + pad * 2
            ZStack(alignment: .topLeading) {
                KeyboardCase(theme: theme, glow: lighting.map { LEDPreview.glow($0) })
                if let lighting {
                    // Lighting preview: the keys can't be clicked here, so draw the whole keyboard in one
                    // Canvas instead of 100+ live key views (those re-laid out on every color change and lagged).
                    LightingKeys(keys: keys, lighting: lighting, iso: store.iso, lit: live.down, unit: unit, pad: pad, pink: theme.pink)
                        .frame(width: w, height: h)
                        .allowsHitTesting(false)
                    if lighting.effect == .perKey {
                        // paint: click or drag across keys (⌥ erases)
                        Color.clear
                            .frame(width: w, height: h)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                                let p = CGPoint(x: (g.location.x - pad) / unit, y: (g.location.y - pad) / unit)
                                guard let k = keys.first(where: { p.x >= $0.x && p.x < $0.x + $0.w && p.y >= $0.y && p.y < $0.y + $0.h })
                                else { return }
                                PaintBrush.shared.paint(k.usage, erase: NSEvent.modifierFlags.contains(.option), store: store)
                            })
                            .onHover { inside in
                                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                            }
                    }
                } else {
                ForEach(keys) { k in
                    KeyCap(key: k, unit: unit, iso: store.iso,
                           target: map[k.usage],
                           action: store.active?.actions[k.usage],
                           selected: selected == k.usage && !k.fixed,
                           lit: live.down.contains(k.usage),
                           enabled: store.enabled)
                        .frame(width: k.w * unit, height: k.h * unit)
                        .offset(x: pad + k.x * unit, y: pad + k.y * unit)
                        .onTapGesture {
                            guard !k.fixed else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selected = selected == k.usage ? nil : k.usage
                            }
                        }
                        .help(k.fixed ? "Fn is handled inside the keyboard and can't be changed" : Keys.name(k.usage, iso: store.iso))
                }
                }
                // Razer-style logo strip
                if store.layout == .huntsman {
                Text("RAZER")
                    .font(.system(size: max(unit * 0.2, 8), weight: .heavy)).tracking(3)
                    .foregroundStyle(theme.pink.opacity(0.55))
                    .offset(x: pad + 18.6 * unit, y: pad + 1.0 * unit - max(unit * 0.2, 8) * 0.2)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio((size.w + 1.2) / (size.h + 1.2), contentMode: .fit)
    }
}

/// The Lighting tab's keyboard: glow + keycaps + legends, all drawn in one pass.
private struct LightingKeys: View {
    let keys: [KeyDef]
    let lighting: Lighting
    let iso: Bool
    let lit: Set<Usage>
    let unit: CGFloat
    let pad: CGFloat
    let pink: Color

    var body: some View {
        let geo = KeyGeometry(unit: unit, pad: pad)
        ZStack {
            // colors that can change 25×/s live in their own views (they watch the live frame)…
            if lighting.effect != .off { LEDGlow(keys: keys, lighting: lighting, geo: geo) }
            // …keycaps and labels are drawn once per real change
            KeyTops(keys: keys, lighting: lighting, iso: iso, lit: lit, geo: geo, pink: pink)
            if lighting.effect.isLive { LEDTint(keys: keys, lighting: lighting, geo: geo) }
        }
    }
}

private struct KeyGeometry {
    let unit: CGFloat
    let pad: CGFloat

    func rect(_ k: KeyDef) -> CGRect {
        CGRect(x: pad + k.x * unit, y: pad + k.y * unit, width: k.w * unit, height: k.h * unit)
    }

    func cap(_ k: KeyDef) -> CGRect { rect(k).insetBy(dx: max(unit * 0.05, 1.5), dy: max(unit * 0.05, 1.5)) }

    func path(_ k: KeyDef, _ r: CGRect) -> Path {
        switch k.shape {
        case .isoEnter: return ISOEnterShape(unit: unit).path(in: r)
        case .round: return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
        case .normal: return Path(roundedRect: r, cornerRadius: max(unit * 0.14, 4), style: .continuous)
        }
    }
}

/// LED color of a key: KeyForge's own frame when it draws the colors, else the effect's preview color.
@MainActor
private func ledColor(_ k: KeyDef, _ lighting: Lighting, _ frame: [Usage: UInt32]?) -> Color? {
    if let frame {
        guard let h = frame[k.usage], h != 0 else { return nil }
        return Color(hex: h).opacity(0.35 + 0.65 * lighting.brightness)
    }
    return LEDPreview.color(lighting, x: k.x / Keys.layoutWidth, key: k.usage)
}

/// Every key's underglow drawn once and blurred once.
private struct LEDGlow: View {
    let keys: [KeyDef]
    let lighting: Lighting
    let geo: KeyGeometry
    @ObservedObject private var live = LightingEngine.shared.live

    var body: some View {
        let frame = live.frame
        Canvas { ctx, _ in
            for k in keys {
                guard let c = ledColor(k, lighting, frame) else { continue }
                ctx.fill(Path(roundedRect: geo.rect(k).insetBy(dx: -2, dy: -2), cornerRadius: geo.unit * 0.18), with: .color(c))
            }
        }
        .blur(radius: 7)
        .opacity(0.6)
    }
}

/// Live effects: the key tops light up in the frame's colors (the labels underneath stay put).
private struct LEDTint: View {
    let keys: [KeyDef]
    let lighting: Lighting
    let geo: KeyGeometry
    @ObservedObject private var live = LightingEngine.shared.live

    var body: some View {
        let frame = live.frame
        Canvas { ctx, _ in
            for k in keys {
                guard let c = ledColor(k, lighting, frame) else { continue }
                ctx.fill(geo.path(k, geo.cap(k)), with: .color(c.opacity(0.32)))
            }
        }
        .blendMode(.plusLighter)
    }
}

/// Keycaps and their labels (labels take the LED color for built-in effects, white for live ones).
private struct KeyTops: View {
    let keys: [KeyDef]
    let lighting: Lighting
    let iso: Bool
    let lit: Set<Usage>
    let geo: KeyGeometry
    let pink: Color

    var body: some View {
        let live = lighting.effect.isLive
        let unit = geo.unit
        Canvas { ctx, _ in
            let skirt = GraphicsContext.Shading.color(Color(white: 0.04))
            let edge = GraphicsContext.Shading.color(.white.opacity(0.08))
            for k in keys {
                let r = geo.cap(k)
                let down = lit.contains(k.usage)
                let top = r.offsetBy(dx: 0, dy: down ? 1.5 : 0)
                let path = geo.path(k, top)
                ctx.fill(geo.path(k, r.offsetBy(dx: 0, dy: down ? 0 : 1.5)), with: skirt)
                let colors: [Color] = down ? [pink.opacity(0.95), pink.opacity(0.6)] : [Color(white: 0.2), Color(white: 0.12)]
                ctx.fill(path, with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: top.midX, y: top.minY),
                                                      endPoint: CGPoint(x: top.midX, y: top.maxY)))
                ctx.stroke(path, with: edge, lineWidth: 1)

                let led = (live ? nil : ledColor(k, lighting, nil)) ?? .white.opacity(k.fixed ? 0.35 : 0.9)
                let l = Keys.legend(k.usage, iso: iso)
                var center = CGPoint(x: top.midX, y: top.midY)
                if k.shape == .isoEnter { center = CGPoint(x: top.midX + unit * 0.12, y: top.minY + unit * 0.5) }
                let size: CGFloat = l.main.count <= 2 ? max(unit * 0.32, 9) : max(unit * 0.21, 7.5)
                var main = ctx.resolve(Text(l.main).font(.system(size: size, weight: .semibold)).foregroundColor(led))
                var m = main.measure(in: CGSize(width: 1000, height: 100))
                if m.width > top.width - 6 {   // shrink long legends to fit, like minimumScaleFactor
                    let f = max(0.5, (top.width - 6) / m.width)
                    main = ctx.resolve(Text(l.main).font(.system(size: size * f, weight: .semibold)).foregroundColor(led))
                    m = main.measure(in: CGSize(width: 1000, height: 100))
                }
                if let t = l.top {
                    let small = ctx.resolve(Text(t).font(.system(size: max(unit * 0.2, 7), weight: .medium)).foregroundColor(led.opacity(0.7)))
                    let sm = small.measure(in: CGSize(width: 1000, height: 100))
                    let total = sm.height + m.height
                    ctx.draw(small, at: CGPoint(x: center.x, y: center.y - total / 2 + sm.height / 2))
                    ctx.draw(main, at: CGPoint(x: center.x, y: center.y + total / 2 - m.height / 2))
                } else {
                    ctx.draw(main, at: center)
                }
            }
        }
    }
}

/// What the lighting looks like on screen (colors per key position).
enum LEDPreview {
    static func color(_ l: Lighting, x: Double, key: Usage = 0) -> Color? {
        switch l.effect {
        case .off: return nil
        case .perKey:
            let h = l.hex(for: key)
            return h == 0 ? nil : Color(hex: h).opacity(0.35 + 0.65 * l.brightness)
        case .wave, .spectrum: return Color(hue: l.effect == .wave ? x * 0.85 : 0.0 + x * 0.85, saturation: 1, brightness: 1)
            .opacity(0.35 + 0.65 * l.brightness)
        default: return l.color.opacity(0.35 + 0.65 * l.brightness)
        }
    }

    static func glow(_ l: Lighting) -> AnyShapeStyle {
        switch l.effect {
        case .off: AnyShapeStyle(Color.clear)
        case .wave, .spectrum: AnyShapeStyle(LinearGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple],
                                                            startPoint: .leading, endPoint: .trailing).opacity(l.brightness))
        case .perKey: AnyShapeStyle(Color(hex: l.baseHex).opacity(l.brightness * 0.6))
        case .ripple, .rain, .heatmap, .cover, .music: AnyShapeStyle(Color(hex: l.baseHex).opacity(l.brightness * 0.3))
        default: AnyShapeStyle(l.color.opacity(l.brightness))
        }
    }
}

private struct KeyboardCase: View {
    let theme: AppTheme
    var glow: AnyShapeStyle? = nil
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .background(
                shape.fill(glow ?? AnyShapeStyle(Color.clear)).blur(radius: 26).opacity(0.55).padding(6)
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
    }
}

/// ISO Enter: wide on the top row, narrower below.
struct ISOEnterShape: Shape {
    let unit: CGFloat
    func path(in r: CGRect) -> Path {
        let inset = 0.25 * unit, rad: CGFloat = 6
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + rad), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + inset + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + inset, y: r.maxY - rad), control: CGPoint(x: r.minX + inset, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + inset, y: r.midY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + inset - rad, y: r.midY), control: CGPoint(x: r.minX + inset, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY - rad), control: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct KeyCap: View {
    let key: KeyDef
    let unit: CGFloat
    let iso: Bool
    let target: Usage?
    /// shortcut / text / app / macro on this key
    var action: KeyAction? = nil
    let selected: Bool
    let lit: Bool
    let enabled: Bool
    @StateObject private var hover = HoverState()
    @Environment(\.appTheme) private var theme

    private var shape: AnyShape {
        switch key.shape {
        case .isoEnter: AnyShape(ISOEnterShape(unit: unit))
        case .round: AnyShape(Capsule())
        case .normal: AnyShape(RoundedRectangle(cornerRadius: max(unit * 0.14, 4), style: .continuous))
        }
    }

    var body: some View {
        ZStack {
            capBody
            legends
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 3)
                .offset(x: key.shape == .isoEnter ? unit * 0.12 : 0,
                        y: (lit ? 1.5 : 0) + (key.shape == .isoEnter ? -unit * 0.45 : 0))
        }
        .padding(max(unit * 0.05, 1.5))
        .contentShape(shape)
        .scaleEffect(hover.on && !key.fixed ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hover.on)
        .animation(.easeOut(duration: 0.08), value: lit)
        .onHover { hover.on = $0 }
        .zIndex(selected || hover.on ? 1 : 0)
    }

    /// Darker skirt + lighter top surface.
    private var capBody: some View {
        let remapped = target != nil || action != nil
        let radius: CGFloat = selected || lit ? 9 : (remapped ? 5 : 0)
        return ZStack {
            shape.fill(Color(white: 0.04)).offset(y: lit ? 0 : 1.5)
            shape
                .fill(LinearGradient(colors: capColors(remapped), startPoint: .top, endPoint: .bottom))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)))
                .overlay(shape.stroke(borderColor(remapped), lineWidth: selected ? 2 : 1).padding(selected ? 1 : 0.5))
                .shadow(color: glowColor(remapped), radius: radius)
                .offset(y: lit ? 1.5 : 0)
        }
    }

    @ViewBuilder private var legends: some View {
        let legend: (main: String, top: String?) = key.label.map { ($0, nil) } ?? Keys.legend(key.usage, iso: iso)
        if let action, key.shape != .round {
            VStack(spacing: 2) {
                Text(legend.main)
                    .font(.system(size: max(unit * 0.17, 7), weight: .medium))
                    .strikethrough(true, color: Color.white.opacity(0.35))
                    .foregroundStyle(Color.white.opacity(0.45))
                Image(systemName: action.icon)
                    .font(.system(size: max(unit * 0.26, 9), weight: .bold))
                    .foregroundStyle(Color.white)
            }
        } else if let target, key.shape != .round {
            let t = Keys.legend(target, iso: iso).main
            VStack(spacing: 1) {
                Text(legend.main)
                    .font(.system(size: max(unit * 0.17, 7), weight: .medium))
                    .strikethrough(true, color: Color.white.opacity(0.35))
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(t)
                    .font(.system(size: fontSize(t), weight: .bold))
                    .foregroundStyle(Color.white)
                    .shadow(color: theme.pink.opacity(0.8), radius: 4)
            }
        } else {
            let main = target.map { Keys.legend($0, iso: iso).main } ?? legend.main
            let mainColor: Color = key.fixed ? Color.white.opacity(0.35) : Color.white.opacity(0.92)
            VStack(spacing: 1) {
                if let top = legend.top, target == nil {
                    Text(top).font(.system(size: max(unit * 0.2, 7), weight: .medium)).foregroundStyle(Color.white.opacity(0.6))
                }
                Text(main)
                    .font(.system(size: fontSize(main), weight: .semibold))
                    .foregroundStyle(mainColor)
                if key.label == nil, let hint = Keys.macHint[key.usage] {
                    Text(hint).font(.system(size: max(unit * 0.2, 7))).foregroundStyle(theme.pink.opacity(0.9))
                }
            }
        }
    }

    private func fontSize(_ s: String) -> CGFloat {
        s.count <= 2 ? max(unit * 0.32, 9) : max(unit * 0.21, 7.5)
    }

    private func capColors(_ remapped: Bool) -> [Color] {
        if lit { return [theme.pink.opacity(0.95), theme.purple] }
        if selected { return [theme.purple.opacity(0.95), theme.indigo] }
        if remapped && enabled { return [theme.purple.opacity(0.55), theme.indigo.opacity(0.55)] }
        if remapped { return [Color(white: 0.28), Color(white: 0.2)] }
        return hover.on && !key.fixed ? [Color(white: 0.26), Color(white: 0.17)] : [Color(white: 0.2), Color(white: 0.12)]
    }

    private func borderColor(_ remapped: Bool) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(Theme.rim) }
        if remapped && enabled { return AnyShapeStyle(theme.pink.opacity(0.7)) }
        return AnyShapeStyle(Color.white.opacity(0.08))
    }

    private func glowColor(_ remapped: Bool) -> Color {
        if lit { return theme.pink.opacity(0.9) }
        if selected { return theme.purple.opacity(0.9) }
        return remapped && enabled ? theme.purple.opacity(0.6) : .clear
    }
}

/// Hover flag kept in a class (the @State macro isn't available with the Command Line Tools).
final class HoverState: ObservableObject {
    @Published var on = false
}
