import SwiftUI
import AppKit

@main
struct KeyForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = ProfileStore.shared

    var body: some Scene {
        Window("KeyForge \(appVersion)", id: "main") {
            ContentView()
                .frame(minWidth: 1180, minHeight: 640)
        }
        .restorationBehavior(.disabled)   // always open the window when the app is launched
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            Image(systemName: store.enabled ? "keyboard.fill" : "keyboard")
        }
    }
}

let appVersion: String = {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return v.hasSuffix(".0") ? String(v.dropLast(2)) : v
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ n: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = ev?.eventID == kAEOpenApplication
            && ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            _ = ProfileStore.shared   // applies the active profile right away
            AppWatcher.start()        // profiles that follow the app in front
            ProfileHotkeys.start()    // ⌃⌥1…9
            KeyTap.shared.watchActivation()
            KeyTap.shared.ensureRunning()
            let d = UserDefaults.standard
            if !d.bool(forKey: "askedLogin"), ProcessInfo.processInfo.environment["KEYFORGE_DRY"] == nil {   // first launch: keep keys working after a restart
                d.set(true, forKey: "askedLogin")
                ProfileStore.shared.openAtLogin = true
            }
        }
        if launchedAtLogin {
            // quietly live in the menu bar
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.identifier?.rawValue == "main" || $0.title.hasPrefix("KeyForge") }.forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow, w.title.hasPrefix("KeyForge") else { return }
            // window closed: keep running in the menu bar without a Dock icon
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { ProfileStore.shared.saveNow() }   // flush a pending save
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}

/// View state that would be @State (unavailable without Xcode's macro plugins).
@MainActor
final class UIState: ObservableObject {
    @Published var selected: Usage?
    @Published var renaming: UUID?
    @Published var renameText = ""
    @Published var deleting: UUID?
    @Published var showTheme = false
    @Published var showSettings = false
    @Published var mode: Mode = .keys
    enum Mode { case keys, lighting }
}

struct ContentView: View {
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @StateObject private var ui = UIState()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, devices: store.devices, ui: ui)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260)
        } detail: {
            DetailView(store: store, ui: ui)
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { AppTitle() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { AppTitle() }
            }
            ToolbarItemGroup {
                Button { ui.showSettings.toggle() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Keyboard layout and startup")
                    .popover(isPresented: $ui.showSettings, arrowEdge: .bottom) {
                        SettingsPanel(store: store).environment(\.appTheme, themeStore.rendered)
                            .environment(\.glassTint, themeStore.glassTint).tint(themeStore.rendered.accent)
                    }
                Button { ui.showTheme.toggle() } label: { Label("Theme", systemImage: "paintpalette.fill") }
                    .help("Change the app's color")
                    .popover(isPresented: $ui.showTheme, arrowEdge: .bottom) { ThemePicker(store: themeStore) }
            }
        }
        .alert("Rename Profile", isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
            TextField("Name", text: $ui.renameText)
            Button("Rename") { if let id = ui.renaming { store.rename(id, to: ui.renameText) }; ui.renaming = nil }
            Button("Cancel", role: .cancel) { ui.renaming = nil }
        }
        .alert("Delete this profile?", isPresented: Binding(get: { ui.deleting != nil }, set: { if !$0 { ui.deleting = nil } })) {
            Button("Delete", role: .destructive) { if let id = ui.deleting { store.delete(id) }; ui.deleting = nil }
            Button("Cancel", role: .cancel) { ui.deleting = nil }
        } message: {
            Text("Its key changes will be gone.")
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            LiveKeys.shared.install { ProfileStore.shared.iso }
            if ProcessInfo.processInfo.environment["KEYFORGE_STRESS"] != nil { StressTest.run() }
            if ProcessInfo.processInfo.environment["KEYFORGE_HUD"] != nil {   // screenshot helper for the profile popup
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ProfileHUD.show("Gaming", auto: true) }
            }
            // screenshot helper: KEYFORGE_SELECT=<hex usage> opens the editor for that key
            if let h = ProcessInfo.processInfo.environment["KEYFORGE_SELECT"], let u = UInt64(h, radix: 16) { ui.selected = u }
        }
        .onChange(of: store.activeID) { ui.selected = nil; LiveKeys.shared.recorder = nil }
        .onChange(of: store.device) { if !store.selectedHasLighting { ui.mode = .keys } }
        .environment(\.appTheme, themeStore.rendered)
        .environment(\.glassTint, themeStore.glassTint)
        .tint(themeStore.rendered.accent)
        .animation(.easeInOut(duration: 0.35), value: themeStore.rendered)
    }
}

