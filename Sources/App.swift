import SwiftUI
import AppKit

@main
struct KeyForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = ProfileStore.shared

    var body: some Scene {
        Window("KeyForge \(appVersion)", id: "main") {
            ContentView()
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
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
    @Published var bindingKey: Usage?
    @Published var renaming: UUID?
    @Published var renameText = ""
    @Published var deleting: UUID?
    @Published var showTheme = false
    @Published var showSettings = false
    @Published var mode: Mode = .keys
    enum Mode { case keys, mouse, lighting }

    func chooseBinding(for key: Usage) {
        LiveKeys.shared.recorder = nil
        LiveKeys.shared.shortcutRecorder = nil
        selected = key
        bindingKey = key
    }
}

struct ContentView: View {
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @StateObject private var ui = UIState()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, devices: store.devices, ui: ui)
                .navigationSplitViewColumnWidth(min: 242, ideal: 254, max: 300)
        } detail: {
            DetailView(store: store, ui: ui)
        }
        .disabled(ui.bindingKey != nil)
        .background(ForgeBackdrop())
        .overlay {
            if let key = ui.bindingKey {
                GeometryReader { geometry in
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                            .onTapGesture { ui.bindingKey = nil }
                        KeyBindingPicker(store: store, key: key) { ui.bindingKey = nil }
                            .frame(width: min(320, geometry.size.width - 40), height: min(176, geometry.size.height - 40))
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(themeStore.colorScheme)
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
                    .disabled(ui.bindingKey != nil)
                    .popover(isPresented: $ui.showSettings, arrowEdge: .bottom) {
                        SettingsPanel(store: store).environment(\.appTheme, themeStore.rendered)
                            .environment(\.glassTint, themeStore.glassTint)
                            .environment(\.glassOpacity, themeStore.glassOpacity).tint(themeStore.rendered.accent)
                    }
                Button { ui.showTheme.toggle() } label: { Label("Appearance", systemImage: "paintpalette") }
                    .help("Change the app's color")
                    .disabled(ui.bindingKey != nil)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ProfileHUD.show("Gaming", reason: "🎮 Game: Townfall-Win64-Shipping.exe") }
            }
            // screenshot helper: KEYFORGE_SELECT=<hex usage> opens the editor for that key
            if let h = ProcessInfo.processInfo.environment["KEYFORGE_SELECT"], let u = UInt64(h, radix: 16) { ui.selected = u }
        }
        .onChange(of: store.activeID) { ui.selected = nil; ui.bindingKey = nil; LiveKeys.shared.recorder = nil }
        .onChange(of: store.device) {
            ui.bindingKey = nil
            if !store.selectedHasLighting && ui.mode == .lighting { ui.mode = .keys }
        }
        .onChange(of: ui.mode) { ui.bindingKey = nil }
        .environment(\.appTheme, themeStore.rendered)
        .environment(\.glassTint, themeStore.glassTint)
        .environment(\.glassOpacity, themeStore.glassOpacity)
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
                .padding(.horizontal, 14).padding(.top, 12)

            VStack(alignment: .leading, spacing: 3) {
                workspace(.keys, "Keyboard", icon: "keyboard")
                workspace(.mouse, "Mouse", icon: "computermouse")
                if store.selectedHasLighting {
                    workspace(.lighting, "Lighting", icon: "light.max")
                }
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 22)

            HStack {
                Text("Profiles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.addProfile() } label: { Image(systemName: "plus") }
                    .buttonStyle(.purpleGlassIcon(26)).help("New profile")
            }
            .padding(.horizontal, 25).padding(.bottom, 7)

            List {
                ForEach(store.visible) { p in
                    Button { store.select(p.id) } label: {
                        ProfileRow(profile: p, active: p.id == store.activeID, enabled: store.enabled)
                    }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(p.id == store.activeID ? [.isSelected] : [])
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Rename…") { ui.renameText = p.name; ui.renaming = p.id }
                            Button("Duplicate") { store.addProfile(copying: p) }
                            Divider()
                            Button("Delete…", role: .destructive) { ui.deleting = p.id }.disabled(store.visible.count < 2)
                        }
                }
                .onMove { store.moveVisible(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 100)

            DeviceCard(store: store, devices: devices).padding(14)

        }
        .background(theme.accent.opacity(0.025 * theme.tintStrength).ignoresSafeArea())
    }

    private func workspace(_ mode: UIState.Mode, _ title: String, icon: String) -> some View {
        let selected = ui.mode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                ui.mode = mode; ui.selected = nil; LiveKeys.shared.recorder = nil
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? theme.accent : Color.secondary).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? theme.accent.opacity(0.12) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

}

