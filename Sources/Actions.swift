import SwiftUI
import AppKit
import Carbon

// MARK: - What a key can do besides becoming another key

/// A key combination, e.g. ⌘⇧4.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt16
    /// CGEventFlags raw value (only the ⌘⌥⌃⇧ bits)
    var modifiers: UInt64

    static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    init(event: NSEvent) {
        var m: UInt64 = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= CGEventFlags.maskCommand.rawValue }
        if f.contains(.option) { m |= CGEventFlags.maskAlternate.rawValue }
        if f.contains(.control) { m |= CGEventFlags.maskControl.rawValue }
        if f.contains(.shift) { m |= CGEventFlags.maskShift.rawValue }
        self.init(keyCode: event.keyCode, modifiers: m)
    }

    /// "⌃⌥⇧⌘K"
    func label(iso: Bool) -> String {
        var s = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        let key = Keys.usage(forVK: Int(keyCode), iso: iso).map { Keys.legend($0, iso: iso).main } ?? "key \(keyCode)"
        return s + key
    }
}

enum MacroStep: Codable, Hashable {
    case shortcut(Shortcut)
    case text(String)
    case wait(Double)

    func label(iso: Bool) -> String {
        switch self {
        case .shortcut(let s): return s.label(iso: iso)
        case .text(let t): return "“\(t)”"
        case .wait(let d): return String(format: "wait %.1fs", d)
        }
    }
}

enum KeyAction: Codable, Hashable {
    case shortcut(Shortcut)
    case text(String)
    /// path of an .app
    case app(String)
    case macro([MacroStep])

    var kind: Kind {
        switch self {
        case .shortcut: .shortcut
        case .text: .text
        case .app: .app
        case .macro: .macro
        }
    }

    enum Kind: String, CaseIterable { case key = "Key", shortcut = "Shortcut", text = "Type Text", app = "Open App", macro = "Macro" }

    /// Short text for keycaps and lists.
    func label(iso: Bool) -> String {
        switch self {
        case .shortcut(let s): return s.label(iso: iso)
        case .text(let t): return t.isEmpty ? "Text" : "“\(t)”"
        case .app(let path): return path.isEmpty ? "App" : FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        case .macro(let steps): return steps.isEmpty ? "Macro" : "Macro · \(steps.count)"
        }
    }

    var icon: String {
        switch self {
        case .shortcut: "command"
        case .text: "text.cursor"
        case .app: "app.badge"
        case .macro: "list.bullet.rectangle"
        }
    }
}

// MARK: - The event tap: runs actions, reports key presses (Ripple / Heatmap)

/// Watches key presses system-wide. Needs Accessibility (System Settings → Privacy & Security).
/// Actions work on every keyboard: macOS doesn't say which keyboard a key press came from.
@MainActor
final class KeyTap: ObservableObject {
    static let shared = KeyTap()

    /// physical key → action, from the active profile
    var actions: [Usage: KeyAction] = [:] { didSet { rebuild(); ensureRunning() } }
    /// ISO/ANSI (set by ProfileStore; asking ProfileStore.shared here would recurse while it's still loading)
    var iso = true { didSet { if iso != oldValue { rebuild() } } }
    /// Someone (Ripple, Heatmap) wants to hear key presses.
    var listeners: [String: (Usage) -> Void] = [:] { didSet { ensureRunning() } }

    @Published private(set) var trusted = KeyTap.hasAccess
    @Published private(set) var running = false

    /// Marks events KeyForge posts itself so the tap lets them through.
    nonisolated static let marker: Int64 = 0x4B46_4B46
    /// vk code → action (what the tap callback looks up)
    nonisolated(unsafe) private static var byVK: [Int64: KeyAction] = [:]
    nonisolated(unsafe) private static var tap: CFMachPort?
    private var trustTimer: Timer?

    var needed: Bool { !actions.isEmpty || !listeners.isEmpty }

    private func rebuild() {
        var m: [Int64: KeyAction] = [:]
        for (u, a) in actions { if let vk = Keys.vk(for: u, iso: iso) { m[Int64(vk)] = a } }
        Self.byVK = m
    }

