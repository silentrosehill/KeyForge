import SwiftUI
import CoreGraphics

/// Live local device and permission state; no device probing or network requests are made here.
struct ConnectionDiagnostics: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject private var tap = KeyTap.shared
    @ObservedObject private var devices: DeviceWatcher

    init(store: ProfileStore) {
        self.store = store
        self.devices = store.devices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection diagnostics").font(.headline)
            status("Selected keyboard", value: store.device == KeyboardDevice.allKey ? "All keyboards" : store.name(of: store.device),
                   detail: store.device == KeyboardDevice.allKey ? "Applies to connected keyboards" : (store.selectedConnected ? "Connected" : "Not connected"),
                   good: store.selectedConnected)
            status("Connected keyboards", value: "\(devices.keyboards.count)",
                   detail: devices.keyboards.isEmpty ? "No keyboards detected" : devices.keyboards.map(\.name).joined(separator: ", "),
                   good: !devices.keyboards.isEmpty)
            status("Remapping", value: store.enabled ? "On" : "Paused", detail: store.lastError ?? "", good: store.enabled && store.lastError == nil)
            status("Accessibility", value: tap.trusted ? "Allowed" : "Not allowed",
                   detail: tap.needed ? (tap.running ? "Event tap running" : "Event tap not running") : "Needed for actions and mouse bindings",
                   good: tap.trusted && (!tap.needed || tap.running))
            status("Screen Recording", value: CGPreflightScreenCaptureAccess() ? "Allowed" : "Not allowed",
                   detail: "Required for Screen Color lighting", good: CGPreflightScreenCaptureAccess())
            HStack {
                Button("Recheck") { tap.recheck() }.buttonStyle(.purpleGlass)
                if !tap.trusted { Button("Allow Accessibility…") { tap.requestAccess() }.buttonStyle(.purpleGlassProminent) }
            }
        }
        .padding(16).frame(width: 380, alignment: .leading)
        .onAppear { tap.recheck() }
    }

    private func status(_ title: String, value: String, detail: String, good: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: good ? "checkmark.circle.fill" : "circle.fill")
                .foregroundStyle(good ? ForgePalette.amber : Color.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(title).fontWeight(.medium); Spacer(); Text(value).foregroundStyle(.secondary) }
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.font(.callout)
    }
}
