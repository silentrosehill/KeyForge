import AppKit
@main struct KeyBehaviorTests {
    @MainActor static func main() throws {
        let runtime = KeyBehaviorRuntime.shared
        let caps = HID.key(0x39), esc = HID.key(0x29), ctrl = HID.key(0xE0), space = HID.key(0x2C), a = HID.key(4), b = HID.key(5), c = HID.key(6)
        var outputs: [(Usage, Bool, CGEventFlags)] = []
        runtime.eventSink = { outputs.append(($0, $1, $2)) }
        func event(_ usage: Usage, down: Bool, flags: CGEventFlags = []) -> Bool {
            let vk = Keys.vk(for: KeyBehaviorRuntime.source(usage), iso: true)!
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(vk), keyDown: down)!
            e.flags = flags
            return runtime.handle(down ? .keyDown : .keyUp, e)
        }
        runtime.configure(dual: [caps: DualRoleBinding(tap: esc, hold: ctrl)], layers: [], iso: true)
        precondition(event(caps, down: true)); precondition(event(caps, down: false))
        precondition(outputs.map { $0.0 } == [esc, esc] && outputs.map { $0.1 } == [true, false])
        outputs = []
        _ = event(caps, down: true)
        precondition(!event(a, down: true))
        precondition(outputs.first?.0 == ctrl && outputs.first?.1 == true)
        _ = event(caps, down: false)
        precondition(outputs.last?.0 == ctrl && outputs.last?.1 == false && outputs.last?.2.contains(.maskControl) == false)
        outputs = []
        _ = event(caps, down: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        precondition(outputs.first?.0 == ctrl)
        runtime.reset()
        precondition(outputs.last?.1 == false && outputs.last?.2.contains(.maskControl) == false)
        outputs = []
        let layer = KeyboardLayer(name: "Navigation", trigger: space, bindings: [a: b, caps: c])
        runtime.configure(dual: [:], layers: [layer], iso: true, baseline: [a: c, caps: caps])
        precondition(event(a, down: true)); _ = event(a, down: false)
        precondition(outputs.first?.0 == c, "Base mapping lost while layer inactive")
        outputs = []
        _ = event(space, down: true)
        precondition(event(a, down: true, flags: .maskShift))
        _ = event(space, down: false)
        _ = event(a, down: false, flags: .maskShift)
        precondition(outputs.map { $0.0 } == [b, b], "Layer release failed to latch target")
        precondition(outputs.allSatisfy { $0.2.contains(.maskShift) }, "Physical Shift lost")
        outputs = []
        _ = event(space, down: true); _ = event(caps, down: true); _ = event(caps, down: false)
        precondition(outputs.map { $0.0 } == [c, c], "Caps carrier was not resolved")
        runtime.configure(dual: [:], layers: [], iso: true)
        precondition(!runtime.needed)
        print("Key behavior tests passed: tap, interrupt/timeout hold, modifier release/reset, inactive base mapping, latched layer release, physical Shift and Caps carrier")
    }
}
