import Foundation
import AppKit

@main
struct ProfileIntegrationTests {
    @MainActor static func main() throws {
        var original = Profile(name: "Portable")
        original.map[HID.key(0x0e)] = HID.key(0x0d)
        original.actions[HID.key(0x0f)] = .macro([.text("hello"), .wait(0.1), .shortcut(Shortcut(keyCode: 0, modifiers: 0))])
        original.apps = ["example.app"]
        var lighting = Lighting(); lighting.effect = .screen; lighting.screenStyle = .uniform
        lighting.screenTransition = 0.3; lighting.screenIgnoreBlackBars = false
        lighting.layers = [LightingLayer(name: "WASD", opacity: 0.5, brightness: 0.6, keyColors: [HID.key(4): 0xFF0000])]
        original.dualRole = [HID.key(0x39): DualRoleBinding(tap: HID.key(0x29), hold: HID.key(0xE0))]
        original.keyboardLayers = [KeyboardLayer(name: "Navigation", trigger: HID.key(0x2C), bindings: [HID.key(4): HID.key(0x50)])]
        original.lighting = lighting
        original.mouseLighting = MouseLighting()
        let encoded = try ProfileArchive.encode([original])
        let decoded_encoded = try ProfileArchive.decode(encoded); precondition(decoded_encoded == [original])
        let raw = try JSONEncoder().encode(original)
        let decoded_raw = try ProfileArchive.decode(raw); precondition(decoded_raw == [original])
        let legacy = try JSONSerialization.data(withJSONObject: ["profiles": [try JSONSerialization.jsonObject(with: raw)]])
        let decoded_legacy = try ProfileArchive.decode(legacy); precondition(decoded_legacy == [original])
        func reject(_ mutate: (inout [String: Any]) -> Void) throws {
            var object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            mutate(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            do { _ = try ProfileArchive.decode(data); preconditionFailure("Invalid archive accepted") }
            catch is ProfileArchive.ArchiveError {}
        }
        try reject { $0["dualRole"] = "broken" }
        try reject { var l = $0["lighting"] as! [String: Any]; var layers = l["layers"] as! [[String: Any]]; layers[0]["opacity"] = 2; l["layers"] = layers; $0["lighting"] = l }
        try reject { $0["actions"] = "broken" }
        try reject { $0["name"] = "   " }
        try reject { var light = $0["lighting"] as! [String: Any]; light["effect"] = "unknown"; $0["lighting"] = light }
        try reject { var light = $0["lighting"] as! [String: Any]; light["screenTransition"] = 4; $0["lighting"] = light }
        try reject { var light = $0["mouseLighting"] as! [String: Any]; light["zones"] = []; $0["mouseLighting"] = light }
        try reject { var light = $0["mouseLighting"] as! [String: Any]; light["speed"] = -2; $0["mouseLighting"] = light }
        do { _ = try ProfileArchive.decode(Data("{\"type\":\"keyforge-profiles\",\"version\":999,\"profiles\":[]}".utf8)); preconditionFailure() }
        catch is ProfileArchive.ArchiveError {}
        let store = ProfileStore.shared
        let before = store.profiles
        let key = HID.key(0x0e), target = HID.key(0x0d)
        store.set(key, to: target); precondition(store.active?.map[key] == target)
        store.history.undo(); precondition(store.profiles == before)
        store.history.redo(); precondition(store.active?.map[key] == target)
        var screen = Lighting(); screen.effect = .screen
        store.setLighting(screen)
        screen.screenStyle = .uniform; store.setLighting(screen)
        screen.screenIgnoreBlackBars = false; store.setLighting(screen)
        store.history.undo()
        precondition(store.active?.lighting?.screenStyle == .uniform && store.active?.lighting?.screenIgnoreBlackBars == true)
        store.history.undo(); precondition(store.active?.lighting?.screenStyle == .regional)
        let beforeImport = store.profiles
        let count = store.importProfiles([original, original])
        precondition(count == 2 && store.profiles.count == beforeImport.count + 2)
        let imported = Array(store.profiles.suffix(2))
        precondition(Set(imported.map(\.id)).count == 2 && !imported.contains(where: { $0.id == original.id }))
        precondition(imported.allSatisfy { $0.requiresManualActivation && $0.apps == original.apps })
        precondition(imported[0].name != imported[1].name)
        precondition(!store.activeByDevice.values.contains(imported[0].id))
        store.history.undo(); precondition(store.profiles == beforeImport)
        store.history.redo(); precondition(store.profiles.count == beforeImport.count + 2)
        let importedID = store.profiles.last!.id
        store.select(importedID); precondition(store.activeID == importedID && store.active?.requiresManualActivation == false)
        store.history.undo(); precondition(store.profiles == beforeImport && store.active != nil)
        store.saveNow()
        print("Profile integration tests passed: archive roundtrips/legacy, malformed imports, limits, remap undo/redo, copy IDs, inactive imports, import undo/redo and selection repair")
    }
}