    /// Either check can lag behind System Settings; if any says yes, try it.
    nonisolated static var hasAccess: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    /// Asks macOS for Accessibility (shows the system prompt / opens Settings).
    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        _ = CGRequestPostEventAccess()
        recheck()
        watchTrust()
    }

    /// Clears KeyForge's Accessibility entry (e.g. one left from an older build that no longer matches)
    /// and asks again, so the switch in System Settings is the one for this copy of the app.
    func resetAndRequest() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "local.keyforge"]
        try? p.run()
        p.waitUntilExit()
        requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Re-reads the permission; the tap itself is the real test (it can only be created with access).
    func recheck() {
        if Self.tap != nil { trusted = true; return }
        trusted = Self.hasAccess
        if needed { startTap() }
    }

    private func watchTrust() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.recheck()
                if self.trusted { t.invalidate(); self.trustTimer = nil }
            }
        }
    }

    /// Checks again whenever KeyForge comes to the front (e.g. back from System Settings).
    func watchActivation() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyTap.shared.recheck() }
        }
    }

    func ensureRunning() {
        guard needed else { trusted = Self.tap != nil || Self.hasAccess; return }
        startTap()
        if !trusted { watchTrust() }
    }

    private func startTap() {
        guard Self.tap == nil else { trusted = true; return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            KeyTap.handle(type, event)
        }, userInfo: nil) else { trusted = false; return }   // no tap = no access, whatever the checks said
        Self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true
        trusted = true
    }

    nonisolated private static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }
        let vk = event.getIntegerValueField(.keyboardEventKeycode)
        let action = byVK[vk]
        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let shared = KeyTap.shared
                        if let u = Keys.usage(forVK: Int(vk), iso: shared.iso) {
                            for l in shared.listeners.values { l(u) }
                        }
                        if let action { ActionRunner.run(action) }
                    }
                }
            }
        }
        return action == nil ? Unmanaged.passUnretained(event) : nil   // the key's own letter is swallowed
    }
}

/// Performs actions by posting keyboard events / opening apps.
enum ActionRunner {
    private static let queue = DispatchQueue(label: "keyforge.actions")

    @MainActor
    static func run(_ a: KeyAction) {
        switch a {
        case .shortcut(let s): queue.async { post(s) }
        case .text(let t): queue.async { type(t) }
        case .app(let path):
            guard !path.isEmpty else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case .macro(let steps):
            queue.async {
                for step in steps {
                    switch step {
                    case .shortcut(let s): post(s)
                    case .text(let t): type(t)
                    case .wait(let d): Thread.sleep(forTimeInterval: min(max(d, 0), 10))
                    }
                    Thread.sleep(forTimeInterval: 0.03)
                }
            }
        }
    }

    private static func post(_ s: Shortcut) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: s.keyCode, keyDown: down) else { continue }
            e.flags = CGEventFlags(rawValue: s.modifiers)
            e.setIntegerValueField(.eventSourceUserData, value: KeyTap.marker)
            e.post(tap: .cghidEventTap)
            usleep(8000)
        }
    }

    private static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.setIntegerValueField(.eventSourceUserData, value: KeyTap.marker)
                e.post(tap: .cghidEventTap)
            }
            usleep(12000)
            i += 16
        }
    }
}

/// How often each key is pressed (for the Heatmap effect). Counted only while Heatmap is chosen.
@MainActor
final class Heatmap: ObservableObject {
    static let shared = Heatmap()
    @Published private(set) var counts: [Usage: Int] = {
        guard let d = UserDefaults.standard.dictionary(forKey: "heatmap") as? [String: Int] else { return [:] }
        var m: [Usage: Int] = [:]
        for (k, v) in d { if let u = UInt64(k) { m[u] = v } }
        return m
    }()
    private var dirty = false

    func press(_ u: Usage) {
        counts[u, default: 0] += 1
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.persist() }
    }

    func reset() { counts = [:]; persist() }

    private func persist() {
        dirty = false
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) }), forKey: "heatmap")
    }
}

// MARK: - Editor UI (in the key card)

/// Shortcut / text / app / macro editor for the selected key.
struct ActionEditor: View {
    @ObservedObject var store: ProfileStore
    let key: Usage
    @ObservedObject private var tap = KeyTap.shared
    @ObservedObject private var live = LiveKeys.shared
    @StateObject private var draft = Draft()

    final class Draft: ObservableObject {
        @Published var text = ""
        @Published var stepText = ""
    }

    private var action: KeyAction? { store.active?.actions[key] }

