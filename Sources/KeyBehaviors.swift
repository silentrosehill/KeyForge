import AppKit

struct DualRoleBinding: Codable, Equatable {
    var tap: Usage
    var hold: Usage
    var threshold: Double = 0.2
}
struct KeyboardLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var trigger: Usage
    var bindings: [Usage: Usage] = [:]
}

/// Actions and these behaviors share the session event tap, so they apply across keyboards.
@MainActor final class KeyBehaviorRuntime {
    static let shared = KeyBehaviorRuntime()
    private var dual: [Int: DualRoleBinding] = [:]
    private var layers: [KeyboardLayer] = []
    private var pending: [Int: (DualRoleBinding, Timer)] = [:]
    private var held: [Int: Usage] = [:]
    private var active: [Int: KeyboardLayer] = [:]
    private var routed: [Int: Usage] = [:]
    private var iso = true
    private var physicalFlags: CGEventFlags = []
    private var baseline: [Usage: Usage] = [:]
    private var capsCarrier = false
    var eventSink: ((Usage, Bool, CGEventFlags) -> Void)?
    private var configDual: [Usage: DualRoleBinding] = [:]
    var needed: Bool { !dual.isEmpty || !layers.isEmpty }
    static func source(_ usage: Usage) -> Usage { usage == HID.key(0x39) ? HID.key(0x6F) : usage }
    func configure(dual: [Usage: DualRoleBinding], layers: [KeyboardLayer], iso: Bool, baseline: [Usage: Usage] = [:]) {
        guard configDual != dual || self.layers != layers || self.iso != iso || self.baseline != baseline else { return }
        reset(); self.iso = iso; configDual = dual; self.layers = layers; self.baseline = baseline
        physicalFlags = ProcessInfo.processInfo.environment["KEYFORGE_DRY"] == nil ? CGEventSource.flagsState(.combinedSessionState) : []
        capsCarrier = dual[HID.key(0x39)] != nil || layers.contains { $0.trigger == HID.key(0x39) || $0.bindings[HID.key(0x39)] != nil }
        self.dual = Dictionary(dual.compactMap { u, b in Keys.vk(for: Self.source(u), iso: iso).map { ($0, b) } }, uniquingKeysWith: { _, b in b })
    }
    func reset() {
        pending.values.forEach { $0.1.invalidate() }; pending = [:]
        let heldValues = Array(held.values); held = [:]
        for value in heldValues { post(value, down: false) }
        for value in routed.values { post(value, down: false) }; routed = [:]; active = [:]
    }
    private var modifierFlags: CGEventFlags {
        held.values.reduce(into: CGEventFlags()) { result, usage in result.formUnion(Self.flag(usage)) }
    }
    private static func flag(_ usage: Usage) -> CGEventFlags {
        switch usage {
        case HID.key(0xE0), HID.key(0xE4): return .maskControl
        case HID.key(0xE1), HID.key(0xE5): return .maskShift
        case HID.key(0xE2), HID.key(0xE6): return .maskAlternate
        case HID.key(0xE3), HID.key(0xE7): return .maskCommand
        default: return []
        }
    }
    private func post(_ usage: Usage, down: Bool) {
        eventSink?(usage, down, physicalFlags.union(modifierFlags))
        guard let vk = Keys.vk(for: usage, iso: iso), ProcessInfo.processInfo.environment["KEYFORGE_DRY"] == nil,
              let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(vk), keyDown: down) else { return }
        let flag = Self.flag(usage)
        event.flags = physicalFlags.union(modifierFlags)
        if !flag.isEmpty { event.type = .flagsChanged }
        event.setIntegerValueField(.eventSourceUserData, value: KeyTap.marker)
        event.post(tap: .cghidEventTap)
    }
    private func promote(_ vk: Int) {
        guard let (binding, timer) = pending.removeValue(forKey: vk) else { return }
        timer.invalidate(); held[vk] = binding.hold; post(binding.hold, down: true)
    }
    /// Returns true when the source event was consumed. Key-up routes are latched at key-down.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let vk = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let down = type == .keyDown
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return false }
        if type == .flagsChanged {
            physicalFlags = event.flags
            event.flags.formUnion(modifierFlags); return false
        }
        physicalFlags.formUnion(event.flags.subtracting(modifierFlags))
        if down {
            let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if pending[vk] != nil || held[vk] != nil || active[vk] != nil { return true }
            for other in Array(pending.keys) where other != vk { promote(other) }
            if let binding = dual[vk] {
                guard !repeatKey else { return true }
                let timer = Timer(timeInterval: binding.threshold, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.promote(vk) }
                }
                pending[vk] = (binding, timer); RunLoop.main.add(timer, forMode: .common); return true
            }
            if let layer = layers.first(where: { Keys.vk(for: Self.source($0.trigger), iso: iso) == vk }) {
                active[vk] = layer; return true
            }
            if let target = routed[vk] { post(target, down: true); return true }
            let sourceUsage = capsCarrier && vk == Keys.vk(for: HID.key(0x6F), iso: iso) ? HID.key(0x39) : Keys.usage(forVK: vk, iso: iso)
            if let usage = sourceUsage,
               let target = layers.reversed().first(where: { layer in active.values.contains(where: { $0.id == layer.id }) && layer.bindings[usage] != nil })?.bindings[usage] {
                routed[vk] = target; post(target, down: true); return true
            }
            if let usage = sourceUsage, let target = baseline[usage], target != KeyBehaviorRuntime.source(usage) {
                routed[vk] = target; post(target, down: true); return true
            }
        } else {
            if let (binding, timer) = pending.removeValue(forKey: vk) {
                timer.invalidate(); post(binding.tap, down: true); post(binding.tap, down: false); return true
            }
            if let target = held.removeValue(forKey: vk) { post(target, down: false); return true }
            if active.removeValue(forKey: vk) != nil { return true }
            if let target = routed.removeValue(forKey: vk) { post(target, down: false); return true }
        }
        event.flags.formUnion(modifierFlags)
        return false
    }
}