struct ProfileRow: View {
    let profile: Profile
    let active: Bool
    let enabled: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(active ? theme.accent : Color.secondary)
                .frame(width: 24, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body.weight(active ? .semibold : .regular)).lineLimit(1)
                let n = profile.map.count + profile.actions.count + profile.mouse.count
                Text(n == 0 ? "No changes" : "\(n) change\(n == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if active {
                Circle().fill(enabled ? theme.accent : Color.gray)
                    .frame(width: 6, height: 6)
                    .help(enabled ? "Active profile" : "Remapping paused")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? theme.accent.opacity(0.1) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.clear, lineWidth: 0.5))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
        .background(ForgePanel(cornerRadius: 16))
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var ui: UIState
    @ObservedObject private var live = LiveKeys.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollViewReader { position in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if ui.mode == .mouse {
                    MouseTab(store: store)
                } else {
                    keyboardStage
                    if ui.mode == .lighting {
                        LightingCard(store: store)
                    } else if let sel = ui.selected {
                        KeyEditor(store: store, key: sel, ui: ui).id(sel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if ui.mode == .keys { ChangesList(store: store, ui: ui) }
                }
                if ui.mode != .lighting { GameModeCard(store: store) }
            }
            .frame(maxWidth: 1450, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            .id("workspace-top")
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: ui.mode)
        }
        // Overlay scrollbars avoid the keyboard aspect-ratio layout feedback loop.
        .scrollIndicators(.never)
        .onChange(of: ui.mode) { position.scrollTo("workspace-top", anchor: .top) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { ui.selected = nil } }
        .onAppear {
            if ProcessInfo.processInfo.environment["KEYFORGE_LIGHTING"] != nil { ui.mode = .lighting }
            if ProcessInfo.processInfo.environment["KEYFORGE_MOUSE"] != nil { ui.mode = .mouse }
        }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.active?.name ?? "Profile")
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 12)
                if ui.mode == .keys { keyButtons }
            }
            AutoSwitchRow(store: store)
        }
    }

    private var keyboardStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: ui.mode == .lighting ? "light.max" : "keyboard")
                    .foregroundStyle(Color.secondary)
                Text(ui.mode == .lighting ? "Preview" : "Keyboard")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if ui.mode == .keys {
                    HStack(spacing: 12) {
                        Label("Remapped", systemImage: "circle.fill").foregroundStyle(theme.accent.opacity(0.65))
                        Label("Selected", systemImage: "circle.fill").foregroundStyle(theme.accent)
                    }.font(.system(size: 9, weight: .medium))
                }
            }
            KeyboardView(store: store, selected: $ui.selected,
                         lighting: ui.mode == .lighting && store.selectedHasLighting ? (store.active?.lighting ?? .standard) : nil,
                         onDoubleClick: { ui.chooseBinding(for: $0) })
                .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
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
                .disabled((store.active?.map.isEmpty ?? true) && (store.active?.actions.isEmpty ?? true))
        }
        .frame(width: 250, alignment: .trailing)
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
                        Button { ui.chooseBinding(for: key) } label: {
                            Label("Choose key", systemImage: "keyboard")
                        }
                        .buttonStyle(.purpleGlass)

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
        .onDisappear {
            // A key popup may already own recording while this editor is replaced.
            guard ui.bindingKey == nil else { return }
            live.recorder = nil; live.shortcutRecorder = nil
        }
        .onTapGesture { }   // don't deselect when clicking the card
    }
}

/// The editor's right-hand keycap for an action (icon + short label).
struct ActionCap: View {
    let action: KeyAction
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: action.icon).font(.system(size: 20, weight: .medium))
            Text(action.label(iso: ProfileStore.shared.iso)).font(.system(size: 9, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(theme.accent).padding(6).frame(width: 64, height: 64)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.opacity(0.25), lineWidth: 0.5))
    }
}

struct BigCap: View {
    let usage: Usage
    let iso: Bool
    let highlighted: Bool
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let legend = Keys.legend(usage, iso: iso)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 1) {
            if let top = legend.top {
                Text(top).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(legend.main).font(.system(size: legend.main.count <= 2 ? 24 : 14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .foregroundStyle(Color.primary).padding(6).frame(width: 64, height: 64)
        .background {
            shape.fill(LinearGradient(colors: scheme == .dark ? [Color(white: 0.25), Color(white: 0.16)]
                                                                  : [Color(white: 0.99), Color(white: 0.9)],
                                      startPoint: .top, endPoint: .bottom))
            if highlighted { shape.fill(theme.accent.opacity(0.15)) }
        }
        .overlay(shape.strokeBorder(highlighted ? theme.accent.opacity(0.65) : Color.primary.opacity(0.14), lineWidth: highlighted ? 1 : 0.5))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
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
                Text("Your mappings").font(.system(size: 13, weight: .semibold))
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
                Picker("Keyboard size", selection: Binding(get: { store.layout }, set: { store.layout = $0 })) {
                    ForEach(LayoutKind.allCases, id: \.self) { layout in Text(layout.title).tag(layout) }
                }
                .pickerStyle(.menu)
                GlassSegmented(selection: Binding(get: { store.iso }, set: { store.iso = $0 }),
                               options: [(true, "ISO (big Enter)"), (false, "ANSI (US)")])
            }
            Toggle(isOn: Binding(get: { store.openAtLogin }, set: { store.openAtLogin = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open at login")
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
        }
        .padding(16)
        .frame(width: 380)
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
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
