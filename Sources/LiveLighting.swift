import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox
import Accelerate

// MARK: - The engine: hardware effects, or frames KeyForge draws itself

/// Decides what the keyboard shows: a built-in effect (the keyboard animates it), or frames KeyForge
/// renders ~25×/s (Ripple, Rain, Heatmap, Album Cover, Music), plus the Caps Lock light on top.
@MainActor
final class LightingEngine: ObservableObject {
    static let shared = LightingEngine()

    /// The frame being shown when KeyForge draws the colors (nil = the keyboard runs a built-in effect).
    /// Its own object: only the keyboard preview redraws 25×/s, not everything that watches the engine.
    let live = LiveFrame()
    private var frame: [Usage: UInt32]? {
        get { live.frame }
        set { if live.frame != newValue { live.frame = newValue } }
    }

    @Published var capsLight: Bool = UserDefaults.standard.bool(forKey: "capsLight") {
        didSet { UserDefaults.standard.set(capsLight, forKey: "capsLight"); configure() }
    }
    @Published var capsHex: UInt32 = UInt32(UserDefaults.standard.object(forKey: "capsHex") as? Int ?? 0xFF2A2A) {
        didSet { UserDefaults.standard.set(Int(capsHex), forKey: "capsHex"); configure() }
    }
    @Published private(set) var capsOn = false

    private var lighting = Lighting.standard
    private var product: Int?
    private var timer: Timer?
    private var capsTimer: Timer?
    private var start = CFAbsoluteTimeGetCurrent()
    private var lastSent: [Usage: UInt32]?
    private var keys: [KeyDef] = []

    // effect state
    private var ripples: [(x: Double, y: Double, t: Double, hue: Double)] = []
    private var drops: [(x: Double, y: Double, speed: Double, hex: UInt32)] = []

    static let fps = 25.0
    static let capsKey = HID.key(0x39)

    private var iso = true

    /// (iso is passed in: reading ProfileStore.shared here would recurse while the store is still loading)
    func update(_ l: Lighting, product p: Int?, iso: Bool) {
        lighting = l
        self.iso = iso
        if let p { product = p }
        configure()
    }

