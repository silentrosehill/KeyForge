import SwiftUI
import AppKit
import IOKit.hid
import ServiceManagement

/// A named set of key changes for one keyboard.
struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// physical key → what it does now
    var map: [Usage: Usage] = [:]
    /// nil = the default purple
    var lighting: Lighting?
    /// physical key → shortcut / text / app / macro (done by KeyTap, needs Accessibility)
    var actions: [Usage: KeyAction] = [:]
    /// bundle IDs: this profile turns on by itself while one of these apps is in front
    var apps: [String] = []
    /// Which keyboard this profile is for (KeyboardDevice.key, or "all").
    var device: String = KeyboardDevice.allKey
}

extension Profile {
    // older profiles.json files don't have every field
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        map = try c.decodeIfPresent([Usage: Usage].self, forKey: .map) ?? [:]
        lighting = try c.decodeIfPresent(Lighting.self, forKey: .lighting)
        actions = (try? c.decodeIfPresent([Usage: KeyAction].self, forKey: .actions)) ?? [:]
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""     // "" = from before 1.7, fixed up on load
    }
}

/// A keyboard KeyForge has seen.
struct KeyboardDevice: Identifiable, Hashable {
    let key: String
    let name: String
    let vendor: Int
    let product: Int
    let builtIn: Bool
    var id: String { key }

    static let allKey = "all"
    static let huntsmanKey = key(0x1532, 0x026C)
    static func key(_ vendor: Int, _ product: Int) -> String { String(format: "%04x:%04x", vendor, product) }

    /// KeyForge can light it (the Razer protocol it speaks is tested on the Huntsman V2).
    var hasLighting: Bool { vendor == 0x1532 && product == 0x026C }

    var guessedLayout: LayoutKind {
        if vendor == 0x1532 && product == 0x026C { return .huntsman }
        if builtIn || vendor == 0x05AC { return .mac }
        let n = name.lowercased()
        if n.contains("tkl") || n.contains("tenkeyless") { return .tkl }
        if n.contains("60") || n.contains("mini") { return .sixty }
        return .full
    }
}

/// Per-keyboard drawing settings.
struct DeviceSettings: Codable, Equatable {
    var layout: LayoutKind
    var iso: Bool
}

/// Which keyboards the active profile applies to (only read from pre-1.7 files).
enum Scope: String, Codable { case huntsman, all }