    var body: some View {
        let kind = action?.kind ?? .key
        VStack(alignment: .leading, spacing: 12) {
            GlassSegmented(selection: Binding(get: { kind }, set: { k in switchKind(k) }),
                           options: KeyAction.Kind.allCases.map { ($0, $0.rawValue) })
                .frame(maxWidth: 560)

            switch action {
            case .shortcut(let s):
                HStack(spacing: 10) {
                    Text("Sends").foregroundStyle(.secondary)
                    Text(s.keyCode == 0 && s.modifiers == 0 ? "—" : s.label(iso: store.iso))
                        .font(.body.monospaced().weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    recordButton { store.setAction(key, .shortcut($0)) }
                }
            case .text(let t):
                HStack(spacing: 10) {
                    Text("Types").foregroundStyle(.secondary)
                    TextField("Text to type", text: Binding(get: { t }, set: { store.setAction(key, .text($0)) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 380)
                }
            case .app(let path):
                HStack(spacing: 10) {
                    Text("Opens").foregroundStyle(.secondary)
                    if !path.isEmpty {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
                        Text(KeyAction.app(path).label(iso: store.iso)).fontWeight(.semibold)
                    }
                    Button(path.isEmpty ? "Choose App…" : "Change…") { chooseApp { store.setAction(key, .app($0)) } }
                        .buttonStyle(.purpleGlass)
                }
            case .macro(let steps):
                macroEditor(steps)
            case nil:
                EmptyView()
            }

            if action != nil && !tap.trusted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("KeyForge needs Accessibility to do this. It works on every keyboard.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Allow…") { tap.requestAccess() }.buttonStyle(.purpleGlassProminent)
                    Button("Reset permission") { tap.resetAndRequest() }.buttonStyle(.link)
                        .help("Already switched on? This clears the old entry and asks again")
                }
            }
        }
    }

    private func switchKind(_ k: KeyAction.Kind) {
        live.recorder = nil; live.shortcutRecorder = nil
        switch k {
        case .key: store.setAction(key, nil)
        case .shortcut: store.setAction(key, .shortcut(Shortcut(keyCode: 0, modifiers: 0))); startRecording { store.setAction(key, .shortcut($0)) }
        case .text: store.setAction(key, .text(""))
        case .app: store.setAction(key, .app("")); chooseApp { store.setAction(key, .app($0)) }
        case .macro: store.setAction(key, .macro([]))
        }
        if k != .key { tap.ensureRunning(); if !tap.trusted { tap.requestAccess() } }
    }

    private func recordButton(_ done: @escaping (Shortcut) -> Void) -> some View {
        let recording = live.shortcutRecorder != nil
        return Button {
            if recording { live.shortcutRecorder = nil } else { startRecording(done) }
        } label: {
            Label(recording ? "Press the shortcut…" : "Record", systemImage: recording ? "record.circle.fill" : "record.circle")
        }
        .buttonStyle(.purpleGlassProminent)
    }

    private func startRecording(_ done: @escaping (Shortcut) -> Void) {
        live.shortcutRecorder = { s in withAnimation { done(s) } }
    }

    private func chooseApp(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }

    @ViewBuilder private func macroEditor(_ steps: [MacroStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Runs").foregroundStyle(.secondary)
                if steps.isEmpty { Text("nothing yet: add steps below").foregroundStyle(.secondary) }
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 4) {
                        Text(step.label(iso: store.iso)).lineLimit(1)
                        Button {
                            var s = steps; s.remove(at: i); store.setAction(key, .macro(s))
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                    }
                    .font(.callout)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    if i < steps.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            HStack(spacing: 8) {
                recordButton { s in store.setAction(key, .macro(steps + [.shortcut(s)])) }
                    .help("Add a shortcut step: press it after clicking")
                TextField("Text step", text: $draft.stepText)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { addText(steps) }
                Button("Add Text") { addText(steps) }.buttonStyle(.purpleGlass).disabled(draft.stepText.isEmpty)
                Button("Add Wait") { store.setAction(key, .macro(steps + [.wait(0.3)])) }.buttonStyle(.purpleGlass)
                    .help("Pause 0.3 s between steps")
            }
        }
    }

    private func addText(_ steps: [MacroStep]) {
        guard !draft.stepText.isEmpty else { return }
        store.setAction(key, .macro(steps + [.text(draft.stepText)]))
        draft.stepText = ""
    }
}