struct AppTitle: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 22, height: 22)
            .padding(.trailing, -10)
            .accessibilityHidden(true)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var devices: DeviceWatcher
    @ObservedObject var ui: UIState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            KeyboardPicker(store: store, devices: devices)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button { store.addProfile() } label: { Image(systemName: "plus") }
                    .buttonStyle(.purpleGlassIcon(28))
                    .help("New profile")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List(selection: Binding(get: { store.activeID }, set: { if let id = $0 { store.select(id) } })) {
                ForEach(store.visible) { p in
                    ProfileRow(profile: p, active: p.id == store.activeID, enabled: store.enabled)
                        .tag(p.id)
                        .contextMenu {
                            Button("Rename…") { ui.renameText = p.name; ui.renaming = p.id }
                            Button("Duplicate") { store.addProfile(copying: p) }
                            Divider()
                            Button("Delete…", role: .destructive) { ui.deleting = p.id }.disabled(store.visible.count < 2)
                        }
                }
                .onMove { store.moveVisible(from: $0, to: $1) }
            }
            .scrollContentBackground(.hidden)

            DeviceCard(store: store, devices: devices)
                .padding(12)
        }
        .background {
            theme.sidebarTint   // macOS draws the sidebar's Liquid Glass; this just tints it
                .ignoresSafeArea()
        }
    }
}

struct ProfileRow: View {
    let profile: Profile
    let active: Bool
    let enabled: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? AnyShapeStyle(theme.purple) : AnyShapeStyle(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(active ? 0.22 : 0), lineWidth: 0.5))
                Image(systemName: "keyboard").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? .white : .secondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body.weight(active ? .semibold : .regular)).lineLimit(1)
                let n = profile.map.count + profile.actions.count
                Text(n == 0 ? "No changes" : "\(n) key\(n == 1 ? "" : "s") changed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if active {
                Text(enabled ? "ON" : "OFF")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(enabled ? theme.purple : Color.gray))
            }
        }
        .padding(.vertical, 3)
    }
}

