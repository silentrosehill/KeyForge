import SwiftUI

/// Edits dual-role behavior for the selected key and profile-wide keyboard layers.
struct KeyBehaviorEditor: View {
    @ObservedObject var store: ProfileStore
    let key: Usage

    private var eligibleKeys: [KeyDef] {
        var seen = Set<Usage>()
        return Keys.layout(store.layout, iso: store.iso).filter {
            !$0.fixed && !Self.isModifier($0.usage) && $0.usage != HID.key(0x6F) && Keys.vk(for: $0.usage, iso: store.iso) != nil && seen.insert($0.usage).inserted
        }
    }

    private static func isModifier(_ usage: Usage) -> Bool {
        usage >> 32 == 7 && (0xE0...0xE7).contains(usage & 0xFF)
    }

    var body: some View {
        let dual = store.active?.dualRole[key]
        let layers = store.active?.keyboardLayers ?? []
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Tap and hold", systemImage: "hand.tap").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { dual != nil }, set: { on in
                    if on && !KeyTap.shared.trusted { KeyTap.shared.requestAccess() }
                    store.setDualRole(key, binding: on ? DualRoleBinding(tap: key == HID.key(0x39) ? HID.key(0x29) : key, hold: HID.key(0xE0)) : nil)
                })).labelsHidden().disabled(Self.isModifier(key))
            }
            if Self.isModifier(key) {
                Text("Choose a non-modifier key or Caps Lock for tap and hold.").font(.caption).foregroundStyle(.secondary)
            } else if let dual {
                HStack {
                    Text("Tap").foregroundStyle(.secondary)
                    targetMenu(dual.tap) { value in var next = dual; next.tap = value; store.setDualRole(key, binding: next) }
                    Text("Hold").foregroundStyle(.secondary)
                    modifierMenu(dual.hold) { value in var next = dual; next.hold = value; store.setDualRole(key, binding: next) }
                    Spacer()
                }
                HStack {
                    Text("Hold delay").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { dual.threshold }, set: { value in
                        var next = dual; next.threshold = value; store.setDualRole(key, binding: next)
                    }), in: 0.1...0.5, step: 0.05)
                    Text(String(format: "%.2f s", dual.threshold)).monospacedDigit().frame(width: 48)
                }.font(.callout)
            }
            Divider()
            HStack {
                Label("Keyboard layers", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button("Add layer") {
                    if !KeyTap.shared.trusted { KeyTap.shared.requestAccess() }
                    guard let trigger = eligibleKeys.first(where: { item in !layers.contains { $0.trigger == item.usage } })?.usage else { return }
                    var next = layers
                    next.append(KeyboardLayer(name: "Layer \(next.count + 1)", trigger: trigger, bindings: [:]))
                    store.setKeyboardLayers(next)
                }.buttonStyle(.purpleGlass).disabled(eligibleKeys.isEmpty)
            }
            if layers.isEmpty { Text("Hold a layer trigger to use alternate key mappings.").font(.caption).foregroundStyle(.secondary) }
            ForEach(layers) { layer in layerEditor(layer) }
            Text("Tap and hold and layers require Accessibility and apply across keyboards. Caps Lock behavior reserves F20.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func layerEditor(_ layer: KeyboardLayer) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                TextField("Layer name", text: Binding(get: { current(layer.id)?.name ?? layer.name }, set: { name in
                    update(layer.id) { $0.name = name }
                })).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Text("Hold").foregroundStyle(.secondary)
                sourceMenu(layer.trigger) { value in update(layer.id) { $0.trigger = value } }
                Spacer()
                Button(role: .destructive) { store.setKeyboardLayers((store.active?.keyboardLayers ?? []).filter { $0.id != layer.id }) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.plain).help("Delete layer")
            }
            ForEach(layer.bindings.keys.sorted(), id: \.self) { source in
                HStack {
                    Text(Keys.name(source, iso: store.iso)).frame(minWidth: 70, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    targetMenu(layer.bindings[source] ?? source) { target in update(layer.id) { $0.bindings[source] = target } }
                    Spacer()
                    Button { update(layer.id) { $0.bindings.removeValue(forKey: source) } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Remove mapping")
                }.font(.callout)
            }
            Menu("Add mapping") {
                ForEach(eligibleKeys.filter { layer.bindings[$0.usage] == nil }) { item in
                    Button(Keys.name(item.usage, iso: store.iso)) { update(layer.id) { $0.bindings[item.usage] = item.usage } }
                }
            }.modifier(GlassMenuLabel())
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    private func current(_ id: UUID) -> KeyboardLayer? { store.active?.keyboardLayers.first { $0.id == id } }
    private func update(_ id: UUID, _ change: (inout KeyboardLayer) -> Void) {
        var layers = store.active?.keyboardLayers ?? []
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[index]); store.setKeyboardLayers(layers)
    }

    private func sourceMenu(_ selection: Usage, set: @escaping (Usage) -> Void) -> some View {
        Menu {
            ForEach(eligibleKeys.filter { item in item.usage == selection || !(store.active?.keyboardLayers ?? []).contains { $0.trigger == item.usage } }) { item in Button(Keys.name(item.usage, iso: store.iso)) { set(item.usage) } }
        } label: { Text(Keys.name(selection, iso: store.iso)) }.modifier(GlassMenuLabel())
    }

    private func modifierMenu(_ selection: Usage, set: @escaping (Usage) -> Void) -> some View {
        Menu {
            ForEach(Array(0xE0...0xE7), id: \.self) { code in
                let usage = HID.key(UInt64(code))
                Button(Keys.name(usage, iso: store.iso)) { set(usage) }
            }
        } label: { Text(Keys.name(selection, iso: store.iso)) }.modifier(GlassMenuLabel())
    }

    private func targetMenu(_ selection: Usage, set: @escaping (Usage) -> Void) -> some View {
        Menu {
            ForEach(Keys.targetGroups(iso: store.iso)) { group in
                Menu {
                    ForEach(group.usages.filter { Keys.vk(for: $0, iso: store.iso) != nil }, id: \.self) { usage in Button(Keys.name(usage, iso: store.iso)) { set(usage) } }
                } label: { Label(group.title, systemImage: group.icon) }
            }
        } label: { Text(Keys.name(selection, iso: store.iso)) }.modifier(GlassMenuLabel())
    }
}
