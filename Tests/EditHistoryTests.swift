import Foundation

@main
struct EditHistoryTests {
    @MainActor static func main() {
        let history = EditHistory<[Int]>()
        var value = [0]
        history.read = { value }
        history.restore = { value = $0 }
        func change(_ next: [Int], _ key: String? = nil, _ time: Double = 0) {
            let old = value; value = next
            history.record(before: old, after: value, title: "Edit", coalescing: key, time: time)
        }
        change([1]); precondition(history.canUndo && !history.canRedo)
        history.undo(); precondition(value == [0] && history.canRedo)
        history.redo(); precondition(value == [1] && !history.canRedo)
        change([2], "slider", 1); change([3], "slider", 1.2); change([4], "slider", 1.4)
        history.undo(); precondition(value == [1])
        history.redo(); precondition(value == [4])
        history.undo(); change([9], "slider", 1.5)
        precondition(!history.canRedo)
        history.undo(); precondition(value == [1])
        history.undo(); precondition(value == [0] && !history.canUndo)
        change([0]); precondition(!history.canUndo)
        change([5], "slider", 3); change([6], "slider", 4)
        history.undo(); precondition(value == [5])
        history.undo(); precondition(value == [0])
        print("History tests passed: undo, redo, slider grouping, branch edits, no-ops, separate gestures")
    }
}
