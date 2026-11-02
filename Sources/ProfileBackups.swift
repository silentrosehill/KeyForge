import Foundation
import SwiftUI

/// Versioned snapshots of the complete profiles.json file, stored beside that file.
@MainActor
final class ProfileBackups: ObservableObject {
    struct Entry: Identifiable {
        let id: URL
        let date: Date
    }
    private struct Archive: Codable {
        let type: String
        let version: Int
        let date: Date
        let payload: Data
    }
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "This backup is damaged or from an unsupported version." }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var message: String?
    private let directory: URL
    private var pending: DispatchWorkItem?
    private var lastData: Data?
    private let retention: Int
    private let dailyRetention: Int

    init(fileURL: URL, retention: Int = 20, dailyRetention: Int = 14) {
        directory = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".backups", isDirectory: true)
        self.retention = max(1, retention)
        self.dailyRetention = max(0, dailyRetention)
        refresh()
    }

    /// Save bursts (including slider changes) settle before a snapshot is made.
    func schedule(_ data: Data) {
        lastData = data
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = self.lastData else { return }
            do { try self.create(data) } catch { self.message = "Could not create a backup: \(error.localizedDescription)" }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func cancelPending() { pending?.cancel(); pending = nil; lastData = nil }

    /// Used before a restore; failure must prevent replacing the current state.
    func create(_ data: Data, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = Archive(type: "keyforge-backup", version: 1, date: date, payload: data)
        let bytes = try JSONEncoder().encode(archive)
        let url = directory.appendingPathComponent("backup-\(UUID().uuidString).json")
        try bytes.write(to: url, options: .atomic)
        refresh()
        // Keep the most recent snapshots plus the latest snapshot of each previous
        // calendar day in the retention window. Calendar arithmetic handles DST.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -dailyRetention, to: today) ?? today
        var keep = Set(entries.prefix(retention).map(\.id))
        var days = Set<Date>()
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if day >= earliest && day < today && days.insert(day).inserted { keep.insert(entry.id) }
        }
        for entry in entries where !keep.contains(entry.id) { try? FileManager.default.removeItem(at: entry.id) }
        refresh()
    }

    func read(_ entry: Entry) throws -> Data {
        // Only entries in this backup directory may be restored.
        guard entry.id.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { throw Failure.invalid }
        let data = try Data(contentsOf: entry.id)
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.type == "keyforge-backup", archive.version == 1, !archive.payload.isEmpty else { throw Failure.invalid }
        return archive.payload
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        entries = urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let archive = try? JSONDecoder().decode(Archive.self, from: data),
                  archive.type == "keyforge-backup", archive.version == 1 else { return nil }
            return Entry(id: url, date: archive.date)
        }.sorted { $0.date > $1.date }
    }
}

/// Compact settings control; restoring requires an explicit confirmation.
struct ProfileBackupsView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject private var backups: ProfileBackups
    private final class Selection: ObservableObject { @Published var entry: ProfileBackups.Entry? }
    @StateObject private var selection = Selection()

    init(store: ProfileStore) {
        self.store = store
        self.backups = store.backups
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile backups")
                Text("Automatic snapshots of profiles and settings").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Restore…") {
                if backups.entries.isEmpty { Text("No backups yet") }
                ForEach(backups.entries) { entry in
                    Button(entry.date.formatted(date: .abbreviated, time: .shortened)) { selection.entry = entry }
                }
            }.disabled(backups.entries.isEmpty)
        }
        .alert("Restore backup?", isPresented: Binding(get: { selection.entry != nil }, set: { if !$0 { selection.entry = nil } })) {
            Button("Restore", role: .destructive) {
                if let entry = selection.entry {
                    do { try store.restoreBackup(entry); backups.message = "Backup restored. Your previous settings were backed up." }
                    catch { backups.message = "Could not restore backup: \(error.localizedDescription)" }
                }
                selection.entry = nil
            }
            Button("Cancel", role: .cancel) { selection.entry = nil }
        } message: { Text("This replaces the current profiles and settings. A safety backup is saved first.") }
        .alert("Profile Backups", isPresented: Binding(get: { backups.message != nil }, set: { if !$0 { backups.message = nil } })) {
            Button("OK") { backups.message = nil }
        } message: { Text(backups.message ?? "") }
    }
}
