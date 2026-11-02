import Foundation

@main
struct ProfileBackupsTests {
    @MainActor static func main() throws {
        let store = ProfileStore.shared
        store.rename(store.activeID!, to: "Before")
        store.iso = false
        store.saveNow()
        let before = store.profiles
        let beforeBytes = try Data(contentsOf: ProfileStore.fileURL)
        try store.backups.create(beforeBytes)
        let snapshot = store.backups.entries.first!
        store.rename(store.activeID!, to: "After")
        store.enabled = false
        store.iso = true
        store.saveNow()
        try store.restoreBackup(snapshot)
        precondition(store.profiles == before && store.enabled && !store.iso)
        precondition(!store.history.canUndo && !store.history.canRedo)
        precondition(store.backups.entries.count >= 2)
        let safety = try store.backups.read(store.backups.entries.first!)
        let safetyJSON = try JSONSerialization.jsonObject(with: safety) as! [String: Any]
        precondition(safetyJSON["enabled"] as? Bool == false)
        let disk = try Data(contentsOf: ProfileStore.fileURL)
        try store.backups.create(Data("invalid".utf8))
        let bad = store.backups.entries.first!
        do { try store.restoreBackup(bad); preconditionFailure("Invalid backup restored") } catch {}
        let diskAfterRejection = try Data(contentsOf: ProfileStore.fileURL)
        precondition(store.profiles == before && diskAfterRejection == disk)
        let dir = ProfileStore.fileURL.deletingLastPathComponent().appendingPathComponent("retention.json")
        let limited = ProfileBackups(fileURL: dir, retention: 2, dailyRetention: 0)
        for n in 0..<4 { try limited.create(Data("\(n)".utf8)) }
        precondition(limited.entries.count == 2)
        let reopened = ProfileBackups(fileURL: dir, retention: 2, dailyRetention: 0)
        precondition(reopened.entries.count == 2)
        let datedFile = ProfileStore.fileURL.deletingLastPathComponent().appendingPathComponent("dated.json")
        let dated = ProfileBackups(fileURL: datedFile, retention: 3, dailyRetention: 14)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        try dated.create(Data("old".utf8), date: day(-15).addingTimeInterval(3600))
        try dated.create(Data("day14".utf8), date: day(-14).addingTimeInterval(3600))
        try dated.create(Data("yesterday-early".utf8), date: day(-1).addingTimeInterval(3600))
        try dated.create(Data("yesterday-late".utf8), date: day(-1).addingTimeInterval(7200))
        for n in 0..<4 { try dated.create(Data("today\(n)".utf8), date: today.addingTimeInterval(Double(n))) }
        let kept = try Set(dated.entries.map { String(decoding: try dated.read($0), as: UTF8.self) })
        precondition(kept == ["day14", "yesterday-late", "today1", "today2", "today3"])
        let autoFile = ProfileStore.fileURL.deletingLastPathComponent().appendingPathComponent("automatic.json")
        let automatic = ProfileBackups(fileURL: autoFile)
        automatic.schedule(Data("first".utf8))
        automatic.schedule(Data("last".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        precondition(automatic.entries.count == 1)
        let latest = try automatic.read(automatic.entries[0])
        precondition(latest == Data("last".utf8))
        let reopenedAuto = ProfileBackups(fileURL: autoFile)
        precondition(reopenedAuto.entries.count == 1)
        print("Backup tests passed: complete restore, safety copy, invalid rejection, history reset, debouncing, retention and reopening")
    }
}
