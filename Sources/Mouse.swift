import SwiftUI
import AppKit

// MARK: - What a mouse button can do (any mouse)

/// A mouse button's job. Buttons are numbered like macOS does: 0 left, 1 right, 2 middle, 3 back, 4 forward, 5…
enum MouseAction: Codable, Hashable {
    /// acts as a key, held down while the button is (push-to-talk, crouch, a media key…)
    case key(Usage)
    /// acts as another mouse button
    case button(Int)
    /// shortcut / text / app / macro, on press
    case action(KeyAction)
    /// does nothing
    case disabled

    enum Kind: String, CaseIterable { case normal = "Default", key = "Key", button = "Button", shortcut = "Shortcut",
                                      text = "Text", app = "App", macro = "Macro", off = "Off" }

    var kind: Kind {
        switch self {
        case .key: .key
        case .button: .button
        case .disabled: .off
        case .action(let a):
            switch a.kind {
            case .shortcut: .shortcut
            case .text: .text
            case .app: .app
            case .macro: .macro
            case .key: .normal
            }
        }
    }

    func label(iso: Bool) -> String {
        switch self {
        case .key(let u): return Keys.name(u, iso: iso)
        case .button(let b): return MouseButtons.name(b)
        case .action(let a): return a.label(iso: iso)
        case .disabled: return "Nothing"
        }
    }
}

enum MouseButtons {
    /// Buttons offered in the editor (left/right click stay as they are, so the mouse always works).
    static let editable = Array(2...9)

    static func name(_ b: Int) -> String {
        switch b {
        case 0: "Left click"
        case 1: "Right click"
        case 2: "Middle (wheel)"
        case 3: "Back"
        case 4: "Forward"
        default: "Button \(b + 1)"
        }
    }

    static func icon(_ b: Int) -> String {
        switch b {
        case 2: "computermouse"
        case 3: "chevron.backward.circle"
        case 4: "chevron.forward.circle"
        default: "circle.grid.2x1"
        }
    }
}

/// Carries out a mouse bind (called from the event tap on the main thread).
@MainActor
enum MouseRunner {
    static func handle(_ m: MouseAction, down: Bool, at p: CGPoint) {
        switch m {
        case .key(let u): postKey(u, down: down)
        case .button(let b): postButton(b, down: down, at: p)
        case .action(let a): if down { ActionRunner.run(a) }
        case .disabled: break
        }
    }

    private static let modifierFlags: [UInt64: CGEventFlags] = [
        0xE0: .maskControl, 0xE4: .maskControl, 0xE1: .maskShift, 0xE5: .maskShift,
        0xE2: .maskAlternate, 0xE6: .maskAlternate, 0xE3: .maskCommand, 0xE7: .maskCommand,
    ]

    /// NX_KEYTYPE_* for media keys (the reverse of Keys.consumer(nxKey:)).
    private static let nxKeys: [Usage: Int] = [
        HID.consumer(0xE9): 0, HID.consumer(0xEA): 1, HID.consumer(0x6F): 2, HID.consumer(0x70): 3,
        HID.consumer(0xE2): 7, HID.consumer(0xCD): 16, HID.consumer(0xB5): 17, HID.consumer(0xB6): 18,
    ]

    static func postKey(_ u: Usage, down: Bool) {
        if HID.isConsumer(u) {
            guard let nx = nxKeys[u] else { return }
            let data1 = (nx << 16) | ((down ? 0xA : 0xB) << 8)
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            guard let cg = ev?.cgEvent else { return }
            cg.setIntegerValueField(.eventSourceUserData, value: KeyTap.marker)
            cg.post(tap: .cghidEventTap)
            return
        }
        guard u >> 32 == 7, u != HID.none, let vk = Keys.vk(for: u, iso: KeyTap.shared.iso) else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(vk), keyDown: down) else { return }
        if let flag = modifierFlags[u & 0xFF] {
            e.type = .flagsChanged
            e.flags = down ? flag : []
        }
        e.setIntegerValueField(.eventSourceUserData, value: KeyTap.marker)
        e.post(tap: .cghidEventTap)
    }

    static func postButton(_ b: Int, down: Bool, at p: CGPoint) {
        let type: CGEventType
        switch b {
        case 0: type = down ? .leftMouseDown : .leftMouseUp
        case 1: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p,
                              mouseButton: CGMouseButton(rawValue: UInt32(min(b, 31))) ?? .center) else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b))
        e.setIntegerValueField(.eventSourceUserData, value: KeyTap.marker)
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - The Mouse tab

