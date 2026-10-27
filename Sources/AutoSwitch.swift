import SwiftUI
import AppKit
import Carbon

// MARK: - Profiles that follow the app in front

@MainActor
enum AppWatcher {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { changed(app) }
        }
        // the app already in front when KeyForge starts (or the one right behind KeyForge's own window)
        lastPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        ProfileStore.shared.frontAppChanged(frontmostOther)
        // belt and braces: also look once a second (Wine games don't always announce that they came to the front)
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != lastPID else { return }
                changed(app)
            }
        }
    }

    private static var lastPID: pid_t = 0

    /// The frontmost app that isn't KeyForge, from the on-screen window order.
    static var frontmostOther: NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me { return f }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }
    private static var poll: Timer?

    private static func changed(_ app: NSRunningApplication?) {
        guard let app else { return }
        lastPID = app.processIdentifier
        let store = ProfileStore.shared
        if let p = store.frontAppChanged(app) { ProfileHUD.show(p.name, reason: store.lastSwitchReason) }
    }

    /// What a profile stores for an app: its bundle ID, or "exe:<name>" for Windows programs (they have none).
    static func key(for app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "exe:\(app.localizedName ?? app.executableURL?.lastPathComponent ?? "?")"
    }

    /// Apps worth offering in the "+" menu: what's running with a Dock icon.
    static var runningApps: [(name: String, id: String, icon: NSImage?)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { (($0.localizedName ?? key(for: $0)), key(for: $0), $0.icon) }
            .filter { seen.insert($0.1).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func name(of bundleID: String) -> String {
        if bundleID.hasPrefix("exe:") { return String(bundleID.dropFirst(4)) }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(of bundleID: String) -> NSImage {
        if bundleID.hasPrefix("exe:") { return NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil) ?? NSImage() }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// "Turns on for: [Steam ✕] [+]" row under the profile name.
struct AutoSwitchRow: View {
    @ObservedObject var store: ProfileStore

    var body: some View {
        if let p = store.active {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                Text("Auto-switch").font(.callout).foregroundStyle(.secondary)
                ForEach(p.apps, id: \.self) { id in
                    HStack(spacing: 4) {
                        Image(nsImage: AppWatcher.icon(of: id)).resizable().frame(width: 16, height: 16)
                        Text(AppWatcher.name(of: id)).font(.callout).lineLimit(1)
                        Button { store.removeApp(id, from: p.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop switching to this profile for \(AppWatcher.name(of: id))")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Menu {
                    let running = AppWatcher.runningApps.filter { !p.apps.contains($0.id) }
                    if !running.isEmpty {
                        Section("Running apps") {
                            ForEach(running, id: \.id) { a in
                                Button { store.addApp(a.id, to: p.id) } label: {
                                    if let icon = a.icon { Label { Text(a.name) } icon: { Image(nsImage: icon) } } else { Text(a.name) }
                                }
                            }
                        }
                    }
                    Button("Choose App…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        panel.prompt = "Add"
                        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
                            store.addApp(id, to: p.id)
                        }
                    }
                } label: {
                    Label(p.apps.isEmpty ? "Add App" : "Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("While this app is in front, this profile is on; it switches back when you leave it")
            }
        }
    }
}

// MARK: - ⌃⌥1…9 switch profiles

@MainActor
enum ProfileHotkeys {
    private static var refs: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "profileHotkeys") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "profileHotkeys"); newValue ? register() : unregister() }
    }

    /// Number-row vk codes 1…9 (same physical keys on AZERTY).
    private static let digitVKs: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func start() { if enabled { register() } }

    static func register() {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let index = Int(hk.id)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let store = ProfileStore.shared
                        let list = store.visible               // profiles of the keyboard shown in KeyForge
                        guard index < list.count else { return }
                        let p = list[index]
                        store.select(p.id)
                        ProfileHUD.show(p.name, reason: "Profile")
                    }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        for (i, vk) in digitVKs.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4B46484B), id: UInt32(i))   // 'KFHK'
            if RegisterEventHotKey(vk, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    static func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
    }
}

// MARK: - The little popup when the profile changes

@MainActor
enum ProfileHUD {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    /// Shows "Gaming · 🎮 Game: …" in the top-left corner, above everything (full-screen games included).
    static func show(_ name: String, reason: String) {
        let host = NSHostingView(rootView: HUDView(name: name, reason: reason)
            .environment(\.appTheme, ThemeStore.shared.rendered)
            .environment(\.glassTint, ThemeStore.shared.glassTint))
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            // above full-screen games (they can sit above the normal status-bar level)
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            return p
        }()
        panel = p
        p.contentView = host
        // the screen you're looking at: the one with the pointer
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let end = NSRect(x: screen.minX + 14, y: screen.maxY - size.height - 10, width: size.width, height: size.height)
        p.setFrame(end.offsetBy(dx: -24, dy: 0), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(end, display: true)
        }
        hide?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private struct HUDView: View {
        let name: String
        let reason: String
        @Environment(\.appTheme) private var theme
        var body: some View {
            let icon = reason.hasPrefix("🎮") ? "gamecontroller.fill" : reason.hasPrefix("🖥") ? "desktopcomputer" : "keyboard.fill"
            let detail = reason.replacingOccurrences(of: "🎮 ", with: "").replacingOccurrences(of: "🖥 ", with: "")
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(theme.purple)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 15, weight: .bold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 14).padding(.trailing, 18).padding(.vertical, 10)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Capsule().fill(Color.black.opacity(0.25)))   // stays readable over bright games
            .liquidGlass(Capsule())
            .padding(8)
        }
    }
}

// MARK: - Game Mode

/// One card: a switch, "In a game → X", "Everywhere else → Y", and what's happening right now.
struct GameModeCard: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.appTheme) private var theme

    var body: some View {
        let on = store.gameModeOn
        let profiles = store.visible
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Game Mode").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Toggle("Game Mode", isOn: Binding(get: { on }, set: { v in withAnimation { store.setGameMode(v) } }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if on {
                HStack(spacing: 18) {
                    choice("🎮 In a game", store.gameProfile, profiles) { store.gameProfile = $0; store.setGameMode(true) }
                    choice("🖥 Everywhere else", store.desktopProfile, profiles) { store.desktopProfile = $0; store.setGameMode(true) }
                    Spacer()
                }
                // live status
                HStack(spacing: 6) {
                    Circle().fill(store.frontApp?.isGame == true ? Color.green : theme.purple).frame(width: 7, height: 7)
                    if let f = store.frontApp {
                        Text("Now: \(store.active?.name ?? "–")").fontWeight(.semibold)
                        Text(f.isGame ? "because the game \(f.name) is in front" : "because \(f.name) is in front (not a game)")
                            .foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Waiting for an app to come to the front…").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
        .padding(18)
        .background(ForgePanel(cornerRadius: 20))
    }

    private func choice(_ title: String, _ current: UUID?, _ profiles: [Profile], set: @escaping (UUID?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            Menu {
                ForEach(profiles) { p in
                    Button { set(p.id) } label: { if current == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) } }
                }
            } label: {
                Text(store.profile(current)?.name ?? "Pick a profile").font(.callout.weight(.semibold))
            }
            .modifier(GlassMenuLabel())
        }
    }
}
