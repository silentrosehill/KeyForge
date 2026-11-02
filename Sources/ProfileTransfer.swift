import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The portable format deliberately contains profiles only, not active selections or device settings.
enum ProfileArchive {
    static let maximumBytes = 10 * 1024 * 1024
    private static let maximumProfiles = 500

    enum ArchiveError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    private struct Archive: Codable {
        let type: String
        let version: Int
        let profiles: [StrictProfile]
    }

    /// Profile's normal decoder tolerates damaged action fields for old local files. Imports
    /// must instead reject the entire file if any present field cannot be decoded.
    private struct StrictProfile: Codable {
        let profile: Profile
        enum CodingKeys: String, CodingKey { case id, name, map, lighting, actions, apps, device, mouse, mouseLighting, requiresManualActivation, dualRole, keyboardLayers }
        enum LightingKeys: String, CodingKey { case effect, screenStyle, screenTransition, screenIgnoreBlackBars, layers }
        enum MouseLightingKeys: String, CodingKey { case effect }
        init(_ profile: Profile) { self.profile = profile }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            _ = try c.decode(String.self, forKey: .name)
            _ = try c.decodeIfPresent(UUID.self, forKey: .id)
            _ = try c.decodeIfPresent([Usage: Usage].self, forKey: .map)
            _ = try c.decodeIfPresent(Lighting.self, forKey: .lighting)
            if c.contains(.lighting), try !c.decodeNil(forKey: .lighting) {
                let lighting = try c.nestedContainer(keyedBy: LightingKeys.self, forKey: .lighting)
                if lighting.contains(.layers) { _ = try lighting.decode([LightingLayer].self, forKey: .layers) }
                if lighting.contains(.effect) { _ = try lighting.decode(Lighting.Effect.self, forKey: .effect) }
                if lighting.contains(.screenStyle) { _ = try lighting.decode(Lighting.ScreenStyle.self, forKey: .screenStyle) }
                if lighting.contains(.screenIgnoreBlackBars) { _ = try lighting.decode(Bool.self, forKey: .screenIgnoreBlackBars) }
                if lighting.contains(.screenTransition) {
                    let value = try lighting.decode(Double.self, forKey: .screenTransition)
                    guard value.isFinite, (0...1).contains(value) else {
                        throw ArchiveError.invalid("A lighting transition is outside the supported range.")
                    }
                }
            }
            _ = try c.decodeIfPresent([Usage: DualRoleBinding].self, forKey: .dualRole)
            _ = try c.decodeIfPresent([KeyboardLayer].self, forKey: .keyboardLayers)
            _ = try c.decodeIfPresent([Usage: KeyAction].self, forKey: .actions)
            _ = try c.decodeIfPresent([String].self, forKey: .apps)
            _ = try c.decodeIfPresent(String.self, forKey: .device)
            _ = try c.decodeIfPresent([Int: MouseAction].self, forKey: .mouse)
            _ = try c.decodeIfPresent(MouseLighting.self, forKey: .mouseLighting)
            if c.contains(.mouseLighting), try !c.decodeNil(forKey: .mouseLighting) {
                let lighting = try c.nestedContainer(keyedBy: MouseLightingKeys.self, forKey: .mouseLighting)
                if lighting.contains(.effect) { _ = try lighting.decode(MouseLighting.Effect.self, forKey: .effect) }
            }
            _ = try c.decodeIfPresent(Bool.self, forKey: .requiresManualActivation)
            profile = try Profile(from: decoder)
        }
        func encode(to encoder: Encoder) throws { try profile.encode(to: encoder) }
    }

    private struct Envelope: Decodable {
        let profiles: [StrictProfile]
    }

    static func encode(_ profiles: [Profile]) throws -> Data {
        try validate(profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Archive(type: "keyforge-profiles", version: 1, profiles: profiles.map(StrictProfile.init)))
        guard data.count <= maximumBytes else { throw ArchiveError.invalid("The profiles are too large to export (maximum 10 MB).") }
        return data
    }

    static func decode(_ data: Data) throws -> [Profile] {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ArchiveError.invalid("Choose a nonempty JSON file no larger than 10 MB.")
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ArchiveError.invalid("This file does not contain KeyForge profiles.")
            }
            let decoder = JSONDecoder()
            let profiles: [Profile]
            if object["type"] != nil || object["version"] != nil {
                let archive = try decoder.decode(Archive.self, from: data)
                guard archive.type == "keyforge-profiles", archive.version == 1 else {
                    throw ArchiveError.invalid("This profile archive has an unsupported type or version.")
                }
                profiles = archive.profiles.map(\.profile)
            } else if object["profiles"] != nil {
                profiles = try decoder.decode(Envelope.self, from: data).profiles.map(\.profile)
            } else {
                profiles = [try decoder.decode(StrictProfile.self, from: data).profile]
            }
            try validate(profiles)
            return profiles
        } catch let error as ArchiveError { throw error }
        catch { throw ArchiveError.invalid("The file is not a valid KeyForge profile archive.") }
    }

    private static func validate(_ profiles: [Profile]) throws {
        guard !profiles.isEmpty, profiles.count <= maximumProfiles else {
            throw ArchiveError.invalid("An archive must contain between 1 and 500 profiles.")
        }
        func check(_ action: KeyAction) -> Bool {
            switch action {
            case .shortcut(let shortcut): return shortcut.keyCode <= 255
            case .text(let text), .app(let text): return text.utf8.count <= 16_384
            case .macro(let steps):
                return steps.count <= 500 && steps.allSatisfy { step in
                    switch step {
                    case .shortcut(let shortcut): return shortcut.keyCode <= 255
                    case .text(let text): return text.utf8.count <= 16_384
                    case .wait(let seconds): return seconds.isFinite && seconds >= 0 && seconds <= 3600
                    }
                }
            }
        }
        func unit(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
        for profile in profiles {
            func source(_ key: Usage) -> Bool { key >> 32 == 7 && !(0xE0...0xE7).contains(key & 0xFF) && key != HID.key(0x6F) && Keys.vk(for: key, iso: true) != nil }
            guard profile.dualRole.count <= 256, profile.keyboardLayers.count <= 64,
                  Set(profile.keyboardLayers.map(\.id)).count == profile.keyboardLayers.count,
                  Set(profile.keyboardLayers.map(\.trigger)).count == profile.keyboardLayers.count,
                  profile.dualRole.allSatisfy({ key, binding in source(key) && binding.threshold.isFinite && (0.1...0.5).contains(binding.threshold) && Keys.vk(for: binding.tap, iso: true) != nil && (0xE0...0xE7).contains(binding.hold & 0xFF) && binding.hold >> 32 == 7 }),
                  profile.keyboardLayers.allSatisfy({ layer in source(layer.trigger) && profile.dualRole[layer.trigger] == nil && layer.name.utf8.count <= 1024 && layer.bindings.count <= 256 && layer.bindings.allSatisfy { source($0.key) && Keys.vk(for: $0.value, iso: true) != nil } }) else {
                throw ArchiveError.invalid("A profile contains unsupported tap/hold or layer bindings.")
            }

            if let lighting = profile.lighting {
                guard lighting.layers.count <= 64, Set(lighting.layers.map(\.id)).count == lighting.layers.count,
                      lighting.layers.allSatisfy({ $0.name.utf8.count <= 1024 && unit($0.opacity) && unit($0.brightness) && $0.keyColors.count <= 4096 && $0.keyColors.values.allSatisfy { $0 <= 0xFFFFFF } }) else { throw ArchiveError.invalid("Invalid painted lighting layers.") }

                guard [lighting.red, lighting.green, lighting.blue, lighting.brightness, lighting.screenTransition].allSatisfy(unit),
                      lighting.keyColors.count <= 4096, lighting.keyColors.values.allSatisfy({ $0 <= 0xFFFFFF }) else {
                    throw ArchiveError.invalid("A profile has invalid keyboard lighting values.")
                }
            }
            if let lighting = profile.mouseLighting {
                guard unit(lighting.brightness), unit(lighting.speed), lighting.color <= 0xFFFFFF,
                      lighting.zones.count == 3, lighting.zones.allSatisfy({ $0 <= 0xFFFFFF }) else {
                    throw ArchiveError.invalid("A profile has invalid mouse lighting values.")
                }
            }
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.name.utf8.count <= 1024, profile.device.utf8.count <= 1024,
                  profile.apps.count <= 1000, profile.apps.allSatisfy({ $0.utf8.count <= 4096 }),
                  profile.map.count <= 4096, profile.actions.count <= 4096, profile.mouse.count <= 256,
                  profile.mouse.keys.allSatisfy({ (2...255).contains($0) }),
                  profile.actions.values.allSatisfy(check),
                  profile.mouse.values.allSatisfy({ action in
                      switch action {
                      case .action(let keyAction): return check(keyAction)
                      case .button(let button): return (0...255).contains(button)
                      default: return true
                      }
                  }) else {
                throw ArchiveError.invalid("A profile contains an invalid or oversized value.")
            }
        }
    }
}

/// Presents native, nonblocking file panels. Cancellation leaves status unchanged.
@MainActor
final class ProfileTransfer: ObservableObject {
    static let shared = ProfileTransfer()
    @Published var message: String?

    func exportProfiles(_ profiles: [Profile]) {
        do {
            let data = try ProfileArchive.encode(profiles)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "KeyForge Profiles.json"
            show(panel) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    self?.message = "Exported \(profiles.count) \(profiles.count == 1 ? "profile" : "profiles")."
                } catch { self?.message = "Could not export profiles: \(error.localizedDescription)" }
            }
        } catch { message = "Could not export profiles: \(error.localizedDescription)" }
    }

    func importProfiles(into store: ProfileStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        show(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: ProfileArchive.maximumBytes + 1) ?? Data()
                let profiles = try ProfileArchive.decode(data)
                let count = store.importProfiles(profiles)
                self?.message = "Imported \(count) \(count == 1 ? "profile" : "profiles"). Select a profile to use it."
            } catch { self?.message = "Could not import profiles: \(error.localizedDescription)" }
        }
    }

    private func show(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
