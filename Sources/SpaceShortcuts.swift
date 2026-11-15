import Foundation

@_silgen_name("CGSIsSymbolicHotKeyEnabled") private func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool
@_silgen_name("CGSSetSymbolicHotKeyEnabled") private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32

/// Game Mode: while a game is in front, macOS's Ctrl + arrow shortcuts (switch desktop left/right, Mission
/// Control, App Exposé) are turned off, so they reach the game instead of throwing you out of it.
/// macOS handles these before any app sees the keys, so they're switched off at the source and put back
/// when the game leaves the front, Game Mode goes off or KeyForge quits. Only shortcuts that were on are
/// touched, and the list is kept in UserDefaults so a crash is repaired at the next launch.
@MainActor
enum SpaceShortcuts {
    /// Mission Control 32/34, App Exposé 33/35, Move left a space 79/80, Move right a space 81/82.
    static let ids: [Int32] = [32, 33, 34, 35, 79, 80, 81, 82]
    private static let key = "spaceShortcutsDisabled"
    private static let dry = ProcessInfo.processInfo.environment["KEYFORGE_DRY"] != nil

    /// Whether Game Mode blocks the shortcuts at all (Settings switch, on by default).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "gameModeBlocksSpaces") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gameModeBlocksSpaces") }
    }

    private static var disabled: [Int32] {
        get { (UserDefaults.standard.array(forKey: key) as? [Int]).map { $0.map(Int32.init) } ?? [] }
        set { UserDefaults.standard.set(newValue.map(Int.init), forKey: key) }
    }

    static func setBlocked(_ blocked: Bool) {
        guard !dry else { return }
        if blocked && enabled {
            guard disabled.isEmpty else { return }
            let on = ids.filter { CGSIsSymbolicHotKeyEnabled($0) }
            disabled = on   // saved first, so a crash can still put them back
            for id in on { _ = CGSSetSymbolicHotKeyEnabled(id, false) }
            if !on.isEmpty { AutoSwitchLog.write("game: Ctrl+arrow shortcuts off \(on)") }
        } else {
            restore()
        }
    }

    /// Puts back what KeyForge turned off (also at launch, after a crash).
    static func restore() {
        guard !dry else { return }
        let off = disabled
        guard !off.isEmpty else { return }
        for id in off { _ = CGSSetSymbolicHotKeyEnabled(id, true) }
        disabled = []
        AutoSwitchLog.write("Ctrl+arrow shortcuts back on \(off)")
    }
}