/// Profiles for each keyboard, which one is on per keyboard, and pushing them to macOS with `hidutil`
/// (key remapping inside the HID event system: no driver, no Accessibility permission, works everywhere).
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [Profile] = [] {
        didSet {
            save()
            if oldValue.map(\.map) != profiles.map(\.map) { applyKeys() }
            let before = oldValue.first { $0.id == activeByDevice[lightingKey] }?.lighting
            if before != lightingProfile?.lighting { applyLighting() }
            if !loading { updateTap() }
        }
    }
    /// The keyboard shown in the app.
    @Published var device: String = KeyboardDevice.allKey { didSet { if !loading { saveSettingsOnly(); updateTap() } } }
    /// Which profile is on for each keyboard.
    @Published private(set) var activeByDevice: [String: UUID] = [:]
    /// Layout and ISO/ANSI per keyboard.
    @Published var settings: [String: DeviceSettings] = [:] { didSet { save(); updateTap() } }
    /// Names of keyboards seen before (so their profiles stay listed when unplugged).
    @Published private(set) var known: [String: String] = [:]
    @Published var enabled = true { didSet { save(); applyKeys() } }
    @Published private(set) var lastError: String?

    /// Per keyboard: the profile the user picked, and keyboards currently switched by the app in front.
    private var manualByDevice: [String: UUID] = [:]
    @Published private(set) var autoDevices: Set<String> = []

    let devices = DeviceWatcher()
    private var loading = false

    static var fileURL: URL {
        if let p = ProcessInfo.processInfo.environment["KEYFORGE_PROFILES"] { return URL(fileURLWithPath: p) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    private struct Saved: Codable {
        var profiles: [Profile]
        var enabled: Bool
        var activeByDevice: [String: UUID]?
        var settings: [String: DeviceSettings]?
        var known: [String: String]?
        var device: String?
        // before 1.7
        var activeID: UUID?
        var scope: Scope?
        var iso: Bool?
    }

    private init() {
        var migrated = false
        loading = true
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            profiles = s.profiles; enabled = s.enabled
            if let a = s.activeByDevice {
                activeByDevice = a
                settings = s.settings ?? [:]
                known = s.known ?? [:]
                device = s.device ?? KeyboardDevice.allKey
            } else {
                // 1.6 and older: one set of profiles for the Razer keyboard (or "All keyboards")
                let d = s.scope == .all ? KeyboardDevice.allKey : KeyboardDevice.huntsmanKey
                for i in profiles.indices where profiles[i].device.isEmpty { profiles[i].device = d }
                if let id = s.activeID { activeByDevice[d] = id }
                settings[KeyboardDevice.huntsmanKey] = DeviceSettings(layout: .huntsman, iso: s.iso ?? Keys.systemIsISO)
                known[KeyboardDevice.huntsmanKey] = "Razer Huntsman V2"
                device = d
                migrated = true
            }
        }
        for i in profiles.indices where profiles[i].device.isEmpty { profiles[i].device = KeyboardDevice.allKey }
        ensureProfile(for: device)
        for (d, id) in activeByDevice where !profiles.contains(where: { $0.id == id && $0.device == d }) {
            activeByDevice[d] = profiles.first { $0.device == d }?.id
        }
        manualByDevice = activeByDevice
        loading = false
        if migrated { saveNow() }   // write the new format right away
        updateTap()
        devices.onChange = { [weak self] in self?.devicesChanged() }   // plugged in / out: remember it, re-apply
        devices.start()
        apply()
    }

    private func devicesChanged() {
        var added = false
        for k in devices.keyboards where known[k.key] != k.name { known[k.key] = k.name; added = true }
        if added { save() }
        apply()
    }

    private var saveWork: DispatchWorkItem?

    /// Writes profiles.json shortly after the last change (dragging a slider changes it many times a second).
    private func save() {
        guard !loading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveSettingsOnly() { save() }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        let s = Saved(profiles: profiles, enabled: enabled, activeByDevice: activeByDevice, settings: settings, known: known, device: device)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    // MARK: Keyboards

    /// Keyboards to offer in the picker: connected ones, then ones that have profiles.
    var keyboardChoices: [(key: String, name: String, connected: Bool)] {
        var out: [(key: String, name: String, connected: Bool)] = []
        for k in devices.keyboards { out.append((k.key, k.name, true)) }
        let withProfiles = Set(profiles.map(\.device))
        for (key, name) in known.sorted(by: { $0.value < $1.value })
            where withProfiles.contains(key) && !out.contains(where: { $0.key == key }) {
            out.append((key, name, false))
        }
        return out
    }

    func name(of key: String) -> String {
        key == KeyboardDevice.allKey ? "All keyboards" : (devices.keyboards.first { $0.key == key }?.name ?? known[key] ?? "Keyboard")
    }

    var selectedDevice: KeyboardDevice? { devices.keyboards.first { $0.key == device } }
    var selectedConnected: Bool { device == KeyboardDevice.allKey || selectedDevice != nil }

    /// The Lighting tab is shown for keyboards KeyForge can light.
    var selectedHasLighting: Bool {
        device == KeyboardDevice.huntsmanKey || (selectedDevice?.hasLighting ?? false)
    }

    func selectDevice(_ key: String) {
        guard key != device else { return }
        device = key
        if settings[key] == nil, let d = devices.keyboards.first(where: { $0.key == key }) {
            settings[key] = DeviceSettings(layout: d.guessedLayout, iso: Keys.systemIsISO)
        }
        ensureProfile(for: key)
    }

    /// Every keyboard starts with one profile.
    private func ensureProfile(for key: String) {
        if !profiles.contains(where: { $0.device == key }) {
            var p = Profile(name: "Default")
            p.device = key
            profiles.append(p)
        }
        if activeByDevice[key] == nil { activeByDevice[key] = profiles.first { $0.device == key }?.id; manualByDevice[key] = activeByDevice[key] }
    }

    var layout: LayoutKind {
        get { settings[device]?.layout ?? (device == KeyboardDevice.allKey ? .full : (selectedDevice?.guessedLayout ?? .full)) }
        set { var s = settings[device] ?? DeviceSettings(layout: newValue, iso: iso); s.layout = newValue; settings[device] = s }
    }

    var iso: Bool {
        get { settings[device]?.iso ?? Keys.systemIsISO }
        set { var s = settings[device] ?? DeviceSettings(layout: layout, iso: newValue); s.iso = newValue; settings[device] = s }
    }

    // MARK: Profiles of the keyboard on screen

    /// Profiles of the keyboard shown in the app.
    var visible: [Profile] { profiles.filter { $0.device == device } }

    /// The profile that's on for the keyboard shown in the app (the one being edited).
    var activeID: UUID? {
        get { activeByDevice[device] }
        set { setActive(newValue, for: device) }
    }

    var active: Profile? { activeByDevice[device].flatMap { id in profiles.first { $0.id == id } } }
    var activeIndex: Int? { activeByDevice[device].flatMap { id in profiles.firstIndex { $0.id == id } } }
    var autoActive: Bool { autoDevices.contains(device) }

    private func setActive(_ id: UUID?, for key: String) {
        guard activeByDevice[key] != id else { return }
        activeByDevice[key] = id
        save(); apply(); updateTap()
    }

    func profile(_ id: UUID?) -> Profile? { id.flatMap { id in profiles.first { $0.id == id } } }

    /// The profile whose lighting the Razer keyboard shows.
    private var lightingKey: String { KeyboardDevice.huntsmanKey }
    var lightingProfile: Profile? { profile(activeByDevice[lightingKey]) }

    /// Actions of every keyboard's active profile (actions can't tell keyboards apart anyway).
    private func updateTap() {
        guard !loading else { return }
        var merged: [Usage: KeyAction] = profile(activeByDevice[KeyboardDevice.allKey])?.actions ?? [:]
        for (d, id) in activeByDevice where d != KeyboardDevice.allKey {
            for (k, a) in profile(id)?.actions ?? [:] { merged[k] = a }
        }
        KeyTap.shared.iso = iso
        if KeyTap.shared.actions != merged { KeyTap.shared.actions = merged }
    }

    // MARK: Switching

    /// The user picked a profile (sidebar, menu bar, hotkey).
    func select(_ id: UUID) {
        guard let p = profile(id) else { return }
        manualByDevice[p.device] = id
        autoDevices.remove(p.device)
        if device != p.device { selectDevice(p.device) }
        setActive(id, for: p.device)
    }

    /// The app in front changed: turn on the profiles made for it (on their keyboards), or go back to the
    /// user's picks. Returns a profile that just turned on (for the popup), if any.
    @discardableResult
    func frontAppChanged(_ bundleID: String?) -> Profile? {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return nil }   // opening KeyForge changes nothing
        var shown: Profile?
        let hits = profiles.filter { $0.apps.contains(bundleID) }
        for p in hits where activeByDevice[p.device] != p.id {
            if !autoDevices.contains(p.device) { manualByDevice[p.device] = activeByDevice[p.device] }
            autoDevices.insert(p.device)
            activeByDevice[p.device] = p.id
            shown = p
        }
        for d in autoDevices where !hits.contains(where: { $0.device == d }) {
            autoDevices.remove(d)
            if let back = manualByDevice[d], profile(back) != nil {
                activeByDevice[d] = back
                shown = shown ?? profile(back)
            }
        }
        if shown != nil { save(); apply(); updateTap() }
        return shown
    }

    func addApp(_ bundleID: String, to id: UUID) {
        guard let dev = profile(id)?.device else { return }
        for i in profiles.indices where profiles[i].device == dev { profiles[i].apps.removeAll { $0 == bundleID } }   // one app → one profile per keyboard
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].apps.append(bundleID)
    }

    func removeApp(_ bundleID: String, from id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].apps.removeAll { $0 == bundleID }
    }

    // MARK: Editing

    func set(_ key: Usage, to target: Usage?) {
        guard let i = activeIndex else { return }
        profiles[i].actions[key] = nil
        if let target, target != key { profiles[i].map[key] = target } else { profiles[i].map[key] = nil }
    }

    /// Gives a key a shortcut / text / app / macro job (replaces any plain key change on it).
    func setAction(_ key: Usage, _ action: KeyAction?) {
        guard let i = activeIndex else { return }
        profiles[i].map[key] = nil
        profiles[i].actions[key] = action
    }

    func resetActive() {
        guard let i = activeIndex else { return }
        profiles[i].map = [:]
        profiles[i].actions = [:]
    }

    @discardableResult
    func addProfile(name: String = "New Profile", copying: Profile? = nil) -> Profile {
        var p = Profile(name: uniqueName(copying.map { "\($0.name) Copy" } ?? name))
        p.device = device
        if let copying { p.map = copying.map; p.lighting = copying.lighting; p.actions = copying.actions }
        profiles.append(p)
        select(p.id)
        return p
    }

    func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = n
    }

    func delete(_ id: UUID) {
        guard let p = profile(id), profiles.filter({ $0.device == p.device }).count > 1,
              let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: i)
        if activeByDevice[p.device] == id, let next = profiles.first(where: { $0.device == p.device }) { select(next.id) }
    }

    /// Reorders within the keyboard on screen (the sidebar's drag and drop).
    func moveVisible(from offsets: IndexSet, to dest: Int) {
        var vis = visible
        vis.move(fromOffsets: offsets, toOffset: dest)
        profiles = profiles.filter { $0.device != device } + vis
    }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while visible.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    // MARK: Presets

    enum Preset: String, CaseIterable, Identifiable {
        case macModifiers = "Mac modifiers (Alt ⌘, Win ⌥)"
        case capsToEsc = "Caps Lock → Esc"
        case mediaOnF = "Media on F7–F12"
        case noWin = "Disable Win keys (gaming)"
        var id: String { rawValue }
    }

    func apply(preset: Preset) {
        guard let i = activeIndex else { return }
        switch preset {
        case .macModifiers:
            profiles[i].map[HID.key(0xE2)] = HID.key(0xE3); profiles[i].map[HID.key(0xE3)] = HID.key(0xE2)
            profiles[i].map[HID.key(0xE6)] = HID.key(0xE7)
        case .capsToEsc:
            profiles[i].map[HID.key(0x39)] = HID.key(0x29)
        case .mediaOnF:
            let t: [(UInt64, UInt64)] = [(0x40, 0xB6), (0x41, 0xCD), (0x42, 0xB5), (0x43, 0xE2), (0x44, 0xEA), (0x45, 0xE9)]
            for (f, m) in t { profiles[i].map[HID.key(f)] = HID.consumer(m) }
        case .noWin:
            profiles[i].map[HID.key(0xE3)] = HID.none; profiles[i].map[HID.key(0xE7)] = HID.none
        }
    }

    // MARK: Applying

    static let razerVendor = 0x1532
    static let huntsmanV2Product = 0x026C

    /// Pushes every keyboard's active profile (keys) and the Razer keyboard's lighting.
    func apply() {
        applyKeys()
        applyLighting()
    }

    func applyLighting() {
        guard !loading else { return }
        let iso = settings[lightingKey]?.iso ?? Keys.systemIsISO
        LightingEngine.shared.update(lightingProfile?.lighting ?? .standard, product: devices.productID, iso: iso)
    }

    func setLighting(_ l: Lighting) {
        guard let i = activeIndex else { return }
        profiles[i].lighting = l
    }

    private static func json(_ map: [Usage: Usage]) -> String {
        let entries = map.sorted { $0.key < $1.key }.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.key),\"HIDKeyboardModifierMappingDst\":\($0.value)}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    /// "All keyboards" goes on every keyboard first; then each connected keyboard gets its own profile on top.
    func applyKeys() {
        guard !loading else { return }
        let global = enabled ? (profile(activeByDevice[KeyboardDevice.allKey])?.map ?? [:]) : [:]
        var err = Self.hidutil(["property", "--set", Self.json(global)])
        if enabled {
            var done = Set<String>()
            for k in devices.keyboards where !done.contains(k.key) {
                done.insert(k.key)
                guard let p = profile(activeByDevice[k.key]), !p.map.isEmpty else { continue }
                let merged = global.merging(p.map) { _, mine in mine }
                let match = "{\"VendorID\":\(k.vendor),\"ProductID\":\(k.product)}"
                err = Self.hidutil(["property", "--matching", match, "--set", Self.json(merged)]) ?? err
            }
        }
        lastError = err
    }

    /// Clears every mapping this app made (used on "Turn off" and when quitting with remapping off).
    static func clearAll() {
        _ = hidutil(["property", "--set", "{\"UserKeyMapping\":[]}"])
    }

    @discardableResult
    nonisolated static func hidutil(_ args: [String]) -> String? {
        if ProcessInfo.processInfo.environment["KEYFORGE_DRY"] != nil { return nil }   // screenshots/tests: never touch the real keyboard
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return msg.isEmpty ? "hidutil failed (\(p.terminationStatus))" : msg
        }
        return nil
    }

    // MARK: Open at login

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { lastError = "Open at login: \(error.localizedDescription)" }
        }
    }
}