/// Which keyboard the app shows: every connected keyboard, keyboards set up before, and "All keyboards".
struct KeyboardPicker: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var devices: DeviceWatcher
    @StateObject private var open = Flag()
    @Environment(\.appTheme) private var theme

    final class Flag: ObservableObject { @Published var on = false }

    var body: some View {
        Button { open.on.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: store.device == KeyboardDevice.allKey ? "keyboard.badge.ellipsis" : "keyboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.name(of: store.device)).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(store.device == KeyboardDevice.allKey ? "Changes apply to every keyboard"
                         : store.selectedConnected ? "Connected" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
        .help("Pick the keyboard to set up; each keyboard has its own profiles")
        .popover(isPresented: $open.on, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboards").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
                ForEach(store.keyboardChoices, id: \.key) { k in
                    row(k.key, k.name, sub: k.connected ? "Connected" : "Not connected", connected: k.connected)
                }
                Divider().padding(.vertical, 4)
                row(KeyboardDevice.allKey, "All keyboards", sub: "Changes apply to every keyboard", connected: true)
            }
            .padding(8)
            .frame(width: 280)
            .environment(\.appTheme, theme)
        }
    }

    private func row(_ key: String, _ name: String, sub: String, connected: Bool) -> some View {
        Button {
            store.selectDevice(key)
            open.on = false
        } label: {
            HStack(spacing: 10) {
                Circle().fill(connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).lineLimit(1)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if key == store.device { Image(systemName: "checkmark").foregroundStyle(theme.purple) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(key == store.device ? theme.purple.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Connection status and the master switch.
struct DeviceCard: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var devices: DeviceWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(devices.keyboards.isEmpty ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(devices.keyboards.count == 1 ? "1 keyboard connected" : "\(devices.keyboards.count) keyboards connected")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                    Text(devices.keyboards.map(\.name).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Toggle(isOn: $store.enabled) {
                Text("Remapping").font(.callout)
            }
            .toggleStyle(.switch)
            .help("Turns every keyboard's key changes on or off")

            if let e = store.lastError {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            shape.fill(Color.primary.opacity(0.05))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var ui: UIState
    @ObservedObject private var live = LiveKeys.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                KeyboardView(store: store, selected: $ui.selected,
                             lighting: ui.mode == .lighting && store.selectedHasLighting ? (store.active?.lighting ?? .standard) : nil)
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
                if ui.mode == .lighting {
                    LightingCard(store: store)
                } else if let sel = ui.selected {
                    KeyEditor(store: store, key: sel, ui: ui).id(sel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    hint
                }
                if ui.mode == .keys { ChangesList(store: store, ui: ui) }
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.25), value: ui.mode)
        }
        // The keyboard's height follows the width. A scroll bar that takes space (macOS does that when a
        // mouse is plugged in) made the page narrower → shorter → no scroll bar → wider → taller… forever,
        // pegging the CPU (seen when Per Key's extra row made the page just taller than the window).
        .scrollIndicators(.never)
        .background(
            LinearGradient(colors: [theme.purple.opacity(0.10), .clear, theme.indigo.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { ui.selected = nil } }
        .onAppear { if ProcessInfo.processInfo.environment["KEYFORGE_LIGHTING"] != nil { ui.mode = .lighting } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.active?.name ?? "").font(.system(size: 26, weight: .bold))
                Text(store.enabled ? "On \(store.device == KeyboardDevice.allKey ? "every keyboard" : store.name(of: store.device))" : "Remapping is off")
                    .font(.callout).foregroundStyle(.secondary)
                AutoSwitchRow(store: store)
                    .padding(.top, 2)
            }
            Spacer()
            if store.selectedHasLighting {
                GlassSegmented(selection: Binding(get: { ui.mode }, set: { ui.mode = $0; ui.selected = nil; LiveKeys.shared.recorder = nil }),
                               options: [(.keys, "Keys"), (.lighting, "Lighting")])
                    .frame(width: 220)
            } else {
                // KeyForge can only light the Razer Huntsman V2
                Color.clear.frame(width: 220, height: 1)
            }
            Spacer()
            if ui.mode == .keys { keyButtons } else { Color.clear.frame(width: 250, height: 1) }
        }
    }

    @ViewBuilder private var keyButtons: some View {
        HStack {
            Menu {
                ForEach(ProfileStore.Preset.allCases) { p in
                    Button(p.rawValue) { withAnimation { store.apply(preset: p) } }
                }
            } label: {
                Label("Quick Setups", systemImage: "wand.and.stars")
            }
            .modifier(GlassMenuLabel())

            Button("Reset All") { withAnimation { store.resetActive(); ui.selected = nil } }
                .buttonStyle(.purpleGlass)
                .disabled(store.active?.map.isEmpty ?? true)
        }
        .frame(width: 250, alignment: .trailing)
    }

    private var hint: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "hand.tap.fill").font(.title2).foregroundStyle(theme.swatch)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Click a key to change what it does").font(.headline)
                    Text("Press keys on your keyboard to see them light up. Changed keys glow and show their new job.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

/// The card under the keyboard for the selected key.
struct KeyEditor: View {
    @ObservedObject var store: ProfileStore
    let key: Usage
    @ObservedObject var ui: UIState
    @ObservedObject private var live = LiveKeys.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        let target = store.active?.map[key]
        let action = store.active?.actions[key]
        let recording = live.recorder != nil
        let isModifier = (0xE0...0xE7).contains(key & 0xFFFF) && key >> 32 == 7
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    BigCap(usage: key, iso: store.iso, highlighted: false)
                    Image(systemName: "arrow.right").font(.title2.weight(.bold)).foregroundStyle(theme.purple)
                    if let action {
                        ActionCap(action: action)
                    } else {
                        BigCap(usage: target ?? key, iso: store.iso, highlighted: target != nil)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(Keys.name(key, iso: store.iso)).font(.title3.weight(.bold))
                        Group {
                            if recording { Text("Press the key you want here…").foregroundStyle(theme.pink) }
                            else if let action { Text("Now does: \(action.label(iso: store.iso))") }
                            else if let target { Text("Now does: \(Keys.name(target, iso: store.iso))") }
                            else { Text("Works normally") }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()

                    if action == nil {
                        Menu {
                            ForEach(Keys.targetGroups(iso: store.iso)) { g in
                                Menu {
                                    ForEach(g.usages, id: \.self) { u in
                                        Button { store.set(key, to: u) } label: {
                                            if u == target { Label(Keys.name(u, iso: store.iso), systemImage: "checkmark") }
                                            else { Text(Keys.name(u, iso: store.iso)) }
                                        }
                                    }
                                } label: { Label(g.title, systemImage: g.icon) }
                            }
                            Divider()
                            Button { store.set(key, to: HID.none) } label: { Label("Disable this key", systemImage: "nosign") }
                        } label: {
                            Label("Choose", systemImage: "list.bullet")
                        }
                        .modifier(GlassMenuLabel())

                        Button {
                            if recording { live.recorder = nil }
                            else {
                                live.recorder = { [store] u in withAnimation { store.set(key, to: u) } }
                            }
                        } label: {
                            Label(recording ? "Cancel" : "Press a Key", systemImage: recording ? "xmark" : "record.circle")
                        }
                        .buttonStyle(.purpleGlassProminent)
                    }

                    Button("Default") { withAnimation { store.set(key, to: nil) } }
                        .buttonStyle(.purpleGlass)
                        .disabled(target == nil && action == nil)
                }

                if !isModifier && key >> 32 == 7 {
                    ActionEditor(store: store, key: key)
                }
            }
        }
        .onDisappear { live.recorder = nil; live.shortcutRecorder = nil }
        .onTapGesture { }   // don't deselect when clicking the card
    }
}

/// The editor's right-hand keycap for an action (icon + short label).
struct ActionCap: View {
    let action: KeyAction
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 3) {
            Image(systemName: action.icon).font(.system(size: 20, weight: .bold))
            Text(action.label(iso: ProfileStore.shared.iso)).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .padding(6)
        .frame(width: 64, height: 64)
        .background {
            ZStack {
                shape.fill(Color(white: 0.04)).offset(y: 2)
                shape.fill(LinearGradient(colors: [theme.purple, theme.indigo], startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

/// A large single keycap used in the editor card.
struct BigCap: View {
    let usage: Usage
    let iso: Bool
    let highlighted: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        let l = Keys.legend(usage, iso: iso)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 1) {
            if let top = l.top { Text(top).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
            Text(l.main).font(.system(size: l.main.count <= 2 ? 24 : 14, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .padding(6)
        .frame(width: 64, height: 64)
        .background {
            ZStack {
                shape.fill(Color(white: 0.04)).offset(y: 2)
                shape.fill(LinearGradient(colors: highlighted ? [theme.purple, theme.indigo] : [Color(white: 0.22), Color(white: 0.12)],
                                          startPoint: .top, endPoint: .bottom))
                shape.fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center))
            }
        }
        .overlay(shape.strokeBorder(highlighted ? AnyShapeStyle(Theme.rim) : AnyShapeStyle(Color.white.opacity(0.1)), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

/// Every change in this profile as a chip; click to jump to the key, ✕ to undo it.
struct ChangesList: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var ui: UIState
    @Environment(\.appTheme) private var theme

    var body: some View {
        let keyChanges = (store.active?.map ?? [:]).map { (key: $0.key, value: Keys.name($0.value, iso: store.iso)) }
        let actionChanges = (store.active?.actions ?? [:]).map { (key: $0.key, value: $0.value.label(iso: store.iso)) }
        let changes = (keyChanges + actionChanges).sorted { Keys.name($0.key, iso: store.iso) < Keys.name($1.key, iso: store.iso) }
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Changes in this profile").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(changes, id: \.key) { c in
                        HStack(spacing: 8) {
                            Text(Keys.name(c.key, iso: store.iso)).lineLimit(1)
                            Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(theme.pink)
                            Text(c.value).fontWeight(.semibold).lineLimit(1)
                            Spacer(minLength: 4)
                            Button { withAnimation { store.set(c.key, to: nil) } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Put this key back to normal")
                        }
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background {
                            Capsule().fill(ui.selected == c.key ? theme.purple.opacity(0.3) : Color.primary.opacity(0.05))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                        }
                        .contentShape(Capsule())
                        .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { ui.selected = c.key } }
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @ObservedObject var store: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Layout of \(store.name(of: store.device))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                GlassSegmented(selection: Binding(get: { store.layout }, set: { store.layout = $0 }),
                               options: LayoutKind.allCases.map { ($0, $0.title) })
                GlassSegmented(selection: Binding(get: { store.iso }, set: { store.iso = $0 }),
                               options: [(true, "ISO (big Enter)"), (false, "ANSI (US)")])
            }
            Toggle(isOn: Binding(get: { store.openAtLogin }, set: { store.openAtLogin = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open at login")
                    Text("Keeps your keys working after a restart").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(get: { ProfileHotkeys.enabled }, set: { ProfileHotkeys.enabled = $0; store.objectWillChange.send() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Profile hotkeys")
                    Text("⌃⌥1 … ⌃⌥9 (number row) switch to profile 1 … 9").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            AccessRow()
            Text("KeyForge stays in the menu bar when you close the window, and puts your keys back when the keyboard is replugged.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// Shows whether KeyForge may watch/send key presses (shortcuts, macros, Ripple, Heatmap).
struct AccessRow: View {
    @ObservedObject private var tap = KeyTap.shared
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tap.trusted ? "checkmark.circle.fill" : "hand.raised.fill")
                .foregroundStyle(tap.trusted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Key access")
                Text(tap.trusted ? "Allowed: shortcuts, macros, Ripple and Heatmap work" : "Needed for shortcuts, macros, Ripple and Heatmap")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !tap.trusted {
                Button("Allow…") { tap.requestAccess() }.buttonStyle(.purpleGlass)
                    .help("Opens the Accessibility list: switch KeyForge on")
            }
        }
        if !tap.trusted {
            HStack(spacing: 6) {
                Text("Already switched on and still not working?").font(.caption).foregroundStyle(.secondary)
                Button("Reset permission") { tap.resetAndRequest() }
                    .buttonStyle(.link).font(.caption)
                    .help("Removes KeyForge's old entry from Accessibility and asks again. Switch the new KeyForge entry on.")
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // one section per keyboard that has profiles
        let keys = Array(Set(store.profiles.map(\.device))).sorted { store.name(of: $0) < store.name(of: $1) }
        ForEach(keys, id: \.self) { d in
            Section(store.name(of: d)) {
                ForEach(store.profiles.filter { $0.device == d }) { p in
                    Button { store.select(p.id) } label: {
                        if p.id == store.activeByDevice[d] { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
            }
        }
        Divider()
        Toggle("Remapping", isOn: $store.enabled)
        Divider()
        Button("Open KeyForge…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit KeyForge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Debug: KEYFORGE_STRESS=1 switches Solid/Per Key and paints keys for a few seconds, logging main-thread stalls.
@MainActor
enum StressTest {
    static func run() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { start() }
    }

    private static func start() {
        var last = CFAbsoluteTimeGetCurrent(), lastAction = "idle", ticks = 0
        var worst: [String: Double] = [:]
        let watch = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent(), gap = (now - last) * 1000
            last = now
            MainActor.assumeIsolated { worst[lastAction] = max(worst[lastAction] ?? 0, gap) }
        }
        RunLoop.main.add(watch, forMode: .common)
        let store = ProfileStore.shared
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { t in
            MainActor.assumeIsolated {
                ticks += 1
                var l = store.active?.lighting ?? .standard
                if ticks % 30 == 0 {
                    l.effect = l.effect == .perKey ? .solid : .perKey
                    lastAction = "switch to \(l.effect)"
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { store.setLighting(l) }   // like clicking the switcher
                } else if l.effect == .perKey {
                    lastAction = "paint"
                    PaintBrush.shared.hex = UInt32(ticks * 7919 & 0xFFFFFF)
                    PaintBrush.shared.paint(0x7_0000_0004 + UInt64(ticks % 26), erase: false, store: store)
                } else { lastAction = "idle solid" }
                if ticks == 240 {
                    t.invalidate(); watch.invalidate()
                    for (k, v) in worst.sorted(by: { $0.key < $1.key }) { print(String(format: "STRESS %@: worst gap %.0f ms", k, v)) }
                    fflush(stdout)
                }
            }
        }
    }
}
