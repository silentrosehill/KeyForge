import SwiftUI
import AppKit

@MainActor
private final class KeyCaptureState: ObservableObject {
    @Published var replacement: Usage?
    var dismissal: DispatchWorkItem?

    func stop() {
        dismissal?.cancel()
        dismissal = nil
    }
}

/// Original key → next key pressed. Click outside to cancel.
struct KeyBindingPicker: View {
    @ObservedObject var store: ProfileStore
    let key: Usage
    let dismiss: () -> Void
    @StateObject private var state = KeyCaptureState()
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 26) {
            BigCap(usage: key, iso: store.iso, highlighted: false)
                .scaleEffect(1.2).frame(width: 80, height: 80)
            Image(systemName: "arrow.right")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.secondary)
            Group {
                if let replacement = state.replacement {
                    BigCap(usage: replacement, iso: store.iso, highlighted: true)
                        .scaleEffect(1.2)
                } else {
                    let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
                    shape.fill(LinearGradient(colors: scheme == .dark ? [Color(white: 0.24), Color(white: 0.15)] : [Color(white: 0.99), Color(white: 0.9)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                                           startPoint: .topLeading, endPoint: .center)))
                        .overlay(shape.strokeBorder(theme.accent.opacity(0.6), lineWidth: 1))
                        .shadow(color: theme.accent.opacity(0.12), radius: 10)
                        .frame(width: 77, height: 77)
                        .accessibilityLabel("Press the replacement key")
                }
            }
            .frame(width: 80, height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ForgePanel(cornerRadius: 20, emphasized: true))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Change \(Keys.name(key, iso: store.iso))")
        .onAppear {
            (NSApp.keyWindow ?? NSApp.mainWindow)?.makeFirstResponder(nil)
            LiveKeys.shared.shortcutRecorder = nil
            LiveKeys.shared.recorder = { replacement in
                guard state.replacement == nil else { return }
                store.set(key, to: replacement)
                state.replacement = replacement
                let finish = DispatchWorkItem(block: dismiss)
                state.dismissal = finish
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: finish)
            }
        }
        .onDisappear { state.stop(); LiveKeys.shared.recorder = nil }
    }
}