/// Watches every keyboard being plugged in or out (no Input Monitoring needed: devices aren't opened).
@MainActor
final class DeviceWatcher: ObservableObject {
    /// Connected keyboards, one entry per model.
    @Published private(set) var keyboards: [KeyboardDevice] = []
    /// The Razer keyboard KeyForge lights (Huntsman V2), if connected.
    @Published private(set) var name: String?
    @Published private(set) var productID: Int?
    var onChange: (() -> Void)?

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var pending: DispatchWorkItem?

    /// Mice and receivers often expose a keyboard interface too; don't list them as keyboards.
    private static let notKeyboards = ["mouse", "dock", "dongle", "trackpad", "viper", "deathadder", "basilisk", "naga",
                                       "g203", "g305", "g502", "mx master", "mx anywhere", "trackball"]

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            let me = Unmanaged<DeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            let me = Unmanaged<DeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = m
    }

    private func added(_ d: IOHIDDevice) {
        devices.append(d)
        refresh()
    }

    private func removed(_ d: IOHIDDevice) {
        devices.removeAll { $0 === d }
        refresh()
    }

    private func refresh() {
        var list: [KeyboardDevice] = []
        for d in devices {
            func prop<T>(_ k: String) -> T? { IOHIDDeviceGetProperty(d, k as CFString) as? T }
            let transport: String = prop(kIOHIDTransportKey) ?? ""
            guard transport.lowercased() != "virtual" else { continue }
            let vendor: Int = prop(kIOHIDVendorIDKey) ?? 0, product: Int = prop(kIOHIDProductIDKey) ?? 0
            let builtIn: Bool = prop(kIOHIDBuiltInKey) ?? false
            var name: String = prop(kIOHIDProductKey) ?? "Keyboard"
            if builtIn || name.contains("Internal Keyboard") { name = "Built-in Keyboard" }
            let lower = name.lowercased()
            guard !Self.notKeyboards.contains(where: { lower.contains($0) }) else { continue }
            let k = KeyboardDevice(key: KeyboardDevice.key(vendor, product), name: name, vendor: vendor, product: product, builtIn: builtIn)
            if !list.contains(where: { $0.key == k.key }) { list.append(k) }
        }
        // Razer first, built-in last
        list.sort { ($0.builtIn ? 2 : $0.vendor == 0x1532 ? 0 : 1, $0.name) < ($1.builtIn ? 2 : $1.vendor == 0x1532 ? 0 : 1, $1.name) }
        let lit = list.first { $0.hasLighting }
        let changed = list != keyboards
        keyboards = list
        name = lit?.name
        productID = lit?.product
        // the HID services appear a moment after the device: re-apply shortly after any change
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (changed ? 0.8 : 0.4), execute: work)
    }
}
