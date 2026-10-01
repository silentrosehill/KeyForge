import SwiftUI
import AppKit

/// App colors, all derived from one base color so any pick stays harmonious (same palette as MP3 Tagger).
struct AppTheme: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double
    /// How strongly the sidebar is tinted (0 = plain see-through, 1 = full).
    var tintStrength: Double = 1

    static let purpleDefault = AppTheme(hex: 0xB23AEE)

    init(hue: Double, saturation: Double, brightness: Double, tintStrength: Double = 1) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness; self.tintStrength = tintStrength
    }

    init(hex: UInt32) {
        let c = NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        self.init(color: c)
    }

    init(color: NSColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        self.init(hue: Double(h), saturation: Double(s), brightness: Double(b))
    }

    private static func wrap(_ h: Double) -> Double { (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }
    private func c(_ dh: Double, s: Double, b: Double) -> Color {
        Color(hue: Self.wrap(hue + dh), saturation: min(max(s, 0), 1), brightness: min(max(b, 0), 1))
    }

    var purple: Color { c(0, s: saturation, b: brightness) }
    var indigo: Color { c(-0.07, s: saturation + 0.08, b: brightness * 0.77) }
    var pink: Color {
        var toPink = 0.966 - hue
        toPink -= toPink.rounded()
        return c(min(max(toPink, -0.185), 0.185), s: saturation * 0.77, b: 1)
    }
    var accent: Color { c(-0.03, s: saturation * 0.87, b: min(brightness + 0.03, 0.96)) }
    var base: Color { purple }

    var sidebarTint: LinearGradient {
        let k = tintStrength
        return LinearGradient(colors: [pink.opacity(0.16 * k), purple.opacity(0.22 * k), indigo.opacity(0.28 * k)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var swatch: LinearGradient {
        LinearGradient(colors: [pink, purple, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func sameColor(as o: AppTheme) -> Bool {
        abs(hue - o.hue) < 0.005 && abs(saturation - o.saturation) < 0.01 && abs(brightness - o.brightness) < 0.01
    }
}

/// The user's chosen theme, saved between launches.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    static let presets: [(name: String, theme: AppTheme)] = [
        ("Purple", .purpleDefault),
        ("Pink", AppTheme(hex: 0xEE3A9A)),
        ("Red", AppTheme(hex: 0xE5484D)),
        ("Orange", AppTheme(hex: 0xF07B2A)),
        ("Gold", AppTheme(hex: 0xD9A521)),
        ("Razer", AppTheme(hex: 0x44D62C)),
        ("Teal", AppTheme(hex: 0x1FB5B0)),
        ("Blue", AppTheme(hex: 0x3A7BEE)),
        ("Graphite", AppTheme(hue: 0.7, saturation: 0.08, brightness: 0.62)),
    ]

    @Published var theme: AppTheme {
        didSet {
            let d = UserDefaults.standard
            d.set(theme.hue, forKey: "themeHue"); d.set(theme.saturation, forKey: "themeSat")
            d.set(theme.brightness, forKey: "themeBri"); d.set(theme.tintStrength, forKey: "themeTint")
        }
    }

    /// 0 = clear glass … 1 = tinted glass (Theme → Glass slider, same as MP3 Tagger).
    @Published var glassTint: Double = UserDefaults.standard.object(forKey: "glassTint") as? Double ?? 0.3 {
        didSet { UserDefaults.standard.set(glassTint, forKey: "glassTint") }
    }

    /// When on, the app's colors follow the active profile's keyboard lighting.
    @Published var matchLighting: Bool = UserDefaults.standard.bool(forKey: "themeMatchLighting") {
        didSet { UserDefaults.standard.set(matchLighting, forKey: "themeMatchLighting") }
    }

    /// What the app actually renders with.
    var rendered: AppTheme {
        guard matchLighting, let t = Self.fromLighting(ProfileStore.shared.active?.lighting ?? .standard) else { return theme }
        var r = t
        r.tintStrength = theme.tintStrength
        return r
    }

    /// Theme for a lighting setting: its color for Solid/Breathing/Reactive; Wave, Spectrum and Off keep the chosen theme.
    static func fromLighting(_ l: Lighting) -> AppTheme? {
        guard l.usesColor else { return nil }
        let c = NSColor(srgbRed: l.red, green: l.green, blue: l.blue, alpha: 1)
        var t = AppTheme(color: c)
        if t.saturation < 0.12 {   // white/grey keys → a soft graphite theme
            return AppTheme(hue: 0.7, saturation: 0.08, brightness: 0.62)
        }
        t.saturation = min(max(t.saturation, 0.45), 0.9)
        t.brightness = min(max(t.brightness, 0.6), 0.95)   // very dark picks stay readable
        return t
    }

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "themeHue") != nil {
            theme = AppTheme(hue: d.double(forKey: "themeHue"), saturation: d.double(forKey: "themeSat"),
                             brightness: d.double(forKey: "themeBri"),
                             tintStrength: d.object(forKey: "themeTint") as? Double ?? 1)
        } else {
            theme = .purpleDefault
        }
    }

    func apply(_ preset: AppTheme) {
        matchLighting = false
        var t = preset
        t.tintStrength = theme.tintStrength
        theme = t
    }

    var customColor: Binding<Color> {
        Binding(get: { self.theme.base },
                set: { new in
                    self.matchLighting = false
                    var t = AppTheme(color: NSColor(new))
                    t.tintStrength = self.theme.tintStrength
                    self.theme = t
                })
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.purpleDefault
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

enum Theme {
    static var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08), .white.opacity(0.35)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Liquid Glass (Apple's system material on macOS 26+, frosted fallback before) — same as MP3 Tagger

private struct InsideGlassKey: EnvironmentKey { static let defaultValue = false }
private struct GlassTintKey: EnvironmentKey { static let defaultValue = 0.3 }
extension EnvironmentValues {
    /// Controls placed on a glass surface draw as plain symbols (Apple avoids glass on glass).
    var insideGlass: Bool {
        get { self[InsideGlassKey.self] }
        set { self[InsideGlassKey.self] = newValue }
    }
    /// 0 = clear glass … 1 = tinted glass.
    var glassTint: Double {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
}

extension View {
    /// Real Liquid Glass in `shape`, following the Clear ↔ Tinted slider. An explicit `tint` (main actions)
    /// always wins; `interactive` makes it light up and flex under the pointer.
    func liquidGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
    }

    /// Groups neighbouring glass controls so they render together and can blend when close.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

private struct LiquidGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.glassTint) private var amount
    @Environment(\.appTheme) private var theme

    private var effectiveTint: Color? {
        if let tint { return tint }
        return amount > 0.02 ? theme.purple.opacity(0.15 + 0.8 * amount * amount) : nil
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(shape.fill(theme.purple.opacity(tint == nil ? 0.45 * amount * amount : 0)))
                .glassEffect(glass, in: shape)
        } else {
            content.background {
                ZStack {
                    shape.fill(.ultraThinMaterial).opacity(0.55 + 0.45 * amount)
                    if let t = effectiveTint { shape.fill(t.opacity(tint == nil ? 1 : 0.6)) }
                }
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = amount < 0.15 && tint == nil ? .clear : .regular
        if let t = effectiveTint { g = g.tint(t) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// A control's surface: Liquid Glass, or — on a glass panel — just a soft press highlight.
private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let plain: Bool
    let pressed: Bool

    func body(content: Content) -> some View {
        if plain {
            content.background(shape.fill(Color.primary.opacity(pressed ? 0.14 : 0)))
        } else {
            content.liquidGlass(shape, tint: tint, interactive: true)
        }
    }
}

/// Liquid Glass capsule button; `prominent` is tinted with the theme color for the main action.
struct PurpleGlassButtonStyle: ButtonStyle {
    var prominent = false
    var icon = false
    var iconSize: CGFloat = 40
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appTheme) private var theme
    @Environment(\.insideGlass) private var insideGlass

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = Capsule()
        return configuration.label
            .font(icon ? .system(size: iconSize * 0.4, weight: .semibold) : .callout.weight(prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, icon ? 0 : 14)
            .padding(.vertical, icon ? 0 : 6)
            .frame(width: icon ? iconSize : nil, height: icon ? iconSize : nil)
            .modifier(GlassSurface(shape: shape, tint: prominent ? theme.purple : nil,
                                   plain: insideGlass && !prominent, pressed: pressed))
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: pressed)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == PurpleGlassButtonStyle {
    static var purpleGlass: PurpleGlassButtonStyle { PurpleGlassButtonStyle() }
    static var purpleGlassProminent: PurpleGlassButtonStyle { PurpleGlassButtonStyle(prominent: true) }
    static func purpleGlassIcon(_ size: CGFloat) -> PurpleGlassButtonStyle { PurpleGlassButtonStyle(icon: true, iconSize: size) }
}

/// A menu drawn as a Liquid Glass capsule (matches the glass buttons).
struct GlassMenuLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 6)
            .liquidGlass(Capsule(), interactive: true)
    }
}

/// Segmented switch whose theme-colored highlight slides between options, on a glass track.
struct GlassSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Namespace private var ns
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let on = value == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { selection = value }
                } label: {
                    Text(title)
                        .font(.callout.weight(on ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background {
                            if on {
                                Capsule().fill(theme.purple.opacity(0.92))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "highlight", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background { Color.clear.liquidGlass(Capsule()) }
    }
}

/// Content card: a calm filled panel (Apple keeps Liquid Glass for floating controls, not content).
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 18
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape.fill(Color.primary.opacity(0.05))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            }
    }
}

/// Popover for picking the app color.
struct ThemePicker: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Theme").font(.headline)

            Toggle(isOn: Binding(get: { store.matchLighting },
                                 set: { on in withAnimation(.easeInOut(duration: 0.4)) { store.matchLighting = on } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Match keyboard lighting")
                    Text("Colors follow your keyboard's RGB").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 5), alignment: .leading, spacing: 10) {
                ForEach(ThemeStore.presets, id: \.name) { preset in
                    let selected = !store.matchLighting && store.theme.sameColor(as: preset.theme)
                    Button {
                        withAnimation(.easeInOut(duration: 0.35)) { store.apply(preset.theme) }
                    } label: {
                        Circle()
                            .fill(preset.theme.swatch)
                            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                                  startPoint: .top, endPoint: .center)))
                            .overlay(Circle().strokeBorder(Theme.rim, lineWidth: 1))
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.4), radius: 2)
                                }
                            }
                            .frame(width: 34, height: 34)
                            .shadow(color: preset.theme.purple.opacity(selected ? 0.7 : 0.35), radius: selected ? 7 : 3, y: 2)
                            .scaleEffect(selected ? 1.08 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Glass").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Clear").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $store.glassTint, in: 0...1)
                        .controlSize(.small)
                        .help("How the app's Liquid Glass looks: clear and see-through, or frosted and tinted with your color")
                    Text("Tinted").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Custom color")
                Spacer()
                ColorPicker("Custom color", selection: store.customColor, supportsOpacity: false)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sidebar tint")
                    Spacer()
                    Text("\(Int(store.theme.tintStrength * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { store.theme.tintStrength },
                                      set: { store.theme.tintStrength = $0 }), in: 0...2)
            }

            Button("Reset to Purple") {
                withAnimation(.easeInOut(duration: 0.35)) { store.matchLighting = false; store.theme = .purpleDefault }
            }
            .buttonStyle(.purpleGlass)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 262)
        .environment(\.appTheme, store.rendered)
        .environment(\.glassTint, store.glassTint)
        .tint(store.rendered.accent)
    }
}
