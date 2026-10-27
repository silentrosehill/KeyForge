import SwiftUI
import AppKit

/// The light and glass palette of the KeyForge keycap icon.
enum ForgePalette {
    static let amber = Color(hex: 0xFFB05A)
    static let rose = Color(hex: 0xFF648F)
    static let violet = Color(hex: 0xA775FF)
    static let background = Color(hex: 0x0D0D13)
    static let surface = Color(hex: 0x1A1922)
    static var spectrum: LinearGradient {
        LinearGradient(colors: [amber, rose, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A system material behind the window, with a separate readable content layer.
private struct NativeWindowBackdrop: NSViewRepresentable {
    final class MaterialView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
    }

    func makeNSView(context: Context) -> MaterialView {
        let view = MaterialView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: MaterialView, context: Context) {}
}

struct ForgeBackdrop: View {
    @Environment(\.glassOpacity) private var opacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if !reduceTransparency { NativeWindowBackdrop() }
            Color(nsColor: .windowBackgroundColor)
                .opacity(reduceTransparency ? 1 : 0.3 + 0.7 * opacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Standard content surfaces, distinct from the glass controls above them.
struct ForgePanel: View {
    var cornerRadius: CGFloat = 16
    var emphasized = false
    @Environment(\.glassOpacity) private var opacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if !reduceTransparency {
                shape.fill(.regularMaterial).opacity(0.25 + 0.45 * opacity)
            }
            shape.fill(Color(nsColor: .controlBackgroundColor)
                .opacity(reduceTransparency ? 1 : (emphasized ? 0.25 : 0.16) + 0.55 * opacity))
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.2 : 0.065), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
    }
}

/// App colors, all derived from one base color so any pick stays harmonious (same palette as MP3 Tagger).
struct AppTheme: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double
    /// How strongly the sidebar is tinted (0 = plain see-through, 1 = full).
    var tintStrength: Double = 1

    static let purpleDefault = AppTheme(hex: 0xB23AEE)
    static let forgeDefault = AppTheme(hex: 0xA775FF)

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
    var forgeGlow: LinearGradient { ForgePalette.spectrum }

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
        ("Forge", .forgeDefault),
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

    @Published var glassOpacity: Double = min(max(UserDefaults.standard.object(forKey: "glassOpacity") as? Double ?? 0.7, 0), 1) {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: "glassOpacity") }
    }

    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearanceMode") }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
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
            theme = .forgeDefault
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
    static let defaultValue = AppTheme.forgeDefault
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
private struct GlassOpacityKey: EnvironmentKey { static let defaultValue = 0.7 }
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
    var glassOpacity: Double {
        get { self[GlassOpacityKey.self] }
        set { self[GlassOpacityKey.self] = newValue }
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
    @Environment(\.glassOpacity) private var opacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appTheme) private var theme

    private var effectiveTint: Color? {
        if let tint { return tint.opacity(0.5) }
        return amount > 0.02 ? theme.accent.opacity(amount * 0.3) : nil
    }

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else if #available(macOS 26.0, *) {
                shape.fill(.clear).glassEffect(glass, in: shape).opacity(opacity)
            } else {
                shape.fill(.regularMaterial).opacity(opacity)
                    .overlay(shape.fill((effectiveTint ?? .clear).opacity(opacity)))
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var value = Glass.regular
        if let tint = effectiveTint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
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
        let shape = RoundedRectangle(cornerRadius: icon ? iconSize * 0.3 : 9, style: .continuous)
        return configuration.label
            .font(icon ? .system(size: iconSize * 0.4, weight: .semibold) : .callout.weight(prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.primary))
            .padding(.horizontal, icon ? 0 : 12)
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
            .padding(.horizontal, 12).padding(.vertical, 6)
            .liquidGlass(RoundedRectangle(cornerRadius: 9, style: .continuous), interactive: true)
    }
}

/// Segmented switch whose theme-colored highlight slides between options, on a glass track.
struct GlassSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].1).tag(options[index].0)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
    }
}

/// Content card: a calm filled panel (Apple keeps Liquid Glass for floating controls, not content).
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .background(ForgePanel(cornerRadius: cornerRadius))
    }
}

/// Popover for picking the app color.
struct ThemePicker: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance").font(.headline)
            Picker("Appearance", selection: $store.appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .labelsHidden().pickerStyle(.segmented)

            Divider()
            HStack {
                Text("Accent color").font(.callout)
                Spacer()
                ColorPicker("Accent color", selection: store.customColor, supportsOpacity: false).labelsHidden()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 5), alignment: .leading, spacing: 10) {
                ForEach(ThemeStore.presets, id: \.name) { preset in
                    let selected = !store.matchLighting && store.theme.sameColor(as: preset.theme)
                    Button { store.apply(preset.theme) } label: {
                        Circle().fill(preset.theme.purple)
                            .frame(width: 24, height: 24).padding(4)
                            .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.75) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain).help(preset.name)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            Toggle("Match keyboard lighting", isOn: $store.matchLighting)
                .toggleStyle(.switch).controlSize(.small)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Glass opacity").font(.callout)
                    Spacer()
                    Text("\(Int((store.glassOpacity * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $store.glassOpacity, in: 0...1)
                    .accessibilityLabel("Glass opacity")
                    .help("Adjusts glass and surface opacity without fading text or controls")
            }

            DisclosureGroup("Color tint") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Glass tint")
                        Slider(value: $store.glassTint, in: 0...1).accessibilityLabel("Glass tint")
                    }
                    HStack {
                        Text("Sidebar tint")
                        Slider(value: Binding(get: { store.theme.tintStrength }, set: { store.theme.tintStrength = $0 }), in: 0...2)
                            .accessibilityLabel("Sidebar tint")
                    }
                }
                .font(.callout).padding(.top, 10)
            }
            .font(.callout).foregroundStyle(.secondary)

            Button("Reset appearance") {
                store.matchLighting = false
                store.theme = .forgeDefault
                store.glassOpacity = 0.7
                store.glassTint = 0.15
                store.appearance = "system"
            }
            .buttonStyle(.bordered)
        }
        .padding(20).frame(width: 300)
        .environment(\.appTheme, store.rendered)
        .environment(\.glassTint, store.glassTint)
        .environment(\.glassOpacity, store.glassOpacity)
        .tint(store.rendered.accent)
    }
}
