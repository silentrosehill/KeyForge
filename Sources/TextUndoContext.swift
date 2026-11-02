import AppKit
import Combine

/// Keeps menu validation in sync with native field editors, including sheets.
@MainActor
final class TextUndoContext: ObservableObject {
    static let shared = TextUndoContext()
    struct State: Equatable {
        var editing = false
        var canUndo = false
        var canRedo = false
    }
    @Published private(set) var state = State()
    private var queued = false
    private var observers: [NSObjectProtocol] = []

    var manager: UndoManager? { editor?.undoManager }
    private var editor: NSTextView? {
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let window = host.attachedSheet ?? host
        if let text = window.firstResponder as? NSTextView, text.isEditable { return text }
        if let field = window.firstResponder as? NSTextField, field.isEditable {
            return field.currentEditor() as? NSTextView
        }
        return nil
    }

    private init() {
        let names: [Notification.Name] = [
            NSControl.textDidBeginEditingNotification, NSControl.textDidChangeNotification,
            NSControl.textDidEndEditingNotification, NSText.didChangeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerWillCloseUndoGroup
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
    }

    private func scheduleRefresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in self?.queued = false; self?.refresh() }
    }

    func refresh() {
        let text = editor
        if let text, !text.allowsUndo { text.allowsUndo = true }
        let next = State(editing: text != nil, canUndo: text?.undoManager?.canUndo ?? false,
                         canRedo: text?.undoManager?.canRedo ?? false)
        if state != next { state = next }
    }
}