    private func configure() {
        keys = Keys.huntsmanV2(iso: iso)
        let e = lighting.effect

        // who needs key presses / audio
        let wantsKeys = e == .ripple || e == .heatmap
        if wantsKeys != (KeyTap.shared.listeners["engine"] != nil) {
            KeyTap.shared.listeners["engine"] = wantsKeys ? { [weak self] u in self?.pressed(u) } : nil
        }
        if e == .music { AudioTap.shared.start() } else { AudioTap.shared.stop() }
        if e == .cover { NowPlayingLink.shared.start() }

        // Caps Lock light: watch the Caps state while it's on
        if capsLight, capsTimer == nil {
            capsOn = Self.capsState
            capsTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = Self.capsState
                    if now != self.capsOn { self.capsOn = now; self.configure() }
                }
            }
        } else if !capsLight {
            capsTimer?.invalidate(); capsTimer = nil; capsOn = false
        }

        if e.isLive {
            if timer == nil {
                start = CFAbsoluteTimeGetCurrent()
                let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            tick()
            return
        }
        timer?.invalidate(); timer = nil
        ripples = []; drops = []
        lastSent = nil

        if capsLight && capsOn && (e == .solid || e == .perKey) {
            // the keyboard can't lay one key over its built-in Solid, so draw the frame ourselves
            var f: [Usage: UInt32] = [:]
            for k in keys { f[k.usage] = lighting.hex(for: k.usage) }
            f[Self.capsKey] = capsHex
            frame = f
            LightingController.sendFrame(f, brightness: lighting.brightness, product: product)
        } else {
            frame = nil
            LightingController.apply(lighting, product: product)
        }
    }

    nonisolated static var capsState: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) }

    private func pressed(_ u: Usage) {
        switch lighting.effect {
        case .ripple:
            guard let k = keys.first(where: { $0.usage == u }) else { return }
            let hue = Double(ripples.count % 12) / 12
            ripples.append((k.x + k.w / 2, k.y + k.h / 2, CFAbsoluteTimeGetCurrent() - start, hue))
        case .heatmap:
            Heatmap.shared.press(u)
        default: break
        }
    }

    private func tick() {
        let t = CFAbsoluteTimeGetCurrent() - start
        var f: [Usage: UInt32] = [:]
        switch lighting.effect {
        case .ripple: f = renderRipple(t)
        case .rain: f = renderRain(t)
        case .heatmap: f = renderHeatmap()
        case .cover: f = renderCover(t)
        case .music: f = renderMusic()
        default: return
        }
        if capsLight && capsOn { f[Self.capsKey] = capsHex }
        if f != frame { frame = f }
        guard f != lastSent else { return }   // Heatmap / a paused cover barely change
        lastSent = f
        LightingController.sendFrame(f, brightness: lighting.brightness, product: product)
    }

    // MARK: effects

    private var base: UInt32 { lighting.baseHex }

    private func renderRipple(_ t: Double) -> [Usage: UInt32] {
        ripples.removeAll { t - $0.t > 1.6 }
        let dim = Color.scale(base, 0.12)
        var f: [Usage: UInt32] = [:]
        for k in keys {
            let cx = k.x + k.w / 2, cy = k.y + k.h / 2
            var best = 0.0, bestHex = base
            for r in ripples {
                let age = t - r.t
                let d = ((cx - r.x) * (cx - r.x) + (cy - r.y) * (cy - r.y)).squareRoot()
                let ring = exp(-pow((d - age * 9) / 0.9, 2)) * (1 - age / 1.6)
                if ring > best {
                    best = ring
                    // ripples shift hue a little each time, starting from the chosen color
                    bestHex = Color.hueShift(base, r.hue * 0.35)
                }
            }
            f[k.usage] = best > 0.02 ? Color.mix(dim, bestHex, min(1, best)) : dim
        }
        return f
    }

    private func renderRain(_ t: Double) -> [Usage: UInt32] {
        let dt = 1 / Self.fps
        for i in drops.indices { drops[i].y += drops[i].speed * dt }
        drops.removeAll { $0.y > Keys.layoutHeight + 2.5 }
        if drops.count < 16, Double.random(in: 0...1) < 0.55 {
            let col = Double(Int.random(in: 0...21)) + 0.5
            drops.append((col, -0.5, .random(in: 5...10), Color.hueShift(base, .random(in: -0.06...0.06))))
        }
        let dim = Color.scale(base, 0.05)
        var f: [Usage: UInt32] = [:]
        for k in keys {
            let cx = k.x + k.w / 2, cy = k.y + k.h / 2
            var c = dim
            for d in drops where abs(cx - d.x) < max(0.55, k.w / 2) && cy <= d.y && cy > d.y - 2.4 {
                let v = 1 - (d.y - cy) / 2.4
                c = Color.mix(c, d.hex, v)
            }
            f[k.usage] = c
        }
        return f
    }

    private static let heatStops: [UInt32] = [0x14145A, 0x0077FF, 0x00E5A0, 0xFFD400, 0xFF2A00]

    private func renderHeatmap() -> [Usage: UInt32] {
        let counts = Heatmap.shared.counts
        let top = log(1 + Double(counts.values.max() ?? 0))
        var f: [Usage: UInt32] = [:]
        for k in keys {
            let c = Double(counts[k.usage] ?? 0)
            f[k.usage] = c == 0 || top == 0 ? 0x0A0A26 : LightingPreset.blend(Self.heatStops, log(1 + c) / top)
        }
        return f
    }

    private func renderCover(_ t: Double) -> [Usage: UInt32] {
        let link = NowPlayingLink.shared
        var colors = link.colors
        if colors.isEmpty { colors = [base, Color.hueShift(base, 0.08), Color.hueShift(base, -0.08)] }
        let stops = colors + [colors[0]]
        let speed = link.playing ? 0.06 : 0.0
        var f: [Usage: UInt32] = [:]
        for k in keys {
            let x = (k.x + k.w / 2) / Keys.layoutWidth
            let y = (k.y + k.h / 2) / Keys.layoutHeight
            let p = (x * 0.8 + y * 0.2 + t * speed).truncatingRemainder(dividingBy: 1)
            f[k.usage] = Color.scale(LightingPreset.blend(stops, p), link.playing ? 1 : 0.55)
        }
        return f
    }

    private func renderMusic() -> [Usage: UInt32] {
        let (levels, rms) = AudioTap.shared.snapshot()
        let top = Color.hueShift(base, 0.12)
        var f: [Usage: UInt32] = [:]
        for k in keys {
            guard let pos = LEDMatrix.position(of: k.usage) else { f[k.usage] = 0; continue }
            let level = Double(levels[min(pos.col, levels.count - 1)])
            let height = level * 6                      // bar height in rows
            let fromBottom = Double(5 - pos.row)
            if fromBottom < height {
                let fill = min(1, height - fromBottom)
                let c = LightingPreset.blend([base, top, 0xFFFFFF], fromBottom / 5)
                f[k.usage] = Color.scale(c, 0.35 + 0.65 * fill)
            } else {
                f[k.usage] = Color.scale(base, 0.04 + 0.25 * Double(rms))   // the rest pulses with the beat
            }
        }
        return f
    }
}

@MainActor
final class LiveFrame: ObservableObject {
    @Published var frame: [Usage: UInt32]?
}

extension Color {
    static func scale(_ hex: UInt32, _ k: Double) -> UInt32 {
        func ch(_ s: UInt32) -> UInt32 { UInt32(max(0, min(255, (Double(hex >> s & 0xFF) * k).rounded()))) << s }
        return ch(16) | ch(8) | ch(0)
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 { LightingPreset.blend([a, b], t) }

    static func hueShift(_ hex: UInt32, _ dh: Double) -> UInt32 {
        let c = NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var nh = (Double(h) + dh).truncatingRemainder(dividingBy: 1); if nh < 0 { nh += 1 }
        return Color(nsColor: NSColor(hue: nh, saturation: s, brightness: b, alpha: 1)).hex
    }
}

// MARK: - MP3 Tagger link (album cover colors)

/// Listens for MP3 Tagger's now-playing broadcast (cover palette + playing state).
@MainActor
final class NowPlayingLink: ObservableObject {
    static let shared = NowPlayingLink()
    @Published private(set) var colors: [UInt32] = []
    @Published private(set) var playing = false
    @Published private(set) var title = ""
    private var observer: NSObjectProtocol?