@MainActor
final class MouseUI: ObservableObject {
    @Published var selected = 3
}

struct MouseTab: View {
    @ObservedObject var store: ProfileStore
    @StateObject private var ui = MouseUI()
    @ObservedObject private var live = LiveKeys.shared
    @ObservedObject private var tap = KeyTap.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        let binds = store.active?.mouse ?? [:]
        VStack(alignment: .leading, spacing: 18) {
            // screenshot helper: KEYFORGE_MOUSE=light shows the lighting card first
            if ProcessInfo.processInfo.environment["KEYFORGE_MOUSE"] == "light" { MouseLightingCard(store: store) }
            HStack(alignment: .top, spacing: 18) {
                GlassCard {
                    VStack(spacing: 14) {
                        MouseDrawing(binds: binds, selected: $ui.selected, pressed: live.mouseDown,
                                     glow: store.mouseLightingProfile?.mouseLighting?
                                        .resolved(keyboard: store.lightingProfile?.lighting ?? .standard).previewColors)
                            .frame(width: 230, height: 330)
                        // buttons a drawing can't show (side panels of MMO mice…)
                        HStack(spacing: 6) {
                            ForEach(5...9, id: \.self) { b in
                                Button { ui.selected = b } label: {
                                    Text("\(b + 1)").font(.callout.weight(.semibold)).frame(width: 30, height: 26)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(chipFill(b, binds)))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                                .help(MouseButtons.name(b))
                            }
                        }
                        Button {
                            if live.mouseRecorder != nil { live.mouseRecorder = nil }
                            else { live.mouseRecorder = { b in withAnimation { ui.selected = b } } }
                        } label: {
                            Label(live.mouseRecorder != nil ? "Press a mouse button…" : "Find a Button",
                                  systemImage: live.mouseRecorder != nil ? "record.circle.fill" : "cursorarrow.click.2")
                        }
                        .buttonStyle(.purpleGlass)
                        .help("Press any mouse button over this window to pick it (for extra side buttons)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: 300)

                MouseEditor(store: store, button: ui.selected).id(ui.selected)
            }

            if !binds.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mouse buttons in this profile").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(binds.sorted { $0.key < $1.key }, id: \.key) { b, m in
                            HStack(spacing: 8) {
                                Text(MouseButtons.name(b)).lineLimit(1)
                                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(theme.pink)
                                Text(m.label(iso: store.iso)).fontWeight(.semibold).lineLimit(1)
                                Spacer(minLength: 4)
                                Button { withAnimation { store.setMouse(b, nil) } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(ui.selected == b ? theme.purple.opacity(0.3) : Color.primary.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                            .contentShape(Capsule())
                            .onTapGesture { ui.selected = b }
                        }
                    }
                }
            }

            MouseLightingCard(store: store)

            Text("Works with any mouse. Left and right click always stay as they are. Binds follow the profile that's on, so a game profile can have its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { live.mouseRecorder = nil }
    }

    private func chipFill(_ b: Int, _ binds: [Int: MouseAction]) -> Color {
        if ui.selected == b { return theme.purple.opacity(0.85) }
        if live.mouseDown.contains(b) { return theme.pink.opacity(0.7) }
        return binds[b] != nil ? theme.purple.opacity(0.3) : Color.primary.opacity(0.06)
    }
}

/// A gaming mouse seen from above, with the wheel and the two side buttons clickable.
struct MouseDrawing: View {
    let binds: [Int: MouseAction]
    @Binding var selected: Int
    let pressed: Set<Int>
    /// the mouse's light colors (nil = KeyForge doesn't control them)
    var glow: [Color]? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let bodyRect = CGRect(x: w * 0.12, y: 0, width: w * 0.8, height: h)
            ZStack(alignment: .topLeading) {
                // shell
                RoundedRectangle(cornerRadius: bodyRect.width * 0.48, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: bodyRect.width * 0.48, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .frame(width: bodyRect.width, height: bodyRect.height)
                    .offset(x: bodyRect.minX)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                // left / right click (locked) split + palm line
                Path { p in
                    p.move(to: CGPoint(x: bodyRect.midX, y: 6)); p.addLine(to: CGPoint(x: bodyRect.midX, y: h * 0.4))
                    p.move(to: CGPoint(x: bodyRect.minX + 8, y: h * 0.4))
                    p.addQuadCurve(to: CGPoint(x: bodyRect.maxX - 8, y: h * 0.4), control: CGPoint(x: bodyRect.midX, y: h * 0.45))
                }
                .stroke(Color.black.opacity(0.6), lineWidth: 2)
                lockLabel("Left", x: bodyRect.minX + bodyRect.width * 0.25, y: h * 0.22)
                lockLabel("Right", x: bodyRect.minX + bodyRect.width * 0.75, y: h * 0.22)
                // wheel = button 2
                part(2, CGRect(x: bodyRect.midX - 11, y: h * 0.1, width: 22, height: h * 0.17), radius: 11)
                // side buttons on the left flank: forward (front) above back
                part(4, CGRect(x: bodyRect.minX - 14, y: h * 0.42, width: 26, height: h * 0.12), radius: 8)
                part(3, CGRect(x: bodyRect.minX - 14, y: h * 0.56, width: 26, height: h * 0.12), radius: 8)
                // light strip + logo, in the mouse's colors
                let colors = glow ?? [theme.purple.opacity(0.7)]
                Capsule().fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: bodyRect.width * 0.62, height: 7)
                    .blur(radius: 1.5)
                    .shadow(color: colors.first ?? .clear, radius: 8)
                    .offset(x: bodyRect.midX - bodyRect.width * 0.31, y: h * 0.88)
                Circle().fill(colors.count > 1 ? colors[colors.count / 2] : colors[0]).frame(width: 16, height: 16).blur(radius: 4)
                    .offset(x: bodyRect.midX - 8, y: h * 0.72)
            }
        }
    }

    private func lockLabel(_ t: String, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text(t).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.35))
        .position(x: x, y: y)
    }

    private func part(_ b: Int, _ r: CGRect, radius: CGFloat) -> some View {
        let on = selected == b, down = pressed.contains(b), bound = binds[b] != nil
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = b } } label: {
            shape
                .fill(down ? AnyShapeStyle(theme.pink) : on ? AnyShapeStyle(theme.purple)
                      : bound ? AnyShapeStyle(theme.purple.opacity(0.45)) : AnyShapeStyle(Color(white: 0.3)))
                .overlay(shape.strokeBorder(on ? Color.white.opacity(0.8) : Color.white.opacity(0.15), lineWidth: on ? 2 : 1))
                .shadow(color: on || down ? theme.purple.opacity(0.7) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
        .help(MouseButtons.name(b))
    }
}

