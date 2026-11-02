import SwiftUI
import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    @Published var automaticChecks = UserDefaults.standard.bool(forKey: "automaticUpdateChecks") {
        didSet {
            UserDefaults.standard.set(automaticChecks, forKey: "automaticUpdateChecks")
            configureTimer()
        }
    }
    private var controller: SPUStandardUpdaterController?
    private var timer: Timer?
    private var started = false

    private struct Release: Decodable {
        var tag_name: String
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
    }

    func start() {
        guard !started else { return }
        started = true
        configureTimer()
    }

    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard automaticChecks, ProcessInfo.processInfo.environment["KEYFORGE_DRY"] == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        checkIfDue()
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 86400 { check(userInitiated: false) }
    }

    func checkForUpdates() { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard !checking else { return }
        if let controller, !controller.updater.canCheckForUpdates {
            controller.checkForUpdates(nil)
            return
        }
        checking = true; status = "Checking…"
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/silentrosehill/KeyForge/releases/latest")!)
                request.timeoutInterval = 20
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("KeyForge", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_048_576 else {
                    throw UpdateError.unavailable
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard !release.draft, !release.prerelease, UpdateVersion.numbers(release.tag_name) != nil else {
                    throw UpdateError.unavailable
                }
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                guard UpdateVersion.isNewer(release.tag_name, than: installed) else {
                    status = "Up to date."
                    if userInitiated { showMessage("KeyForge is up to date", detail: "You’re running version \(installed).") }
                    return
                }
                guard release.assets.contains(where: { asset in
                    asset.name == "appcast.xml" && asset.browser_download_url.scheme == "https"
                        && asset.browser_download_url.host == "github.com"
                        && asset.browser_download_url.path.hasPrefix("/silentrosehill/KeyForge/releases/download/")
                }) else { throw UpdateError.missingFeed }
                if controller == nil {
                    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
                    try updater.updater.start()
                    controller = updater
                }
                status = "Update available: \(release.tag_name)."
                if userInitiated { controller?.checkForUpdates(nil) }
                else { controller?.updater.checkForUpdatesInBackground() }
            } catch {
                status = error.localizedDescription
                if userInitiated { showMessage("Couldn’t check for updates", detail: status) }
            }
        }
    }

    private enum UpdateError: LocalizedError {
        case unavailable, missingFeed
        var errorDescription: String? {
            switch self {
            case .unavailable: "Try again when GitHub is available."
            case .missingFeed: "This release is missing its signed update feed."
            }
        }
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Updates").font(.subheadline.weight(.semibold))
                Spacer()
                Button(updater.checking ? "Checking…" : "Check for Updates…") { updater.checkForUpdates() }
                    .disabled(updater.checking)
            }
            Toggle("Check automatically", isOn: $updater.automaticChecks).toggleStyle(.switch)
            if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { updater.start() }
    }
}
