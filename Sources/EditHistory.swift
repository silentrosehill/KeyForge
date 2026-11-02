import Foundation
import Combine

/// Snapshot history for intentional profile edits. Continuous controls become one undo step.
@MainActor
final class EditHistory<Value: Equatable>: ObservableObject {
    private let manager = UndoManager()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoTitle = "Undo"
    @Published private(set) var redoTitle = "Redo"
    var read: (() -> Value)?
    var restore: ((Value) -> Void)?
    private var lastKey: String?
    private var lastTime = -Double.infinity

    init() { manager.groupsByEvent = false; manager.levelsOfUndo = 100 }

    func record(before: Value, after: Value, title: String, coalescing key: String? = nil,
                time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard before != after else { return }
        let joinsPrevious = key != nil && key == lastKey && time - lastTime < 0.7
            && manager.canUndo && !manager.canRedo
        if !joinsPrevious {
            manager.beginUndoGrouping()
            register(before, title: title)
            manager.endUndoGrouping()
        }
        lastKey = key; lastTime = time
        refresh()
    }

    private func register(_ snapshot: Value, title: String) {
        manager.registerUndo(withTarget: self) { history in
            guard let current = history.read?() else { return }
            history.register(current, title: title)
            history.restore?(snapshot)
        }
        manager.setActionName(title)
    }

    func undo() {
        guard manager.canUndo else { return }
        manager.undo(); lastKey = nil; lastTime = -Double.infinity; refresh()
    }

    func redo() {
        guard manager.canRedo else { return }
        manager.redo(); lastKey = nil; lastTime = -Double.infinity; refresh()
    }

    private func refresh() {
        canUndo = manager.canUndo; canRedo = manager.canRedo
        undoTitle = manager.undoMenuItemTitle; redoTitle = manager.redoMenuItemTitle
    }
}
