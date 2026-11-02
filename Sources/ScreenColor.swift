import AppKit
import Combine
import ScreenCaptureKit
import CoreMedia
import CoreVideo

private final class ScreenColorOutput: NSObject, SCStreamOutput {
    let deliver: ([UInt32]) -> Void
    let ignoreBlackBars: Bool
    let uniform: Bool
    init(ignoreBlackBars: Bool, uniform: Bool, deliver: @escaping ([UInt32]) -> Void) {
        self.ignoreBlackBars = ignoreBlackBars; self.uniform = uniform; self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .blank || status == .suspended { deliver(ScreenColorGrid.black); return }
        guard status == .complete, let pixels = CMSampleBufferGetImageBuffer(buffer),
              let colors = ScreenColorGrid.sample(pixels, ignoreBlackBars: ignoreBlackBars, uniform: uniform) else { return }
        deliver(colors)
    }
}

/// ScreenCaptureKit runs only while Screen Color is the active keyboard effect.
@MainActor
final class ScreenColorCapture: NSObject, ObservableObject, SCStreamDelegate {
    static let shared = ScreenColorCapture()
    struct Display: Identifiable { let id: UInt32; let name: String }
    @Published private(set) var status = "Screen Recording access is required."
    @Published private(set) var needsPermission = !CGPreflightScreenCaptureAccess()
    @Published private(set) var isCapturing = false
    @Published private(set) var displays: [Display] = []
    @Published var selectedDisplayID: UInt32 = UInt32(exactly: UserDefaults.standard.integer(forKey: "screenColorDisplay")) ?? 0 {
        didSet {
            UserDefaults.standard.set(Int(selectedDisplayID), forKey: "screenColorDisplay")
            if selectedDisplayID != oldValue && !choosingDisplay && wanted { restart() }
        }
    }
    // The lighting engine reads this on the main actor, without redrawing the whole UI per frame.
    private(set) var colors: [UInt32] = []
    private var ignoreBlackBars = true
    private var uniform = false
    func configure(ignoreBlackBars: Bool, uniform: Bool) {
        guard self.ignoreBlackBars != ignoreBlackBars || self.uniform != uniform else { return }
        self.ignoreBlackBars = ignoreBlackBars; self.uniform = uniform
        if wanted { restart() }
    }
    private var wanted = false
    private var suspensions: Set<String> = []
    private var paused: Bool { !suspensions.isEmpty }
    private var choosingDisplay = false
    private var generation = 0
    private var stream: SCStream?
    private var output: ScreenColorOutput?
    private var task: Task<Void, Never>?
    private let queue = DispatchQueue(label: "keyforge.screen-color", qos: .utility)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private override init() {
        super.init()
        refreshDisplayNames()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { capture in
            capture.refreshDisplayNames()
            if capture.wanted { capture.restart() }
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { capture in
            if capture.wanted && !capture.isCapturing && !capture.paused { capture.restart() }
        }
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { $0.stop() }
        let workspace = NSWorkspace.shared.notificationCenter
        let reasons: [(String, Notification.Name, Notification.Name)] = [
            ("display", NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            ("session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ]
        for (reason, pause, resume) in reasons {
            observe(workspace, pause) { capture in
                capture.suspensions.insert(reason)
                capture.invalidate()
            }
            observe(workspace, resume) { capture in
                capture.suspensions.remove(reason)
                if capture.wanted && !capture.paused { capture.restart() }
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (ScreenColorCapture) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private func refreshDisplayNames() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return Display(id: id, name: screen.localizedName)
        }
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        restart()
    }

    func stop() {
        wanted = false
        invalidate()
        status = "Screen Color is off."
    }

    func requestAccess() {
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            needsPermission = false
            if wanted { restart() }
        } else {
            needsPermission = true
            status = "Allow KeyForge in Screen Recording, then return here."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func retry() { if wanted { restart() } }

    private func invalidate() {
        generation += 1
        task?.cancel(); task = nil
        let old = stream
        stream = nil; output = nil
        isCapturing = false; colors = []
        if let old { Task { try? await old.stopCapture() } }
    }

    private func restart() {
        invalidate()
        guard wanted, !paused else { return }
        needsPermission = !CGPreflightScreenCaptureAccess()
        guard !needsPermission else { status = "Screen Recording access is required."; return }
        let run = generation
        status = "Connecting to display…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled, self.generation == run, self.wanted else { return }
                self.refreshDisplayNames()
                guard let display = content.displays.first(where: { $0.displayID == self.selectedDisplayID })
                        ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    self.status = "No display available."; return
                }
                self.choosingDisplay = true
                self.selectedDisplayID = display.displayID
                self.choosingDisplay = false
                let configuration = SCStreamConfiguration()
                configuration.width = 176; configuration.height = 96
                configuration.scalesToFit = true; configuration.preservesAspectRatio = false
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 8)
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.showsCursor = false
                configuration.capturesAudio = false
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let next = SCStream(filter: filter, configuration: configuration, delegate: self)
                let output = ScreenColorOutput(ignoreBlackBars: self.ignoreBlackBars, uniform: self.uniform) { [weak self] colors in
                    Task { @MainActor in
                        guard let self, self.wanted, self.generation == run else { return }
                        self.colors = colors
                    }
                }
                try next.addStreamOutput(output, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = next; self.output = output
                try await next.startCapture()
                guard !Task.isCancelled, self.generation == run, self.wanted else {
                    try? await next.stopCapture(); return
                }
                self.isCapturing = true
                self.status = "Colors follow your screen."
            } catch {
                guard self.generation == run else { return }
                self.invalidate()
                self.needsPermission = !CGPreflightScreenCaptureAccess()
                self.status = self.needsPermission ? "Screen Recording access is required." : "Couldn't capture this display. Try again."
                AutoSwitchLog.write("screen color capture: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.invalidate()
            self.needsPermission = !CGPreflightScreenCaptureAccess()
            self.status = self.needsPermission ? "Screen Recording access is required." : "Screen capture stopped. Try again."
        }
    }
}
