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
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated {
                if let p = ProfileStore.shared.frontAppChanged(id) { ProfileHUD.show(p.name, auto: ProfileStore.shared.autoActive) }
            }
        }
        // the app already in front when KeyForge starts
        ProfileStore.shared.frontAppChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Apps worth offering in the "+" menu: what's running with a Dock icon.
    static var runningApps: [(name: String, id: String, icon: NSImage?)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { ($0.localizedName ?? $0.bundleIdentifier!, $0.bundleIdentifier!, $0.icon) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(of bundleID: String) -> NSImage {
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
                Text(p.apps.isEmpty ? "Turns on by itself for:" : "Turns on for").font(.callout).foregroundStyle(.secondary)
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
                if store.autoActive {
                    Text("· on because of the app in front").font(.caption).foregroundStyle(.secondary)
                }
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
                        ProfileHUD.show(p.name, auto: false)
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

    static func show(_ name: String, auto: Bool) {
        let host = NSHostingView(rootView: HUDView(name: name, auto: auto)
            .environment(\.appTheme, ThemeStore.shared.rendered)
            .environment(\.glassTint, ThemeStore.shared.glassTint))
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return p
        }()
        panel = p
        p.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 110, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        hide?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private struct HUDView: View {
        let name: String
        let auto: Bool
        @Environment(\.appTheme) private var theme
        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "keyboard.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 17, weight: .bold))
                    Text(auto ? "Switched for the app in front" : "Profile").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .liquidGlass(Capsule())
            .padding(10)
        }
    }
}