/// The card for the selected mouse button.
struct MouseEditor: View {
    @ObservedObject var store: ProfileStore
    let button: Int
    @ObservedObject private var live = LiveKeys.shared
    @ObservedObject private var tap = KeyTap.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        let bind = store.active?.mouse[button]
        let kind = bind?.kind ?? .normal
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: MouseButtons.icon(button)).font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(theme.purple).frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MouseButtons.name(button)).font(.title3.weight(.bold))
                        Text(bind.map { "Now does: \($0.label(iso: store.iso))" } ?? "Works normally")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Default") { withAnimation { store.setMouse(button, nil) } }
                        .buttonStyle(.purpleGlass).disabled(bind == nil)
                }

                GlassSegmented(selection: Binding(get: { kind }, set: { switchKind($0) }),
                               options: MouseAction.Kind.allCases.map { ($0, $0.rawValue) })

                switch bind {
                case .key(let u):
                    HStack(spacing: 10) {
                        Text("Holds").foregroundStyle(.secondary)
                        Text(Keys.name(u, iso: store.iso)).fontWeight(.semibold)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                        Menu {
                            ForEach(Keys.targetGroups(iso: store.iso)) { g in
                                Menu {
                                    ForEach(g.usages, id: \.self) { t in
                                        Button(Keys.name(t, iso: store.iso)) { store.setMouse(button, .key(t)) }
                                    }
                                } label: { Label(g.title, systemImage: g.icon) }
                            }
                        } label: { Label("Choose", systemImage: "list.bullet") }
                        .modifier(GlassMenuLabel())
                        Button {
                            if live.recorder != nil { live.recorder = nil }
                            else { live.recorder = { [store, button] u in store.setMouse(button, .key(u)) } }
                        } label: {
                            Label(live.recorder != nil ? "Press the key…" : "Press a Key", systemImage: "record.circle")
                        }
                        .buttonStyle(.purpleGlassProminent)
                    }
                    Text("The key stays pressed while you hold the button: great for push-to-talk, crouch or sprint. Media keys work too.")
                        .font(.caption).foregroundStyle(.secondary)
                case .button(let b):
                    HStack(spacing: 10) {
                        Text("Acts as").foregroundStyle(.secondary)
                        Menu {
                            ForEach(0...9, id: \.self) { t in
                                if t != button { Button(MouseButtons.name(t)) { store.setMouse(button, .button(t)) } }
                            }
                        } label: { Text(MouseButtons.name(b)) }
                        .modifier(GlassMenuLabel())
                    }
                case .action:
                    ActionEditor(store: store, showKinds: false,
                                 read: { [store, button] in
                                     if case .action(let a) = store.active?.mouse[button] { return a } else { return nil }
                                 },
                                 write: { [store, button] a in store.setMouse(button, a.map { .action($0) }) })
                case .disabled:
                    Text("This button does nothing (handy when a game binds it by accident).")
                        .font(.callout).foregroundStyle(.secondary)
                case nil:
                    Text("Pick what this button should do.").font(.callout).foregroundStyle(.secondary)
                }

                if bind != nil && !tap.trusted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("KeyForge needs Accessibility to change mouse buttons.").font(.callout).foregroundStyle(.secondary)
                        Button("Allow…") { tap.requestAccess() }.buttonStyle(.purpleGlassProminent)
                        Button("Reset permission") { tap.resetAndRequest() }.buttonStyle(.link)
                    }
                }
            }
        }
        .onDisappear { live.recorder = nil; live.shortcutRecorder = nil }
    }

    private func switchKind(_ k: MouseAction.Kind) {
        live.recorder = nil; live.shortcutRecorder = nil
        switch k {
        case .normal: store.setMouse(button, nil)
        case .key:
            store.setMouse(button, .key(HID.key(0x2C)))   // Space until you press another key
            live.recorder = { [store, button] u in store.setMouse(button, .key(u)) }
        case .button: store.setMouse(button, .button(button == 2 ? 3 : 2))
        case .shortcut:
            store.setMouse(button, .action(.shortcut(Shortcut(keyCode: 0, modifiers: 0))))
            live.shortcutRecorder = { [store, button] s in store.setMouse(button, .action(.shortcut(s))) }
        case .text: store.setMouse(button, .action(.text("")))
        case .app: store.setMouse(button, .action(.app("")))
        case .macro: store.setMouse(button, .action(.macro([])))
        case .off: store.setMouse(button, .disabled)
        }
        if k != .normal { tap.ensureRunning(); if !tap.trusted { tap.requestAccess() } }
    }
}