    static let broadcast = Notification.Name("local.mp3tagger.nowPlaying")
    static let request = Notification.Name("local.keyforge.requestNowPlaying")

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.broadcast, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            let colors = (info["colors"] as? [Int] ?? []).map { UInt32(truncatingIfNeeded: $0) }
            let playing = info["playing"] as? Bool ?? false
            let title = info["title"] as? String ?? ""
            MainActor.assumeIsolated {
                self.colors = colors; self.playing = playing; self.title = title
            }
        }
        // ask MP3 Tagger (if it's running) what's on right now
        DistributedNotificationCenter.default().postNotificationName(Self.request, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

// MARK: - System audio → 22 bands (one per keyboard column)

/// Captures what the Mac is playing with a Core Audio process tap (macOS asks for permission once).
final class AudioTap: @unchecked Sendable {
    static let shared = AudioTap()

    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: LEDMatrix.cols)
    private var rms: Float = 0
    private var peaks = [Float](repeating: 1e-4, count: LEDMatrix.cols)
    private var ring = [Float](repeating: 0, count: 2048)
    private var ringFill = 0
    private var sampleRate: Double = 48000
    private var channels = 2

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "keyforge.audio")
    private(set) var running = false
    private(set) var lastError: String?

    private let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)

    func snapshot() -> ([Float], Float) {
        lock.lock(); defer { lock.unlock() }
        return (levels, rms)
    }

    func start() {
        guard !running else { return }
        do { try setUp(); running = true; lastError = nil }
        catch { lastError = "\(error)"; tearDown() }
    }

    func stop() {
        guard running else { return }
        tearDown()
        running = false
        lock.lock(); levels = levels.map { _ in 0 }; rms = 0; lock.unlock()
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw Failure(description: "\(what) failed (\(s))") }
    }

    private func setUp() throws {
        // default output device → its UID (the aggregate device is built on it)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &out), "output device")
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uidRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(out, &addr, 0, nil, &size, &uidRef), "device UID")
        let outUID = uidRef?.takeRetainedValue() as String? ?? ""

        // a private tap on everything the Mac plays (not muted)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "audio tap")

        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var fmt = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &fmt) == noErr {
            sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000
            channels = max(1, Int(fmt.mChannelsPerFrame))
        }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "KeyForge Music Tap",
            kAudioAggregateDeviceUIDKey: "local.keyforge.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "aggregate device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }, "audio callback")
        try check(AudioDeviceStart(aggID, procID), "audio start")
    }

    private func tearDown() {
        if aggID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let perBuffer = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, perBuffer)
        // mono mix
        var mono = [Float](repeating: 0, count: frames)
        if perBuffer >= 2 {
            for i in 0..<frames { mono[i] = (floats[i * perBuffer] + floats[i * perBuffer + 1]) * 0.5 }
        } else {
            for i in 0..<frames { mono[i] = floats[i] }
            if list.count > 1, let second = list[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<frames { mono[i] = (mono[i] + second[i]) * 0.5 }
            }
        }
        // slide into the 2048-sample window; analyse every ~1024 new samples
        let n = ring.count
        if frames >= n { ring = Array(mono.suffix(n)) } else {
            ring.removeFirst(frames); ring.append(contentsOf: mono)
        }
        ringFill += frames
        guard ringFill >= 1024 else { return }
        ringFill = 0
        analyse()
    }

    private func analyse() {
        guard let fft else { return }
        let n = ring.count, half = n / 2
        let x = vDSP.multiply(ring, window)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        let level = vDSP.rootMeanSquare(ring)
        // 22 log-spaced bands, 40 Hz … 16 kHz
        let cols = LEDMatrix.cols
        let binHz = sampleRate / Double(n)
        var bands = [Float](repeating: 0, count: cols)
        for b in 0..<cols {
            let lo = 40 * pow(16000 / 40, Double(b) / Double(cols)), hi = 40 * pow(16000 / 40, Double(b + 1) / Double(cols))
            let i0 = max(1, Int(lo / binHz)), i1 = min(half - 1, max(i0 + 1, Int(hi / binHz)))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            bands[b] = sum / Float(i1 - i0)
        }
        lock.lock()
        for b in 0..<cols {
            peaks[b] = max(bands[b], peaks[b] * 0.997, 1e-4)          // slowly forgetting loudest
            let v = min(1, bands[b] / peaks[b])
            levels[b] = max(v, levels[b] * 0.82)                        // fast rise, soft fall
        }
        rms = max(min(1, level * 4), rms * 0.8)
        lock.unlock()
    }
}
